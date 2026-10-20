import CompanionCore
import Foundation

/// What the loop tells the app.
public enum LoopEvent: Sendable {
    case mood(Mood)
    /// A turn of theirs, as it will be answered.
    case heard(String)
    /// The voice starts saying `words` at `start`, on `Duplex.now`'s clock.
    case saying(String, words: [SpokenWord], start: Double)
    /// The voice was cut off at this time.
    case hushed(at: Double)
    /// A reply, all of it or what was said before it was cut off.
    case replied(String, interrupted: Bool)
    case timing(PauseModel)
    /// How loud the reply comes back, as learned so far: kept for the next session.
    case echoLevel(EchoLevel)
    /// Speech over a reply: what it was transcribed as, how loud it was as a
    /// multiple of the reply's learned echo (nil before that is learned), and
    /// the verdict.
    case overlap(heard: String, saying: String, loudness: Double?, echo: Bool)
    case problem(String)
}

/// The live conversation: microphone frames through the voice detector into
/// the turn taker, and whatever it decides carried out.
///
/// A reply is drafted while the person is still pausing, from the moment the
/// pause is long enough to be worth a guess: transcribed, written by the model
/// and turned into speech, sentence by sentence, but held. If they carry on,
/// it is thrown away; if the pause runs to the learned wait, what is ready is
/// played at once and the rest follows as it is made. Most of the model's
/// time is spent inside the silence the person was leaving anyway.
public actor Loop {
    struct Said {
        let text: String
        let start: Double
        let end: Double
    }

    /// One reply, drafted, perhaps committed.
    struct Reply {
        var id = 0
        var person = ""
        var held: [(text: String, samples: [Float])] = []
        var said: [Said] = []
        var committed = false
        var written = false
        var finished = false
    }

    static let frame = SileroVAD.frame
    /// Audio kept from before the detector noticed speech, so the first
    /// syllable isn't clipped.
    static let preroll = 16_000 / 4

    private let audio: any AudioIO
    private let vad: SileroVAD
    private let recognizer: Recognizer
    private let brain: Brain
    private let voice: Voice
    private let log: ConversationLog?
    private let emit: @Sendable (LoopEvent) -> Void
    private var taker: TurnTaker
    private var history: [Turn] = []
    private var processed = 0
    private var turnStart = 0
    private var reply = Reply()
    private var draft: Task<Void, Never>?
    private var echoLevel: EchoLevel

    public init(audio: any AudioIO, vad: SileroVAD, recognizer: Recognizer, brain: Brain, voice: Voice, log: ConversationLog?,
         timing: PauseModel, echoLevel: EchoLevel = EchoLevel(), emit: @escaping @Sendable (LoopEvent) -> Void) {
        self.audio = audio
        self.vad = vad
        self.recognizer = recognizer
        self.brain = brain
        self.voice = voice
        self.log = log
        self.emit = emit
        taker = TurnTaker(model: timing)
        self.echoLevel = echoLevel
    }

    /// Until cancelled.
    public func run() async {
        vad.reset()
        while !Task.isCancelled {
            let available = audio.buffer.count
            while processed + Self.frame <= available {
                let samples = audio.buffer.read(processed, processed + Self.frame)
                processed += Self.frame
                let t = Double(processed) / 16_000
                let speech: Bool
                do {
                    speech = try vad.push(samples[...], at: t)
                } catch {
                    emit(.problem("The voice detector failed: \(error.localizedDescription)"))
                    return
                }
                listenForEcho(samples, behind: available - processed)
                act(taker.tick(at: t, speech: speech, probability: vad.probability), at: t)
            }
            finishIfSaid()
            // Keep what a turn could still need; a minute is more than any.
            audio.buffer.drop(before: min(turnStart, processed - 60 * 16_000))
            try? await Task.sleep(for: .milliseconds(20))
        }
        draft?.cancel()
    }

    private func act(_ action: TurnTaker.Action, at t: Double) {
        switch action {
        case .none:
            break
        case let .turnStarted(at):
            turnStart = max(0, Int(at * 16_000) - Self.preroll)
            emit(.mood(.listening))
        case .draft:
            startDraft()
        case .abandon:
            draft?.cancel()
            reply = Reply(id: reply.id + 1)
            emit(.mood(.listening))
        case .commit:
            commit()
        case let .overlap(since):
            check(overlapSince: since, reply: reply.id)
        }
    }

    /// While the reply plays, learn how loud it comes back. `behind` is how
    /// many samples the microphone has delivered since this frame.
    private func listenForEcho(_ frame: [Float], behind: Int) {
        guard case .replying = taker.phase, audio.backlog > 0 else { return }
        let end = Duplex.now - Double(behind) / 16_000
        echoLevel.hear(mic: frame, played: audio.reference(from: end - Double(frame.count) / 16_000, to: end))
    }

    // MARK: drafting

    private func startDraft() {
        let id = reply.id + 1
        reply = Reply(id: id)
        let samples = audio.buffer.read(turnStart, processed)
        draft = Task { await self.write(id, samples) }
    }

    private func write(_ id: Int, _ samples: [Float]) async {
        do {
            let text = try await recognizer.transcribe(samples)
            guard reply.id == id, !Task.isCancelled else { return }
            if text.isEmpty {
                taker.discard()
                reply = Reply(id: id + 1)
                emit(.mood(.idle))
                return
            }
            taker.transcribed(Ending.of(text))
            reply.person = text
            let turns = history + [Turn(.person, text)]

            let (pieces, continuation) = AsyncStream<String>.makeStream()
            let brain = brain
            let generation = Task {
                defer { continuation.finish() }
                try await brain.reply(to: turns) { continuation.yield($0) }
            }
            var splitter = SentenceSplitter()
            await withTaskCancellationHandler {
                for await piece in pieces {
                    for sentence in splitter.feed(piece) { await speak(sentence, id) }
                }
            } onCancel: {
                generation.cancel()
            }
            for sentence in splitter.finish() { await speak(sentence, id) }
            _ = try await generation.value
            if reply.id == id { reply.written = true }
        } catch is CancellationError {
        } catch {
            if reply.id == id { emit(.problem(error.localizedDescription)) }
        }
    }

    /// Synthesise a sentence off the loop, then hold it or say it.
    private func speak(_ sentence: String, _ id: Int) async {
        guard reply.id == id, !Task.isCancelled else { return }
        let voice = voice
        guard let samples = try? await Task.detached(operation: { try voice.speak(sentence) }).value,
              !samples.isEmpty, reply.id == id, !Task.isCancelled
        else { return }
        if reply.committed { say(sentence, samples) } else { reply.held.append((sentence, samples)) }
    }

    private func say(_ sentence: String, _ samples: [Float]) {
        let (start, end) = audio.play(samples)
        reply.said.append(Said(text: sentence, start: start, end: end))
        emit(.saying(sentence, words: SpokenWord.estimate(sentence, duration: end - start), start: start))
        emit(.mood(.speaking))
    }

    // MARK: the turn changes hands

    private func commit() {
        reply.committed = true
        record(Turn(.person, reply.person))
        emit(.heard(reply.person))
        emit(.timing(taker.model))
        if reply.held.isEmpty { emit(.mood(.thinking)) }
        for (sentence, samples) in reply.held { say(sentence, samples) }
        reply.held = []
    }

    /// Said everything it wrote: the turn is open again.
    private func finishIfSaid() {
        guard reply.committed, reply.written, !reply.finished, reply.held.isEmpty, audio.backlog <= 0 else { return }
        reply.finished = true
        let text = reply.said.map(\.text).joined(separator: " ")
        if !text.isEmpty { record(Turn(.companion, text)) }
        emit(.replied(text, interrupted: false))
        emit(.echoLevel(echoLevel))
        taker.replyFinished()
        emit(.mood(.idle))
    }

    /// Someone talked over the reply. Its own voice coming back says the words
    /// it is saying; a person interrupting says something else.
    ///
    /// Two signals, either enough to call it echo: the words, and how loud it
    /// is against what was being played.
    private func check(overlapSince since: Double, reply id: Int) {
        let samples = audio.buffer.read(Int(since * 16_000), processed)
        let end = Duplex.now - Double(audio.buffer.count - processed) / 16_000
        let played = audio.reference(from: end - Double(samples.count) / 16_000, to: end)
        let quiet = echoLevel.isEcho(mic: samples, played: played)
        let loudness = echoLevel.leak.map { EchoLevel.level(samples) / max(1e-9, $0 * EchoLevel.level(played)) }
        Task {
            let heard = (try? await recognizer.transcribe(samples)) ?? ""
            settle(overlap: heard, quiet: quiet, loudness: loudness, since: since, reply: id)
        }
    }

    private func settle(overlap heard: String, quiet: Bool?, loudness: Double?, since: Double, reply id: Int) {
        guard reply.id == id, case .replying = taker.phase else { return }
        let now = Duplex.now
        // What it was saying around the time it was talked over.
        let saying = reply.said.filter { $0.start <= now && $0.end >= now - 2 }.map(\.text).joined(separator: " ")
        // Until the echo's level is learned, one word isn't enough: a third of
        // a second of echo is often transcribed as one wrong word.
        let unsure = quiet == nil && heard.split(whereSeparator: { $0.isWhitespace }).count < 2
        let echo = Echo.isEcho(heard: heard, saying: saying) || quiet == true || unsure
        emit(.overlap(heard: heard, saying: saying, loudness: loudness, echo: echo))
        if echo {
            taker.overlapWasEcho()
            return
        }
        audio.silence()
        draft?.cancel()
        let said = reply.said.filter { $0.start <= now }.map(\.text).joined(separator: " ")
        if !said.isEmpty { record(Turn(.companion, said, interrupted: true)) }
        emit(.hushed(at: now))
        emit(.replied(said, interrupted: true))
        taker.interrupted(since: since)
        turnStart = max(0, Int(since * 16_000) - Self.preroll)
        reply = Reply(id: id + 1)
        emit(.timing(taker.model))
        emit(.mood(.listening))
    }

    private func record(_ turn: Turn) {
        history.append(turn)
        if history.count > 64 { history.removeFirst(history.count - 64) }
        do {
            try log?.append(turn)
        } catch {
            emit(.problem("Couldn't write the conversation log: \(error.localizedDescription)"))
        }
    }
}
