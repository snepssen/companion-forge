import CompanionCore
import Foundation
import Observation
import SampleBuffer
import SileroVAD

/// Everything the app shows and controls, on the main actor. The Mac app and
/// the iPad and iPhone apps are views of this.
///
/// There is no talk button: it listens as soon as it is ready, for as long as
/// the app is open (and, on a phone or tablet, in front). Quitting stops it.
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
        public var at = Date()
    }

    public private(set) var phase: Phase = .idle
    public private(set) var lines: [Line] = []
    public private(set) var face = FacePerformance(origin: Duplex.now)
    public private(set) var timing: PauseModel
    public private(set) var notice: String?
    /// A model download under way, from 0 to 1.
    public private(set) var downloading: (model: ChatModel, progress: Double)?
    /// What it remembers, newest first.
    public private(set) var notes: [Note] = []
    /// Notes are being written from a conversation.
    public private(set) var writingUp = false
    /// What came to mind for the last thing they said.
    public private(set) var recalled: [Note] = []

    /// The language model, chosen in settings; remembered.
    public private(set) var model: ChatModel =
        ModelCatalog.model(UserDefaults.standard.string(forKey: "model")) ?? ModelCatalog.recommended

    /// Cancel the voice's echo so it can speak out of the speakers. Off only
    /// for someone on headphones who wants Apple's processing out of the way.
    /// Remembered; listening starts again with it at once.
    public var echoCancellation: Bool = UserDefaults.standard.object(forKey: "echoCancellation") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(echoCancellation, forKey: "echoCancellation")
            guard echoCancellation != oldValue, phase == .live else { return }
            pause()
            Task { await start() }
        }
    }

    /// Place the voice where the device is, and keep it there as the head
    /// turns on headphones that track it. Remembered; applied at once.
    public var spatialVoice: Bool = UserDefaults.standard.object(forKey: "spatialVoice") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(spatialVoice, forKey: "spatialVoice")
            guard spatialVoice != oldValue, phase == .live else { return }
            pause()
            Task { await start() }
        }
    }

    /// Who it is: playful, gentle or deadpan. Remembered; from the next reply on.
    public var personality: Personality = Personality(rawValue: UserDefaults.standard.string(forKey: "personality") ?? "")
        ?? .playful {
        didSet {
            UserDefaults.standard.set(personality.rawValue, forKey: "personality")
            let (brain, personality) = (brain, personality)
            Task { await brain?.set(personality) }
        }
    }

    /// Start listening by itself once ready. Off only for measuring (ccrun),
    /// where nobody is there to be listened to.
    public var listensWhenReady = true

    public var listening: Bool { phase == .live }
    /// How the device is moving, for the face to follow.
    public let motion = MotionSense()
    /// Where whoever is talking is, for the face to turn to.
    public let attention = AttentionSense()
    private var watcher: Watcher?

    /// Watch with the front camera for who is talking, and look at them.
    /// Off unless chosen; nothing it sees is kept. Remembered.
    public var watching: Bool = UserDefaults.standard.bool(forKey: "watching") {
        didSet {
            UserDefaults.standard.set(watching, forKey: "watching")
            guard watching != oldValue, phase == .live else { return }
            Task { await watch(watching) }
        }
    }
    public var level: Float { audio?.buffer.level ?? 0 }

    /// Music it hears, for the face to dance to.
    public let beat = BeatSense()
    /// How it dances when there's music with a steady kick: nodding, a
    /// figure of eight, or not at all (nil). Remembered.
    public var dance: Dance.Pattern? = Companion.storedDance {
        didSet {
            UserDefaults.standard.set(dance?.rawValue ?? "off", forKey: "dance")
            beat.pattern = dance
        }
    }
    private static var storedDance: Dance.Pattern? {
        let stored = UserDefaults.standard.string(forKey: "dance") ?? Dance.Pattern.infinity.rawValue
        return Dance.Pattern(rawValue: stored)
    }

    /// What its memory and logs are sealed with.
    private var sealer = Sealer.plain
    private var recognizer: Recognizer?
    private var brain: Brain?
    private var voice: Voice?
    private var audio: Duplex?
    private var loop: Task<Void, Never>?
    private var running: Loop?
    private var blurt: Blurt?
    private var events: Task<Void, Never>?
    private var nextLine = 0
    /// How loud its voice comes back through the canceller here, learned while
    /// it talks; kept between presses of Talk while the app is open.
    private var echoLevel = EchoLevel()
    private var memory: Memory?
    private var voiceprinter: Voiceprinter?

    /// Know its person's voice, so a guest is met kindly but told nothing
    /// and kept out of its memory. The voiceprint stays on this device,
    /// sealed with the rest. Remembered.
    public var tellsVoicesApart: Bool = UserDefaults.standard.object(forKey: "voices") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(tellsVoicesApart, forKey: "voices")
            guard tellsVoicesApart != oldValue, phase == .live else { return }
            pause()
            Task {
                if tellsVoicesApart { await loadVoiceprinter() }
                await start()
            }
        }
    }

    /// Whether it has learned its person's voice yet, for settings.
    public private(set) var knowsTheirVoice = false
    private var dictionary: Dictionary?
    private var writing: Task<Void, Never>?
    private var idleWatch: Task<Void, Never>?
    /// When anything was last said, by either of them.
    private var lastActivity = Duplex.now
    /// Notes are written once a conversation has been quiet this long.
    static let quietEnough = 45.0

    public init() {
        timing = (try? JSONDecoder().decode(PauseModel.self, from: Data(contentsOf: Resources.timing))) ?? PauseModel()
        motion.onShaken = { [weak self] complaint in
            Task { @MainActor in await self?.complain(complaint) }
        }
        motion.start()
    }

    // MARK: loading

    public func prepare() async {
        guard phase == .idle || phase.isFailure else { return }
        face.set(.waking, at: Duplex.now)
        defer { face.set(.idle, at: Duplex.now) }
        do {
            guard let voiceURL = Resources.voice, let espeak = Resources.espeakData else {
                throw Problem("The voice is missing: build with build.sh.")
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
            phase = .loading("Loading the memory…")
            let embedder = try await Embedder.load { [weak self] progress in
                Task { @MainActor in
                    if progress < 1 { self?.phase = .loading("Downloading the memory's embedder… \(Int(progress * 100))%") }
                }
            }
            Vault.protect(Resources.support)
            let (sealer, problem) = Vault.sealer()
            self.sealer = sealer
            memory = Memory(embedder: embedder, sealer: sealer)
            if let problem { notice = problem }
            if await memory?.locked == true {
                notice = "Its memory is there but couldn't be opened, so it's left untouched and nothing new is saved."
            }
            if tellsVoicesApart { await loadVoiceprinter() }
            dictionary = Resources.dictionary.flatMap(Dictionary.init(file:))
            notes = await memory?.notes ?? []
            try await loadBrain()
            writeUp()
            if listensWhenReady { await start() }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The voiceprint model, fetched the first time. Without it everyone is
    /// its person, as before; that's said, not hidden.
    private func loadVoiceprinter() async {
        guard voiceprinter == nil else { return }
        phase = .loading("Loading what knows your voice…")
        do {
            voiceprinter = try await Voiceprinter(.campplus)
        } catch {
            notice = "Couldn't load what knows your voice, so for now it takes anyone for you."
        }
    }

    private func loadBrain() async throws {
        guard let directory = ModelStore.location(of: model) else {
            phase = .needsModel
            return
        }
        phase = .loading("Loading \(model.name)…")
        face.set(.waking, at: Duplex.now)
        defer { face.set(.idle, at: Duplex.now) }
        brain = nil
        let brain = try await Brain(model: model, at: directory)
        await brain.set(personality)
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
            if recognizer != nil {
                try await loadBrain()
                if listensWhenReady { await start() }
            }
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
            let echoCancellation = echoCancellation
            func open(spatial: Bool) throws -> Duplex {
                let audio = try Duplex(sampleRate: voice.sampleRate, echoCancellation: echoCancellation, spatial: spatial)
                try audio.start()
                return audio
            }
            let audio: Duplex
            if spatialVoice, let spatial = try? open(spatial: true) {
                audio = spatial
            } else {
                // Better heard plainly than not at all.
                audio = try open(spatial: false)
                if spatialVoice { notice = "The spatial voice wouldn't start here, so it's speaking plainly." }
            }
            self.audio = audio
            beat.pattern = dance
            audio.buffer.listener = { [beat] block in beat.hear(block) }
            let log = try? ConversationLog(directory: Resources.conversations, sealer: sealer)
            let (stream, continuation) = AsyncStream<LoopEvent>.makeStream()
            let household = await memory?.household ?? Household()
            knowsTheirVoice = household.owner != nil
            let loop = Loop(audio: audio, vad: try SileroVAD(model: vadURL), recognizer: recognizer, brain: brain,
                            voice: voice, memory: memory, attention: attention, dictionary: dictionary, log: log,
                            voiceprinter: tellsVoicesApart ? voiceprinter : nil,
                            voices: tellsVoicesApart && voiceprinter != nil ? VoiceSense(household) : nil,
                            timing: timing,
                            echoLevel: echoLevel,
                            emit: Self.forward(to: continuation))
            lastActivity = Duplex.now
            idleWatch = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard let self else { continue }
                    // Late, and quiet a while: it nods off. Any voice wakes it.
                    if self.phase == .live, self.face.mood == .idle, Clock.isNight(),
                       Duplex.now - self.lastActivity > Clock.nodsOff {
                        self.face.set(.sleepy, at: Duplex.now)
                    }
                    guard Duplex.now - self.lastActivity > Self.quietEnough else { continue }
                    self.writeUp()
                }
            }
            self.loop = Task { await loop.run() }
            running = loop
            events = Task { [weak self] in
                for await event in stream { self?.handle(event) }
            }
            phase = .live
            if watching { await watch(true) }
            // Hello, if they've been away; a moment first, in case they speak.
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                await loop.greet()
            }
        } catch {
            audio?.stop()
            audio = nil
            notice = "Couldn't start listening: \(error.localizedDescription)"
        }
    }

    /// Stop listening, as the app leaves the screen or switches model, and
    /// write up the conversation.
    public func stop() {
        let wasLive = phase == .live
        pause()
        if wasLive { writeUp() }
    }

    /// Stop listening for a moment, to start again with something changed.
    func pause() {
        watcher?.stop()
        watcher = nil
        loop?.cancel()
        events?.cancel()
        idleWatch?.cancel()
        loop = nil
        running = nil
        events = nil
        idleWatch = nil
        audio?.stop()
        audio = nil
        face.hush(at: Duplex.now)
        face.set(.idle, at: Duplex.now)
        if phase == .live { phase = .ready }
    }

    // MARK: watching

    private func watch(_ on: Bool) async {
        watcher?.stop()
        watcher = nil
        guard on else { return }
        guard await Watcher.permission() else {
            notice = "To look at whoever is talking, allow Companion the camera in Settings."
            return
        }
        let watcher = Watcher(attention: attention)
        do {
            try watcher.start()
            self.watcher = watcher
        } catch {
            notice = error.localizedDescription
        }
    }

    // MARK: being shaken

    /// Say so. In a conversation it goes through the conversation, and only
    /// when nobody is talking; otherwise it is said on its own.
    func complain(_ complaint: String) async {
        face.set(.surprised, at: Duplex.now)
        if let running {
            if await running.interject(complaint) { return }
            return  // somebody is talking: wide eyes are enough
        }
        guard blurt == nil, let voice, phase == .ready || phase == .needsModel else { return }
        do {
            let (samples, mouth) = try await Task.detached { try voice.speakTimed(complaint) }.value
            let blurt = try Blurt(samples, rate: voice.sampleRate, spatial: spatialVoice)
            self.blurt = blurt
            face.say(mouth ?? Visemes.timeline(SpokenWord.estimate(complaint, duration: blurt.end - blurt.start)),
                     at: blurt.start)
            face.set(.speaking, at: blurt.start)
            append(.companion, complaint)
            try? await Task.sleep(for: .seconds(blurt.end - Duplex.now + 0.2))
            blurt.stop()
            self.blurt = nil
            face.set(.idle, at: Duplex.now)
        } catch {
            blurt = nil
            face.set(.idle, at: Duplex.now)
        }
    }

    // MARK: memory

    /// Write notes from whatever hasn't been written up, in the background.
    /// Talking stops it: the model is wanted for replies, and the rest is
    /// written next time it is quiet.
    func writeUp() {
        guard writing == nil, let memory, let brain else { return }
        writingUp = true
        writing = Task { [weak self] in
            do {
                try await memory.writeUp(with: brain)
            } catch is CancellationError {
            } catch {
                self?.notice = "Couldn't write up the conversation: \(error.localizedDescription)"
            }
            self?.notes = await memory.notes
            self?.writingUp = false
            self?.writing = nil
        }
    }

    public func forget(_ note: Note) async {
        do {
            try await memory?.forget(note.id)
        } catch {
            notice = "Couldn't forget that: \(error.localizedDescription)"
        }
        notes = await memory?.notes ?? []
    }

    /// Every note and every conversation log.
    public func forgetEverything() async {
        writing?.cancel()
        do {
            try await memory?.forgetEverything()
        } catch {
            notice = "Couldn't forget everything: \(error.localizedDescription)"
        }
        notes = await memory?.notes ?? []
        recalled = []
        lines = []
        knowsTheirVoice = false
        // The conversation holds the voices too: start it again without them.
        if phase == .live {
            pause()
            await start()
        }
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
            lastActivity = now
            // Someone is talking: the model is wanted for the reply.
            if mood == .listening {
                writing?.cancel()
                recalled = []
            }
        case let .recalled(recollection):
            recalled = recollection.notes
        case .memoryChanged:
            Task { notes = await memory?.notes ?? notes }
        case let .heard(text):
            append(.person, text)
        case let .saying(text, mouth, start):
            face.say(mouth, at: start)
            if let index = lines.lastIndex(where: { $0.id == replyLine }) {
                lines[index].text += " " + text
                lines[index].at = Date()
            } else {
                append(.companion, text)
                replyLine = lines.last?.id
            }
        case let .hushed(at):
            face.hush(at: at)
        case .withdrew:
            // The reply never sounded, so neither line stands: they were still
            // on the turn that had just closed.
            face.hush(at: now)
            if let replyLine, let index = lines.lastIndex(where: { $0.id == replyLine }) {
                lines.remove(at: index)
            }
            replyLine = nil
            if lines.last?.speaker == .person { lines.removeLast() }
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
        case .overlap, .drafted, .echoDelay, .voice, .ignored:
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
