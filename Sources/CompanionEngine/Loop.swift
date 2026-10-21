import CompanionCore
import Foundation

/// What the loop tells the app.
public enum LoopEvent: Sendable {
    case mood(Mood)
    /// A turn of theirs, as it will be answered.
    case heard(String)
    /// What the memory brought up for the turn being drafted.
    case recalled(Recollection)
    /// A note was added or forgotten because they asked.
    case memoryChanged
    /// The voice starts saying this at `start`, on `Duplex.now`'s clock,
    /// with these mouth shapes.
    case saying(String, mouth: [VisemeSpan], start: Double)
    /// The voice was cut off at this time.
    case hushed(at: Double)
    /// A reply, all of it or what was said before it was cut off.
    case replied(String, interrupted: Bool)
    case timing(PauseModel)
    /// Where a draft's time went.
    case drafted(DraftTimes)
    /// How loud the reply comes back, as learned so far: kept for the next session.
    case echoLevel(EchoLevel)
    /// How late it comes back, and how surely that was measured.
    case echoDelay(Double, match: Double)
    /// Speech over a reply: what it was transcribed as, how loud it was as a
    /// multiple of the reply's learned echo (nil before that is learned), and
    /// the verdict.
    case overlap(heard: String, saying: String, loudness: Double?, echo: Bool)
    case problem(String)
}

/// Seconds from the start of a draft to each stage of it, and how much of
/// the prompt the model had to read rather than find in its cache.
public struct DraftTimes: Sendable {
    public var transcribed = 0.0
    public var recalled = 0.0
    public var firstWords = 0.0
    public var firstSentence = 0.0
    public var firstVoice = 0.0
    public var promptRead = 0
    public var promptLength = 0
}

/// Remembering or forgetting, as they asked, done when their turn is
/// committed: a draft can still be thrown away.
enum MemoryAction: Sendable {
    case remember(String)
    case forget(Note)
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
        var held: [(text: String, samples: [Float], mouth: [VisemeSpan]?)] = []
        var times = DraftTimes()
        /// What to do with the memory once the turn is theirs for certain.
        var memory: MemoryAction?
        /// A note it was offered to catch up on in this reply, or something
        /// coming up to remind them of.
        var checkIn: Note?
        var coming: Happening?
        var started = 0.0
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
    private let memory: Memory?
    private let attention: AttentionSense?
    private let dictionary: Dictionary?
    private let emit: @Sendable (LoopEvent) -> Void
    private var taker: TurnTaker
    private var history: [Turn] = []
    private var processed = 0
    private var turnStart = 0
    private var reply = Reply()
    private var draft: Task<Void, Never>?
    private var echoLevel: EchoLevel
    /// The last reply, what of it was said and when its voice stopped: its
    /// echo can open the next turn.
    private var lastReply: (text: String, end: Double)?
    static let echoTail = 1.0
    private var echoDelay = EchoDelay()
    /// The last word looked up in the dictionary, for "and in Polish?".
    private var lastLookup: String?
    /// How many turns into the conversation it last caught up on something.
    private var caughtUp = 0
    /// Turns in this conversation so far (the history itself is trimmed).
    private var turnCount = 0
    /// Catching up waits until they've said a couple of things, and comes
    /// at most once in this many turns.
    static let firstCheckIn = 4
    static let checkInEvery = 12
    /// After the voice stops, how long its echo is still waited out.
    static let ringing = 0.3

    public init(audio: any AudioIO, vad: SileroVAD, recognizer: Recognizer, brain: Brain, voice: Voice,
                memory: Memory? = nil, attention: AttentionSense? = nil, dictionary: Dictionary? = nil,
                log: ConversationLog?,
         timing: PauseModel, echoLevel: EchoLevel = EchoLevel(), emit: @escaping @Sendable (LoopEvent) -> Void) {
        self.audio = audio
        self.vad = vad
        self.recognizer = recognizer
        self.brain = brain
        self.voice = voice
        self.log = log
        self.memory = memory
        self.attention = attention
        self.dictionary = dictionary
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
                listenForDelay(samples, behind: available - processed)
                listenForEcho(samples, behind: available - processed)
                if speech { listenForWhere() }
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
        echoLevel.hear(mic: frame, played: playedBehind(frame.count, behind: behind))
    }

    /// While the reply plays and just after, learn how late it comes back.
    private func listenForDelay(_ frame: [Float], behind: Int) {
        guard audio.backlog > 0 || reply.said.contains(where: { Duplex.now - $0.end < 0.6 }) else { return }
        let end = Duplex.now - Double(behind) / 16_000
        let played = audio.reference(from: end - Double(frame.count) / 16_000, to: end)
        echoDelay.hear(mic: EchoLevel.level(frame), played: EchoLevel.level(played))
    }

    /// What was played as long before this frame as the echo takes to come
    /// back: what the microphone is hearing of it now.
    private func playedBehind(_ count: Int, behind: Int) -> [Float] {
        let end = Duplex.now - Double(behind) / 16_000 - echoDelay.delay
        return audio.reference(from: end - Double(count) / 16_000, to: end)
    }

    /// Someone is speaking: where from, if the microphone has two sides.
    /// Its own voice isn't someone to turn to.
    private func listenForWhere() {
        guard let attention, audio.backlog <= 0, let (left, right) = audio.balance,
              let across = StereoBearing.across(left: left, right: right) else { return }
        attention.hear(Point(across, 0), weight: 0.5)
    }

    // MARK: drafting

    private func startDraft() {
        let id = reply.id + 1
        reply = Reply(id: id)
        let samples = audio.buffer.read(turnStart, processed)
        draft = Task { await self.write(id, samples) }
    }

    private func write(_ id: Int, _ samples: [Float]) async {
        reply.started = Duplex.now
        do {
            var text = try await recognizer.transcribe(samples)
            guard reply.id == id, !Task.isCancelled else { return }
            reply.times.transcribed = Duplex.now - reply.started
            // A turn that began as the last reply's voice stopped may begin
            // with that reply's own last words, off the room.
            let began = Duplex.now - Double(processed - turnStart - Self.preroll) / 16_000
            if let last = lastReply, began - last.end < Self.echoTail {
                text = Echo.strippingTail(text, said: last.text)
            }
            if text.isEmpty {
                taker.discard()
                reply = Reply(id: id + 1)
                emit(.mood(.idle))
                return
            }
            taker.transcribed(Ending.of(text))
            reply.person = text
            let turns = history + [Turn(.person, text)]
            var recollection = await memory?.recollect(for: text) ?? Recollection()
            if let memory, let command = MemoryCommand.parse(text) {
                (reply.memory, recollection.aside) = await plan(command, with: memory)
            }
            // A word to translate or explain: the dictionary's answer, not the model's guess.
            var lookup = Lookup.request(in: text)
            if lookup == nil, let language = Lookup.followUp(text), let last = lastLookup {
                lookup = .translate(last, into: language)
            }
            if let lookup, let dictionary {
                if case let .translate(phrase, _) = lookup { lastLookup = phrase }
                recollection.aside = [recollection.aside, dictionary.answer(lookup)].compactMap { $0 }.joined(separator: " ")
            }
            // What's coming up, or what they did: the calendar and the diary.
            let agenda = Agenda.ask(in: text)
            if let agenda, let memory {
                recollection.aside = [recollection.aside, await memory.agenda(agenda)].compactMap { $0 }.joined(separator: " ")
            }
            // Now and then, when nothing else is going on: something to catch up on.
            // Something coming up today or tomorrow comes first, then how
            // something went.
            if let memory, lookup == nil, agenda == nil, reply.memory == nil, turnCount >= Self.firstCheckIn,
               turnCount - caughtUp >= Self.checkInEvery || caughtUp == 0 {
                if let (day, happening) = await memory.ahead() {
                    (recollection.coming, recollection.comingDay) = (happening, day)
                    reply.coming = happening
                } else if let note = await memory.checkIn() {
                    recollection.checkIn = note
                    reply.checkIn = note
                }
            }
            guard reply.id == id, !Task.isCancelled else { return }
            reply.times.recalled = Duplex.now - reply.started
            if !recollection.notes.isEmpty || !recollection.excerpt.isEmpty { emit(.recalled(recollection)) }

            let (pieces, continuation) = AsyncStream<String>.makeStream()
            let brain = brain
            let generation = Task {
                defer { continuation.finish() }
                try await brain.reply(to: turns, remembering: recollection) { continuation.yield($0) }
            }
            var splitter = SentenceSplitter()
            var pretended = false
            var corrections = 0
            await withTaskCancellationHandler {
                for await piece in pieces where !pretended {
                    if reply.id == id && reply.times.firstWords == 0 { reply.times.firstWords = Duplex.now - reply.started }
                    for sentence in splitter.feed(piece) {
                        if reply.id == id && reply.times.firstSentence == 0 {
                            reply.times.firstSentence = Duplex.now - reply.started
                        }
                        // Claiming to search or check: the truth instead, and no more.
                        if Honesty.pretends(sentence) {
                            pretended = true
                            generation.cancel()
                            await speak(Honesty.admission, id)
                            break
                        }
                        // A help desk's sign-off, not a friend's: left unsaid.
                        if Manners.isFiller(sentence) { continue }
                        // Taking itself back twice: it doesn't know; say so and stop.
                        if Honesty.corrects(sentence) {
                            corrections += 1
                            if corrections >= 2 {
                                pretended = true
                                generation.cancel()
                                await speak(Honesty.unsure, id)
                                break
                            }
                        }
                        await speak(sentence, id)
                    }
                }
            } onCancel: {
                generation.cancel()
            }
            if pretended {
                _ = try? await generation.value
                try Task.checkCancellation()
            } else {
                for sentence in splitter.finish() where !Manners.isFiller(sentence) {
                    if Honesty.pretends(sentence) {
                        await speak(Honesty.admission, id)
                        break
                    }
                    await speak(sentence, id)
                }
                _ = try await generation.value
            }
            if reply.id == id {
                reply.written = true
                (reply.times.promptRead, reply.times.promptLength) = await brain.lastPrompt
                emit(.drafted(reply.times))
            }
        } catch is CancellationError {
        } catch {
            if reply.id == id { emit(.problem(error.localizedDescription)) }
        }
    }

    /// What to do about being asked to remember or forget, and what the
    /// model should know of it to reply.
    private func plan(_ command: MemoryCommand, with memory: Memory) async -> (MemoryAction?, String) {
        switch command {
        case let .remember(what):
            return (.remember(what), "They asked you to remember this, and it is noted: \(what). Say so in a few words.")
        case let .forget(what):
            guard let note = await memory.closest(to: what) else {
                return (nil, "They asked you to forget something about \(what), but you have no note about that. Say so.")
            }
            return (.forget(note), "They asked you to forget something, and this note is now forgotten: "
                + "\(note.text) Say so in a few words, without repeating it.")
        }
    }

    /// Synthesise a sentence off the loop, then hold it or say it.
    private func speak(_ sentence: String, _ id: Int) async {
        guard reply.id == id, !Task.isCancelled else { return }
        let voice = voice
        // The language they asked about, for quoted words in the reply.
        let hint = Languages.named(in: reply.person)
        guard let (samples, mouth) = try? await Task.detached(operation: { try voice.speakTimed(sentence, hint: hint) }).value,
              !samples.isEmpty, reply.id == id, !Task.isCancelled
        else { return }
        if reply.times.firstVoice == 0 { reply.times.firstVoice = Duplex.now - reply.started }
        if reply.committed { say(sentence, samples, mouth) } else { reply.held.append((sentence, samples, mouth)) }
    }

    private func say(_ sentence: String, _ samples: [Float], _ mouth: [VisemeSpan]?) {
        let (start, end) = audio.play(samples)
        reply.said.append(Said(text: sentence, start: start, end: end))
        emit(.saying(sentence, mouth: mouth ?? Visemes.timeline(SpokenWord.estimate(sentence, duration: end - start)),
                     start: start))
        emit(.mood(Tone.isCheerful(sentence) ? .cheerful : .speaking))
    }

    // MARK: the turn changes hands

    private func commit() {
        reply.committed = true
        let turn = record(Turn(.person, reply.person))
        if let action = reply.memory, let memory {
            let session = log?.session ?? "unlogged"
            Task {
                switch action {
                case let .remember(what): _ = try? await memory.remember(what, session: session, turn: turn ?? 0)
                case let .forget(note): try? await memory.forget(note.id)
                }
                emit(.memoryChanged)
            }
        }
        emit(.heard(reply.person))
        emit(.timing(taker.model))
        if reply.held.isEmpty { emit(.mood(.thinking)) }
        for (sentence, samples, mouth) in reply.held { say(sentence, samples, mouth) }
        reply.held = []
    }

    /// Said everything it wrote: the turn is open again.
    private func finishIfSaid() {
        guard reply.committed, reply.written, !reply.finished, reply.held.isEmpty, audio.backlog <= 0 else { return }
        // Its last words are still coming back off the room: the turn isn't
        // open until they have, or they would open it.
        if let end = reply.said.last?.end, Duplex.now < end + echoDelay.delay + Self.ringing { return }
        reply.finished = true
        let text = reply.said.map(\.text).joined(separator: " ")
        if !text.isEmpty { record(Turn(.companion, text)) }
        if let note = reply.checkIn, let memory, CheckIn.asked(text, about: note) {
            caughtUp = turnCount
            Task { await memory.checkedIn(note.id) }
        }
        if let happening = reply.coming, let memory, CheckIn.mentions(text, happening.text) {
            caughtUp = turnCount
            Task { await memory.reminded(happening.id) }
        }
        lastReply = (text, (reply.said.last?.end ?? Duplex.now) + echoDelay.delay)
        emit(.replied(text, interrupted: false))
        emit(.echoLevel(echoLevel))
        emit(.echoDelay(echoDelay.delay, match: echoDelay.match))
        taker.replyFinished()
        anticipate()
        emit(.mood(.idle))
    }

    /// Someone talked over the reply. Its own voice coming back says the words
    /// it is saying; a person interrupting says something else.
    ///
    /// Two signals, either enough to call it echo: the words, and how loud it
    /// is against what was being played.
    private func check(overlapSince since: Double, reply id: Int) {
        let samples = audio.buffer.read(Int(since * 16_000), processed)
        let played = playedBehind(samples.count, behind: audio.buffer.count - processed)
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
        lastReply = (said, now)
        emit(.hushed(at: now))
        emit(.replied(said, interrupted: true))
        taker.interrupted(since: since)
        turnStart = max(0, Int(since * 16_000) - Self.preroll)
        reply = Reply(id: id + 1)
        emit(.timing(taker.model))
        emit(.mood(.listening))
        anticipate()
    }

    /// Say something nobody asked for (being shaken, say), if nobody is
    /// talking; false if somebody is.
    public func interject(_ text: String) async -> Bool {
        guard taker.phase == .waiting else { return false }
        let voice = voice
        guard let (samples, mouth) = try? await Task.detached(operation: { try voice.speakTimed(text) }).value,
              !samples.isEmpty, taker.speakUnprompted(at: Double(processed) / 16_000)
        else { return false }
        draft?.cancel()
        reply = Reply(id: reply.id + 1)
        reply.committed = true
        reply.written = true
        say(text, samples, mouth)
        return true
    }

    /// Have the model read the conversation so far while they talk.
    private func anticipate() {
        let (brain, memory, history) = (brain, memory, history)
        Task {
            let profile = await memory?.profile ?? []
            try? await brain.anticipate(history, remembering: Recollection(profile: profile))
        }
    }

    /// Keep a turn in the conversation and its log; returns its place in the log.
    @discardableResult
    private func record(_ turn: Turn) -> Int? {
        turnCount += 1
        history.append(turn)
        history.removeFirst(Window.trim(history.count))
        do {
            return try log?.append(turn)
        } catch {
            emit(.problem("Couldn't write the conversation log: \(error.localizedDescription)"))
            return nil
        }
    }
}
