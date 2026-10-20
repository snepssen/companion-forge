// Recorded speech through the live loop in real time, for measuring without a
// microphone: the turn taker, recognition, the model and the voice as the app
// runs them, with the reply's own voice leaking back into the "microphone" at
// a chosen level, as it would past the echo canceller.
//
//   ccrun                       a short conversation, with an interruption
//   ccrun --echo 0.3            the same with far more echo leaking through
//   ccrun --shake               with the phone shaken between turns
//   ccrun --model qwen3-4b-instruct-2507-4bit
//   ccrun --faces <folder>      the face in each mood and some visemes, as PNGs
//         [--style smooth] [--colour magenta] [--hearing 0.05]   (also for --window)
//   ccrun --window <file.png>   the app's window, loaded as the app loads it
//   ccrun --memory              earlier conversations written up, then recalled
//   ccrun --icon <file.png>     the app icon, 1024 px
//   ccrun --recall              how the embedder ranks notes, for the thresholds
//   ccrun --long [--anticipate] a long conversation: prompt re-reading and first-word times
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

/// What iOS would hold against the app: its physical footprint, now and at
/// its peak, in GB. On Apple silicon it includes what MLX has on the GPU.
func footprint() -> (now: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return (0, 0) }
    return (Double(info.phys_footprint) / 1e9, Double(info.ledger_phys_footprint_peak) / 1e9)
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

/// --style, --colour and --hearing, for the renders.
@MainActor
func look() -> (style: VisorStyle, colour: VisorColour, hearing: Double) {
    (VisorStyle(rawValue: option("--style") ?? "") ?? .panel, VisorColour(rawValue: option("--colour") ?? "") ?? .cyan,
     Double(option("--hearing") ?? "0") ?? 0)
}

@MainActor
func faces(into folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func write(_ name: String, _ pose: Pose) throws {
        let look = look()
        guard let image = FaceView.image(pose, size: CGSize(width: 640, height: 400), colour: look.colour.color,
                                         style: look.style, hearing: look.hearing),
              let destination = CGImageDestinationCreateWithURL(folder.appending(path: "\(name).png") as CFURL,
                                                                UTType.png.identifier as CFString, 1, nil)
        else { throw NSError(domain: "ccrun", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't render \(name)"]) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        print("  \(folder.appending(path: "\(name).png").path)")
    }
    for mood in [Mood.idle, .listening, .thinking, .speaking, .cheerful, .surprised, .waking] {
        var performance = FacePerformance(origin: 0)
        performance.set(mood, at: 0)
        try write("mood-\(mood.rawValue)", performance.pose(at: 2))
    }
    var looking = FacePerformance(origin: 0)
    for (index, at) in [3.0, 9.0, 17.0].enumerated() {
        try write("gaze-idle-\(index + 1)", looking.pose(at: at))
    }
    looking.set(.thinking, at: 0)
    try write("gaze-thinking", looking.pose(at: 2))
    try write("shaken", Felt(offset: Point(-0.06, 0.03), tilt: -9, shaken: 1).apply(to: FacePerformance(origin: 0).pose(at: 2)))
    for viseme in [Viseme.ah, .oo, .ee] {
        let face = Mood.speaking.expression.face
        try write("viseme-\(viseme.rawValue)",
                  Pose(face: Face(face.eye, viseme.mouth, sharpness: face.sharpness), offset: .zero, tilt: 0, muzzle: .zero))
    }
}

/// The app's window as the app loads it, rendered once it is ready.
@MainActor
func window(into file: URL) async throws {
    UserDefaults.standard.set(look().style.rawValue, forKey: "visorStyle")
    UserDefaults.standard.set(look().colour.rawValue, forKey: "visorColour")
    let companion = Companion()
    companion.listensWhenReady = false  // nobody here to listen to
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

/// The app icon: the visor in its idle smirk, on black, 1024 px square.
@MainActor
func icon(into file: URL) throws {
    var performance = FacePerformance(origin: 0)
    performance.set(.idle, at: 0)
    var pose = performance.pose(at: 2)
    pose.offset = .zero
    pose.tilt = 0
    pose.muzzle = .zero
    guard let image = FaceView.image(pose, size: CGSize(width: 512, height: 512)),
          let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "ccrun", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't render the icon"]) }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("  \(file.path)")
}

if let file = option("--icon") {
    try await MainActor.run { try icon(into: URL(fileURLWithPath: file)) }
    exit(0)
}

if let file = option("--window") {
    try await window(into: URL(fileURLWithPath: file))
    exit(0)
}

/// How the embedder ranks a few notes for a few things someone might say,
/// and how alike it finds a repeat and a change: for setting the thresholds.
func recall() async throws {
    let embedder = try await Embedder.load { print(String(format: "  downloading the embedder… %.0f%%", $0 * 100)) }
    let notes = ["They have no eggs at home.", "They walked by the river this evening and loved it.",
                 "Their dog is called Biscuit.", "They work as a nurse on night shifts.",
                 "They are learning to play the guitar.", "Their sister Ana is visiting next week."]
    let queries = ["What should I make for breakfast?", "I took the dog out earlier", "work was exhausting tonight",
                   "I practiced some chords today", "do you remember where I went walking?", "My dog Biscuit is sick.",
                   "Guess who's coming to stay with me?", "What's the weather like?"]
    let noteVectors = await embedder.embed(notes)
    for query in queries {
        let vector = await embedder.embed([query], query: true)[0]
        print(query)
        for (note, noteVector) in zip(notes, noteVectors) {
            print(String(format: "   %.2f  %@", MemoryStore.cosine(vector, noteVector), note))
        }
    }
    let pairs = [("They have no eggs at home.", "They don't have any eggs in the house."),
                 ("Their dog is called Biscuit.", "Their dog Biscuit is three years old."),
                 ("They live in York.", "They moved to Leeds."),
                 ("They work as a nurse on night shifts.", "They are learning to play the guitar.")]
    for (a, b) in pairs {
        let v = await embedder.embed([a, b])
        print(String(format: "%.2f  %@ / %@", MemoryStore.cosine(v[0], v[1]), a, b))
    }
}

/// Two earlier conversations written up by the model, then new things said
/// to it: what comes to mind, and the reply with it. In a folder of its own,
/// so the app's memory is untouched.
func memoryRun() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ccrun-memory-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let conversations = folder.appending(path: "Conversations")
    let model = ModelCatalog.model(option("--model")) ?? ModelCatalog.recommended
    guard let directory = ModelStore.location(of: model) else { print("\(model.name) isn't downloaded"); return }
    let brain = try await Brain(model: model, at: directory)
    let embedder = try await Embedder.load()
    let memory = Memory(file: folder.appending(path: "memory.json"), conversations: conversations, embedder: embedder)

    let day: TimeInterval = 86_400
    let earlier: [(daysAgo: Double, turns: [(Turn.Speaker, String)])] = [
        (6, [(.person, "Hi! I'm Sam, by the way."), (.companion, "Nice to meet you, Sam!"),
             (.person, "I work night shifts as a nurse, so I'm usually up at odd hours."),
             (.companion, "That sounds tiring. How do you wind down?"),
             (.person, "Mostly walks with my dog Biscuit. He's a beagle and he's obsessed with the river."),
             (.companion, "Biscuit sounds like great company."),
             (.person, "Oh, and my sister Ana is visiting next Saturday. I'm a bit nervous, we haven't talked in a year."),
             (.companion, "That's a big visit. I hope it goes well."),
             (.person, "Anyway, what's the capital of Australia?"), (.companion, "Canberra.")]),
        (2, [(.person, "I've started learning the guitar. My fingers hurt so much."),
             (.companion, "That's normal at first. What are you practising?"),
             (.person, "Just G, C and D for now. I want to play a song for Ana when she comes."),
             (.companion, "That's a lovely idea."),
             (.person, "Also I ran out of eggs, I keep forgetting to buy them."), (.companion, "Add them to a list!")]),
    ]
    for conversation in earlier {
        let started = Date() - conversation.daysAgo * day
        let log = try ConversationLog(directory: conversations, started: started)
        for (index, (speaker, text)) in conversation.turns.enumerated() {
            try log.append(Turn(speaker, text, at: started + Double(index) * 20))
        }
    }

    let began = Duplex.now
    let added = try await memory.writeUp(with: brain)
    print(String(format: "wrote %d notes in %.1f s:", added, Duplex.now - began))
    for note in await memory.notes {
        print("  \(note.lasting ? "(lasting) " : "")[\(note.turns.lowerBound)-\(note.turns.upperBound)] \(note.text)")
    }
    let again = try await memory.writeUp(with: brain)
    print("written up again: \(again) new notes")

    let asked = ["What should I make for breakfast?", "Ugh, work was exhausting tonight.",
                 "Do you remember what I told you about my sister?", "What's the weather like where you are?",
                 "I practised those chords again today."]
    for text in asked {
        print("")
        print("you: \(text)")
        let started = Duplex.now
        let recollection = await memory.recollect(for: text)
        print(String(format: "  recalled in %.0f ms:", (Duplex.now - started) * 1000))
        for (note, score) in await memory.scores(for: text) { print(String(format: "      %.3f %@", score, note.text)) }
        for note in recollection.notes { print("    \(note.text)") }
        if !recollection.excerpt.isEmpty {
            print("    and word for word:")
            for turn in recollection.excerpt { print("      \(turn.speaker == .person ? "them" : "it"): \(turn.text)") }
        }
        if !CommandLine.arguments.contains("--no-replies") {
            let reply = try await brain.reply(to: [Turn(.person, text)], remembering: recollection) { _ in }
            print("  companion: \(reply)")
        }
    }
}

/// A long conversation in text: how much of each prompt the model has to read
/// again, and how soon its first words come, as the conversation outgrows
/// the window of turns it is shown.
func longRun() async throws {
    let model = ModelCatalog.model(option("--model")) ?? ModelCatalog.recommended
    guard let directory = ModelStore.location(of: model) else { print("\(model.name) isn't downloaded"); return }
    let brain = try await Brain(model: model, at: directory)
    try await brain.warmUp()
    let lines = ["Hi there.", "I had a long day at work.", "I'm a nurse, nights mostly.", "It was busy, three admissions.",
                 "One of them was a kid with a broken arm.", "He was really brave about it.", "Anyway, I'm home now.",
                 "My dog is asleep on the sofa.", "His name is Biscuit.", "He's a beagle.", "What should I eat?",
                 "I don't have eggs.", "Pasta sounds good.", "What sauce?", "I have tomatoes and garlic.",
                 "Okay, I'll do that.", "Do you like music?", "I'm learning guitar.", "Just three chords so far.",
                 "My fingers hurt.", "Any tips?", "Thanks, goodnight."]
    var turns: [Turn] = []
    for (index, line) in lines.enumerated() {
        turns.append(Turn(.person, line))
        let started = Duplex.now
        let first = Clock()
        let reply = try await brain.reply(to: turns) { _ in first.mark() }
        let (read, length) = await brain.lastPrompt
        print(String(format: "%2d  read %4d of %4d tokens, first words %.2f s", index + 1, read, length,
                     (first.at ?? Duplex.now) - started))
        turns.append(Turn(.companion, reply))
        // As the loop does once a reply has been said.
        if CommandLine.arguments.contains("--anticipate") { try await brain.anticipate(turns) }
    }
}

/// When something first happened, from any thread.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Double?
    var at: Double? { lock.withLock { first } }
    func mark() { lock.withLock { if first == nil { first = Duplex.now } } }
}

if CommandLine.arguments.contains("--long") {
    try await longRun()
    exit(0)
}

if CommandLine.arguments.contains("--memory") {
    try await memoryRun()
    exit(0)
}

if CommandLine.arguments.contains("--recall") {
    try await recall()
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
let embedder = try await Embedder.load()
let memoryFolder = FileManager.default.temporaryDirectory.appending(path: "ccrun-\(UUID().uuidString)")
let memory = Memory(file: memoryFolder.appending(path: "memory.json"), conversations: memoryFolder, embedder: embedder)
say(String(format: "loaded; footprint %.2f GB", footprint().now))

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
                memory: memory, log: nil, timing: PauseModel(), emit: Report.handle)

/// Away from the main actor: the loop calls it from its own.
enum Report {
    static let tally = Tally()

    /// Replies finished or cut off so far.
    static func ended() -> Int { tally.lock.withLock { tally.replies + tally.interruptions } }

    static func handle(_ event: LoopEvent) {
    switch event {
    case let .mood(mood): say("face: \(mood.rawValue)")
    case let .heard(text): say("heard: \(text)")
    case let .recalled(recollection):
        for note in recollection.notes { say("recalled: \(note.text)") }
        for turn in recollection.excerpt { say("  word for word: \(turn.text)") }
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
    case let .drafted(t):
        say(String(format: "draft: heard %.2f s, recalled %.2f, first words %.2f, first sentence %.2f, its voice %.2f; read %d of %d prompt tokens",
                   t.transcribed, t.recalled, t.firstWords, t.firstSentence, t.firstVoice, t.promptRead, t.promptLength))
    case let .echoLevel(level):
        if let leak = level.leak { say(String(format: "echo comes back at %.3f of what was played", leak)) }
    case let .problem(message): say("PROBLEM: \(message)")
    }
    }
}

let running = Task { await loop.run() }

// Shaking, as the phone's motion sensors would report it.
let motion = MotionSense()
motion.onShaken = { complaint in
    Task {
        let spoke = await loop.interject(complaint)
        say(spoke ? "shaken, and said so" : "shaken, but somebody was talking")
    }
}
func shake(for seconds: Double) async {
    say("(shaking the phone)")
    let end = Duplex.now + seconds
    var step = 0
    while Duplex.now < end {
        motion.feel(acceleration: Point(step % 12 < 6 ? 2.5 : -2.5, 0.4), rotation: 2, at: Duplex.now)
        step += 1
        try? await Task.sleep(for: .milliseconds(16))
    }
}

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
await mouth.pauseForReply(after: Report.ended())
await mouth.pause(1.5)
if CommandLine.arguments.contains("--shake") {
    let before = Report.ended()
    async let silence: Void = mouth.pause(2)
    await shake(for: 1.5)
    await silence
    await mouth.pauseForReply(after: before)
    await mouth.pause(1)
}
try await turn(["What should I cook tonight?", "Something quick."])
// Talk over the reply a second after it starts.
await mouth.pause(intoReply: 1.0)
let beforeEggs = Report.ended()
try await turn(["Actually, wait. I don't have any eggs."])
// The reply it cut off counts as one ending; wait for the next.
await mouth.pauseForReply(after: beforeEggs + 1)
await mouth.pause(1.5)
let beforeLast = Report.ended()
try await turn(["Tell me a little about yourself."])
await mouth.pauseForReply(after: beforeLast)
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
    let (now, peak) = footprint()
    print(String(format: "footprint with %@, recognition, the embedder and the voice: %.2f GB now, %.2f GB at peak",
                 model.name, now, peak))
}
try? FileManager.default.removeItem(at: memoryFolder)
exit(0)
