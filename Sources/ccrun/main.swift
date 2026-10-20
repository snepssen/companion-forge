// Recorded speech through the live loop in real time, for measuring without a
// microphone: the turn taker, recognition, the model and the voice as the app
// runs them, with the reply's own voice leaking back into the "microphone" at
// a chosen level, as it would past the echo canceller.
//
//   ccrun                       a short conversation, with an interruption
//   ccrun --echo 0.3            the same with far more echo leaking through
//   ccrun --model qwen3-4b-instruct-2507-4bit
//   ccrun --faces <folder>      the face in each mood and some visemes, as PNGs
//   ccrun --window <file.png>   the app's window, loaded as the app loads it
//
// Built with build.sh's xcodebuild (MLX needs its Metal library beside it):
//   .build/xcode/Build/Products/Release/ccrun
import CompanionCore
import CompanionEngine
import CompanionUI
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

func option(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

enum Run { static let started = Duplex.now }
func stamp() -> String { String(format: "[%6.2f]", Duplex.now - Run.started) }
func say(_ line: String) {
    print("\(stamp()) \(line)")
    fflush(stdout)
}

func resample(_ samples: [Float], from rate: Double, to target: Double = 16_000) -> [Float] {
    guard rate != target, !samples.isEmpty else { return samples }
    let count = Int(Double(samples.count) * target / rate)
    return (0..<count).map { index in
        let position = Double(index) * rate / target
        let low = Int(position)
        let high = min(low + 1, samples.count - 1)
        let fraction = Float(position - Double(low))
        return samples[low] * (1 - fraction) + samples[high] * fraction
    }
}

// MARK: faces

@MainActor
func faces(into folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func write(_ name: String, _ pose: Pose) throws {
        guard let image = FaceView.image(pose, size: CGSize(width: 640, height: 400)),
              let destination = CGImageDestinationCreateWithURL(folder.appending(path: "\(name).png") as CFURL,
                                                                UTType.png.identifier as CFString, 1, nil)
        else { throw NSError(domain: "ccrun", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't render \(name)"]) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        print("  \(folder.appending(path: "\(name).png").path)")
    }
    for mood in [Mood.idle, .listening, .thinking, .speaking, .surprised] {
        var performance = FacePerformance(origin: 0)
        performance.set(mood, at: 0)
        try write("mood-\(mood.rawValue)", performance.pose(at: 2))
    }
    for viseme in [Viseme.ah, .oo, .ee] {
        let face = Mood.speaking.expression.face
        try write("viseme-\(viseme.rawValue)",
                  Pose(face: Face(face.eye, viseme.mouth, sharpness: face.sharpness), offset: .zero, tilt: 0, muzzle: .zero))
    }
}

/// The app's window as the app loads it, rendered once it is ready.
@MainActor
func window(into file: URL) async throws {
    let companion = Companion()
    await companion.prepare()
    print("phase: \(companion.phase)")
    let view = ContentView(companion: companion).frame(width: 760, height: 620)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.cgImage,
          let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "ccrun", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't render the window"]) }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("  \(file.path)")
}

if let file = option("--window") {
    try await window(into: URL(fileURLWithPath: file))
    exit(0)
}

if let folder = option("--faces") {
    try await MainActor.run { try faces(into: URL(fileURLWithPath: folder)) }
    exit(0)
}

// MARK: the "microphone" and "speakers"

/// Plays a script of speech into the loop at the pace it was spoken, and
/// keeps the replies' schedule as the speakers would, mixing a share of them
/// back into what the loop hears.
final class Played: AudioIO, @unchecked Sendable {
    let buffer = SampleBuffer()
    let rate: Double
    let echo: Float
    private let lock = NSLock()
    /// Replies, at 16 kHz, with when they start and where they were cut off.
    private var clips: [(start: Double, samples: [Float], cut: Double)] = []
    private var end = 0.0
    private(set) var firstPlayed: Double?

    init(rate: Double, echo: Float) {
        self.rate = rate
        self.echo = echo
    }

    func play(_ samples: [Float]) -> (start: Double, end: Double) {
        lock.withLock {
            let start = max(Duplex.now, end)
            end = start + Double(samples.count) / rate
            clips.append((start, resample(samples, from: rate), .infinity))
            firstPlayed = firstPlayed ?? start
            return (start, end)
        }
    }

    func silence() {
        lock.withLock {
            let now = Duplex.now
            clips = clips.filter { $0.start <= now }.map { ($0.start, $0.samples, min($0.cut, now)) }
            end = now
        }
    }

    /// What was played, unattenuated: the loop measures the echo against it.
    func reference(from start: Double, to end: Double) -> [Float] {
        let count = max(0, Int((end - start) * 16_000))
        return (0..<count).map { leak(at: start + Double($0) / 16_000) / max(echo, 1e-9) }
    }

    var backlog: Double { lock.withLock { max(0, end - Duplex.now) } }

    /// Forget when the last reply started, to wait for the next one.
    func markReply() { lock.withLock { firstPlayed = nil } }

    /// What the speakers put back into the microphone at this moment.
    func leak(at time: Double) -> Float {
        lock.withLock {
            var value: Float = 0
            for clip in clips where clip.start <= time && time < clip.cut {
                let index = Int((time - clip.start) * 16_000)
                if index < clip.samples.count { value += clip.samples[index] * echo }
            }
            return value
        }
    }
}

/// Feeds `audio`'s buffer in real time: speech, then silence, with the echo mixed in.
final class Mouth: @unchecked Sendable {
    let audio: Played
    private var fed = 0
    private let origin = Duplex.now

    init(_ audio: Played) { self.audio = audio }

    /// Deliver `samples` (or silence for `seconds`) at the pace of real time.
    func deliver(_ samples: [Float]) async {
        var at = 0
        while at < samples.count {
            let due = Int((Duplex.now - origin) * 16_000)
            if due > fed {
                let count = min(due - fed, samples.count - at)
                var block = Array(samples[at..<(at + count)])
                for index in block.indices { block[index] += audio.leak(at: origin + Double(fed + index) / 16_000) }
                audio.buffer.append(block)
                fed += count
                at += count
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func pause(_ seconds: Double) async { await deliver([Float](repeating: 0, count: Int(seconds * 16_000))) }

    /// Silence until the reply in progress has finished or been cut off.
    func pauseForReply(after count: Int, limit: Double = 30) async {
        let deadline = Duplex.now + limit
        while Report.ended() <= count && Duplex.now < deadline { await pause(0.05) }
    }

    /// Silence until the next reply has been playing for `seconds`.
    func pause(intoReply seconds: Double, limit: Double = 30) async {
        let deadline = Duplex.now + limit
        while (audio.firstPlayed.map { Duplex.now - $0 < seconds } ?? true) && Duplex.now < deadline { await pause(0.05) }
    }
}

// MARK: the conversation

let echo = Float(option("--echo") ?? "0.05") ?? 0.05
guard let voiceURL = Resources.voice, let espeak = Resources.espeakData, let vadURL = Resources.vad else {
    print("missing the voice or the voice detector: run scripts/fetch-models.sh, keep voice-forge beside this checkout")
    exit(1)
}
let model = ModelCatalog.model(option("--model")) ?? ModelCatalog.recommended
guard let directory = ModelStore.location(of: model) else {
    print("\(model.name) isn't downloaded: choose it in the app's settings, or pass --model with one that is")
    exit(1)
}

say("loading the voice, recognition and \(model.name)…")
let voice = try Voice(model: voiceURL, espeakData: espeak)
let recognizer = try await Recognizer.load()
let brain = try await Brain(model: model, at: directory)
try await brain.warmUp()
say("loaded")

func speech(_ text: String) throws -> [Float] { resample(try voice.speak(text), from: voice.sampleRate) }

let audio = Played(rate: voice.sampleRate, echo: echo)
let mouth = Mouth(audio)

/// What happened, for the summary.
final class Tally: @unchecked Sendable {
    let lock = NSLock()
    var spokeUntil = 0.0
    var latencies: [Double] = []
    var waitingForReply = false
    var replies = 0
    var interruptions = 0
    var timing = PauseModel()
}
let tally = Report.tally

let loop = Loop(audio: audio, vad: try SileroVAD(model: vadURL), recognizer: recognizer, brain: brain, voice: voice,
                log: nil, timing: PauseModel(), emit: Report.handle)

/// Away from the main actor: the loop calls it from its own.
enum Report {
    static let tally = Tally()

    /// Replies finished or cut off so far.
    static func ended() -> Int { tally.lock.withLock { tally.replies + tally.interruptions } }

    static func handle(_ event: LoopEvent) {
    switch event {
    case let .mood(mood): say("face: \(mood.rawValue)")
    case let .heard(text): say("heard: \(text)")
    case let .saying(text, _, start):
        tally.lock.withLock {
            if tally.waitingForReply {
                tally.latencies.append(start - tally.spokeUntil)
                tally.waitingForReply = false
            }
        }
        say("saying: \(text)")
    case .hushed: say("hushed")
    case let .replied(text, interrupted):
        tally.lock.withLock {
            if interrupted { tally.interruptions += 1 } else { tally.replies += 1 }
        }
        say(interrupted ? "cut off after: \(text)" : "replied")
    case let .timing(model):
        tally.lock.withLock { tally.timing = model }
        say(String(format: "timing: waits %.2f s after a statement, %d pauses learned, %d cut-ins",
                   model.wait(after: .statement), model.pauses.count, model.cutIns))
    case let .overlap(heard, saying, loudness, echo):
        let loud = loudness.map { String(format: "%.1fx its echo", $0) } ?? "echo level not learned yet"
        say("overlap: heard \"\(heard)\" (\(loud)) while saying \"\(saying)\" → \(echo ? "echo" : "interruption")")
    case let .echoLevel(level):
        if let leak = level.leak { say(String(format: "echo comes back at %.3f of what was played", leak)) }
    case let .problem(message): say("PROBLEM: \(message)")
    }
    }
}

let running = Task { await loop.run() }

/// One turn: phrases with pauses between them, then the time it ended.
func turn(_ phrases: [String], pausing: Double = 0.55) async throws {
    for (index, phrase) in phrases.enumerated() {
        say("you: \(phrase)")
        await mouth.deliver(try speech(phrase))
        if index + 1 < phrases.count { await mouth.pause(pausing) }
    }
    tally.lock.withLock {
        tally.spokeUntil = Duplex.now
        tally.waitingForReply = true
    }
    audio.markReply()
}

await mouth.pause(1)
try await turn(["Hi there.", "I just got back from a long walk by the river."])
await mouth.pauseForReply(after: 0)
await mouth.pause(1.5)
try await turn(["What should I cook tonight?", "Something quick."])
// Talk over the reply a second after it starts.
await mouth.pause(intoReply: 1.0)
try await turn(["Actually, wait. I don't have any eggs."])
await mouth.pauseForReply(after: 2)
await mouth.pause(1.5)
try await turn(["Tell me a little about yourself."])
await mouth.pauseForReply(after: 3)
await mouth.pause(2)
running.cancel()

tally.lock.withLock {
    print("")
    print("echo leaking back: \(echo)")
    print("replies finished: \(tally.replies), interrupted: \(tally.interruptions)")
    print("from the end of your speech to the reply's first sound: "
          + tally.latencies.map { String(format: "%.2f s", $0) }.joined(separator: ", "))
    print(String(format: "learned: %d pauses, waits %.2f s after a statement, %d cut-ins",
                 tally.timing.pauses.count, tally.timing.wait(after: .statement), tally.timing.cutIns))
}
exit(0)
