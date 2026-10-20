import CompanionCore
import Foundation
import Observation

/// Everything the app shows and controls, on the main actor. The Mac app and,
/// later, the iPad and iPhone apps are views of this.
@MainActor @Observable
public final class Companion {
    public enum Phase: Equatable {
        case idle
        case loading(String)
        /// No language model on this device yet.
        case needsModel
        case ready
        case live
        case failed(String)
    }

    public struct Line: Identifiable, Equatable {
        public let id: Int
        public let speaker: Turn.Speaker
        public var text: String
        public var interrupted = false
    }

    public private(set) var phase: Phase = .idle
    public private(set) var lines: [Line] = []
    public private(set) var face = FacePerformance(origin: Duplex.now)
    public private(set) var timing: PauseModel
    public private(set) var notice: String?
    /// A model download under way, from 0 to 1.
    public private(set) var downloading: (model: ChatModel, progress: Double)?

    /// The language model, chosen in settings; remembered.
    public private(set) var model: ChatModel =
        ModelCatalog.model(UserDefaults.standard.string(forKey: "model")) ?? ModelCatalog.recommended

    /// Cancel the voice's echo so it can speak out of the speakers. Off only
    /// for someone on headphones who wants Apple's processing out of the way.
    /// Remembered; takes effect the next time the conversation starts.
    public var echoCancellation: Bool = UserDefaults.standard.object(forKey: "echoCancellation") as? Bool ?? true {
        didSet { UserDefaults.standard.set(echoCancellation, forKey: "echoCancellation") }
    }

    public var listening: Bool { phase == .live }
    public var level: Float { audio?.buffer.level ?? 0 }

    private var recognizer: Recognizer?
    private var brain: Brain?
    private var voice: Voice?
    private var audio: Duplex?
    private var loop: Task<Void, Never>?
    private var events: Task<Void, Never>?
    private var nextLine = 0
    /// How loud its voice comes back through the canceller here, learned while
    /// it talks; kept between presses of Talk while the app is open.
    private var echoLevel = EchoLevel()

    public init() {
        timing = (try? JSONDecoder().decode(PauseModel.self, from: Data(contentsOf: Resources.timing))) ?? PauseModel()
    }

    // MARK: loading

    public func prepare() async {
        guard phase == .idle || phase.isFailure else { return }
        do {
            guard let voiceURL = Resources.voice, let espeak = Resources.espeakData else {
                throw Problem("The voice is missing: build with build.sh, or keep voice-forge beside this checkout.")
            }
            guard Resources.vad != nil else {
                throw Problem("The voice detector is missing: run scripts/fetch-models.sh.")
            }
            phase = .loading("Loading the voice…")
            voice = try await Task.detached { try Voice(model: voiceURL, espeakData: espeak) }.value
            phase = .loading("Loading speech recognition…")
            recognizer = try await Recognizer.load { [weak self] progress in
                Task { @MainActor in
                    if progress < 1 { self?.phase = .loading("Downloading speech recognition… \(Int(progress * 100))%") }
                }
            }
            try await loadBrain()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func loadBrain() async throws {
        guard let directory = ModelStore.location(of: model) else {
            phase = .needsModel
            return
        }
        phase = .loading("Loading \(model.name)…")
        brain = nil
        let brain = try await Brain(model: model, at: directory)
        try await brain.warmUp()
        self.brain = brain
        phase = .ready
    }

    public func isDownloaded(_ model: ChatModel) -> Bool { ModelStore.isDownloaded(model) }

    /// Switch to `model`, downloading it first if need be.
    public func use(_ model: ChatModel) async {
        stop()
        self.model = model
        UserDefaults.standard.set(model.id, forKey: "model")
        do {
            if !ModelStore.isDownloaded(model) {
                downloading = (model, 0)
                try await ModelStore.download(model) { [weak self] progress in
                    Task { @MainActor in self?.downloading = (model, progress) }
                }
                downloading = nil
            }
            if recognizer != nil { try await loadBrain() }
        } catch {
            downloading = nil
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: the conversation

    public func start() async {
        guard phase == .ready, let recognizer, let brain, let voice, let vadURL = Resources.vad else { return }
        notice = nil
        guard await Duplex.permission() else {
            notice = AudioFailure.noPermission.localizedDescription
            return
        }
        do {
            let audio = try Duplex(sampleRate: voice.sampleRate, echoCancellation: echoCancellation)
            try audio.start()
            self.audio = audio
            let log = try? ConversationLog(directory: Resources.conversations)
            let (stream, continuation) = AsyncStream<LoopEvent>.makeStream()
            let loop = Loop(audio: audio, vad: try SileroVAD(model: vadURL), recognizer: recognizer, brain: brain,
                            voice: voice, log: log, timing: timing, echoLevel: echoLevel,
                            emit: Self.forward(to: continuation))
            self.loop = Task { await loop.run() }
            events = Task { [weak self] in
                for await event in stream { self?.handle(event) }
            }
            phase = .live
        } catch {
            audio?.stop()
            audio = nil
            notice = "Couldn't start listening: \(error.localizedDescription)"
        }
    }

    public func stop() {
        loop?.cancel()
        events?.cancel()
        loop = nil
        events = nil
        audio?.stop()
        audio = nil
        face.hush(at: Duplex.now)
        face.set(.idle, at: Duplex.now)
        if phase == .live { phase = .ready }
    }

    public func toggle() async {
        if phase == .live { stop() } else { await start() }
    }

    /// Forget how this person pauses and start learning again.
    public func resetTiming() {
        timing = PauseModel()
        save(timing)
    }

    private func handle(_ event: LoopEvent) {
        let now = Duplex.now
        switch event {
        case let .mood(mood):
            face.set(mood, at: now)
        case let .heard(text):
            append(.person, text)
        case let .saying(text, words, start):
            face.say(words, at: start)
            if let index = lines.lastIndex(where: { $0.id == replyLine }) {
                lines[index].text += " " + text
            } else {
                append(.companion, text)
                replyLine = lines.last?.id
            }
        case let .hushed(at):
            face.hush(at: at)
        case let .replied(text, interrupted):
            if interrupted, let index = lines.lastIndex(where: { $0.id == replyLine }) {
                lines[index].text = text.isEmpty ? "…" : text
                lines[index].interrupted = true
            }
            replyLine = nil
        case let .timing(model):
            timing = model
            save(model)
        case let .echoLevel(level):
            echoLevel = level
        case .overlap:
            break
        case let .problem(message):
            notice = message
        }
    }

    /// Made outside the main actor: the loop calls it from its own, and a
    /// closure formed in a main-actor method would be taken as the main actor's.
    nonisolated static func forward(to continuation: AsyncStream<LoopEvent>.Continuation)
        -> @Sendable (LoopEvent) -> Void {
        { continuation.yield($0) }
    }

    /// The line the current reply is being written into.
    private var replyLine: Int?

    private func append(_ speaker: Turn.Speaker, _ text: String) {
        lines.append(Line(id: nextLine, speaker: speaker, text: text))
        nextLine += 1
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
    }

    private func save(_ timing: PauseModel) {
        do {
            try FileManager.default.createDirectory(at: Resources.support, withIntermediateDirectories: true)
            try JSONEncoder().encode(timing).write(to: Resources.timing, options: .atomic)
        } catch {
            notice = "Couldn't save what it learned about your pauses: \(error.localizedDescription)"
        }
    }
}

extension Companion.Phase {
    var isFailure: Bool { if case .failed = self { true } else { false } }
}
