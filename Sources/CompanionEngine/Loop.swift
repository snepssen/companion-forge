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
    /// The reply never sounded. They were still talking, and that turn goes on.
    case withdrew
    /// Whose voice a turn was, once it was theirs for certain: its person,
    /// a guest, or not sure, with how alike.
    case voice(String)
    /// Heard, but not one to answer: noise it made words of, or someone
    /// other than its person when it wasn't in a conversation.
    case ignored(String)
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
/// it is thrown away and that generation is waited out before another starts;
/// if the pause runs to the learned wait, what is ready is played at once and
/// the rest follows as it is made. Most of the model's time is spent inside
/// the silence the person was leaving anyway.
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
        /// Their voiceprint, how long the turn was, how loud, and whether it
        /// sounded like a guest while drafting.
        var print: [Float]?
        var seconds = 0.0
        var loudness: Float = 0
        var guest = false
        /// Working out their voiceprint, from the start of the draft.
        var printing: Task<[Float]?, Never>?
        /// Finalised, but their voiceprint isn't in yet: their turn is
        /// recorded once it is, and its reply after.
        var awaitingVoice = false
        var started = 0.0
        var said: [Said] = []
        var committed = false
        var written = false
        var finished = false
        /// In the conversation. Not until the reply has been heard: a follow-up
        /// before that is still this turn, and recording it now would make two.
        var recorded = false
        /// Stream time of the first frame of this reply that was actually audible.
        var soundedAt: Double?
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
    /// One generation at a time. A cancelled one is waited out before the next
    /// starts: two at once crash inside MLX's quantized matmul.
    private let generations = GenerationQueue()
    /// Words already committed, when the reply never sounded and they kept
    /// talking. The next transcript is joined onto them.
    private var carried: String?
    /// Those joined words have been given to a generation. Later speech is
    /// an interruption or echo, and this reply is still spoken.
    private var handedOn = false
    /// Speech that arrived after that hand-off, before the reply was audible.
    /// Kept so the interruption, once the voice is out, starts at the
    /// beginning of the sentence rather than wherever we noticed it.
    private var heldOverlap: Double?
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
    /// They may be thinking about suicide or hurting themselves: how
    /// clearly, since which turn, and whether it has told them who they can
    /// talk to. Held for a while after, not just the turn it was said.
    private var crisis: (level: Crisis.Level, since: Int, told: Bool, replies: Int)?  // only ever .clear
    static let crisisLasts = 20
    private let region = Locale.current.region?.identifier
    /// Telling voices apart, if it does: the print model and the voices.
    private let voiceprinter: Voiceprinter?
    private let voices: VoiceSense?
    /// Whether it's a guest talking, as last it could tell.
    private var guestTalking = false
    /// When anything was last said, by either side.
    private var lastExchange = -1e9
    /// Quiet this long and it isn't in a conversation: only its person wakes it.
    private let awake: Double

    /// Whether a turn is one to answer. In a conversation, nearly anything is,
    /// but a stray word it isn't sure of ("Thanks" heard as "Science"). Out
    /// of one, only its person starts one: left on all night, it answered a
    /// TV or the street, which it transcribes just as surely as them.
    private func wakes(_ text: String, confidence: Float) -> Bool {
        let words = text.split(separator: " ").count
        if words <= 2 && confidence < Self.unsure { return false }
        guard let voices else { return Duplex.now - lastExchange <= awake || confidence >= Self.sure }
        let household = voices.current
        guard Duplex.now - lastExchange <= awake else { return household.wakes(reply.print, seconds: reply.seconds) }
        // In a conversation a guest joins in, if they're about as near as its
        // person: a TV through the wall, answered at a tenth of their
        // loudness, isn't someone in the room.
        if let print = reply.print, case .guest = voices.peek(print, seconds: reply.seconds), ownerLoudness > 0 {
            return reply.loudness >= ownerLoudness * Self.near
        }
        return true
    }

    /// How loud its person's recent turns were, and how near that a guest must sound.
    private var ownerLoudness: Float = 0
    static let near: Float = 0.3

    /// How sure the recogniser must be of a short turn, and of anything that
    /// starts a conversation when it can't tell voices apart.
    static let unsure: Float = 0.8
    static let sure: Float = 0.9
    /// How to be with a guest.
    static let guestWay = "This isn't the voice of the person whose companion you are: it's someone else, a guest. "
        + "Be friendly and kind and keep it light. You have nothing to tell them about your person, their plans or "
        + "who they know, and you never guess or make any of it up; if asked, say kindly that it's your person's to "
        + "share, without pretending you don't know them."
    /// Catching up waits until they've said a couple of things, and comes
    /// at most once in this many turns.
    static let firstCheckIn = 4
    static let checkInEvery = 12
    /// After the voice stops, how long its echo is still waited out.
    static let ringing = 0.3

    public init(audio: any AudioIO, vad: SileroVAD, recognizer: Recognizer, brain: Brain, voice: Voice,
                memory: Memory? = nil, attention: AttentionSense? = nil, dictionary: Dictionary? = nil,
                log: ConversationLog?, voiceprinter: Voiceprinter? = nil, voices: VoiceSense? = nil, awake: Double = 180,
         timing: PauseModel, echoLevel: EchoLevel = EchoLevel(), emit: @escaping @Sendable (LoopEvent) -> Void) {
        self.awake = awake
        self.voiceprinter = voiceprinter
        self.voices = voices
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
                listenForEcho(samples, behind: available - processed, at: t)
                if speech { listenForWhere() }
                await act(taker.tick(at: t, speech: speech, probability: vad.probability), at: t)
                releaseHeldOverlap()
            }
            finishIfSaid()
            // Keep what a turn could still need; a minute is more than any.
            audio.buffer.drop(before: min(turnStart, processed - 60 * 16_000))
            try? await Task.sleep(for: .milliseconds(20))
        }
        await generations.cancel()
    }

    private func act(_ action: TurnTaker.Action, at t: Double) async {
        switch action {
        case .none:
            break
        case let .turnStarted(at):
            carried = nil
            handedOn = false
            heldOverlap = nil
            turnStart = max(0, Int(at * 16_000) - Self.preroll)
            emit(.mood(.listening))
        case .draft:
            await startDraft()
        case .abandon:
            // The joined turn is already being written. Keep that generation;
            // what they are saying now overlaps the reply instead of being
            // stitched onto the words it was given.
            if handedOn {
                taker.answer(at: t)
                if !reply.committed, !reply.person.isEmpty { commit() }
                break
            }
            reply = Reply(id: reply.id + 1)
            await generations.cancel()
            emit(.mood(.listening))
        case .commit:
            commit()
        case let .overlap(since):
            check(overlapSince: since, reply: reply.id)
        }
    }

    /// While the reply plays, learn how loud it comes back. `behind` is how
    /// many samples the microphone has delivered since this frame.
    private func listenForEcho(_ frame: [Float], behind: Int, at t: Double) {
        guard case .replying = taker.phase, audio.backlog > 0 else { return }
        let played = playedBehind(frame.count, behind: behind)
        if reply.soundedAt == nil, EchoLevel.isAudible(played) { reply.soundedAt = t }
        echoLevel.hear(mic: frame, played: played)
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

    private func startDraft() async {
        let id = reply.id + 1
        reply = Reply(id: id)
        let samples = audio.buffer.read(turnStart, processed)
        // Whose voice, alongside the words.
        if voices != nil, let voiceprinter {
            reply.printing = Task { try? await voiceprinter.print(samples) }
            reply.seconds = Double(samples.count) / 16_000
            reply.loudness = samples.isEmpty ? 0 : (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        }
        // From here the captured words are what gets answered. Speech after
        // this sample is not part of them.
        if carried != nil { handedOn = true }
        await generations.begin { await self.write(id, samples) }
    }

    private func write(_ id: Int, _ samples: [Float]) async {
        guard reply.id == id, !Task.isCancelled else { return }
        reply.started = Duplex.now
        do {
            let printing = reply.printing
            let recognised = try await recognizer.heard(samples)
            var text = recognised.text
            guard reply.id == id, !Task.isCancelled else { return }
            reply.times.transcribed = Duplex.now - reply.started
            // A turn that began as the last reply's voice stopped may begin
            // with that reply's own last words, off the room.
            let began = Duplex.now - Double(processed - turnStart - Self.preroll) / 16_000
            if let last = lastReply, began - last.end < Self.echoTail {
                text = Echo.strippingTail(text, said: last.text)
            }
            // A follow-up before the reply sounded belongs with the words
            // already committed, as one turn.
            if let earlier = carried, !earlier.isEmpty {
                text = Utterance.join(earlier, text)
            }
            if text.isEmpty {
                handedOn = false
                heldOverlap = nil
                taker.discard()
                reply = Reply(id: id + 1)
                emit(.mood(.idle))
                return
            }
            // Its voiceprint, for whose voice this is.
            if voices != nil, let print = await printing?.value ?? nil, reply.id == id { reply.print = print }
            // A turn that had already been accepted stays one, whatever the
            // follow-up's confidence. A fresh turn still has to be worth answering.
            if carried == nil, !wakes(text, confidence: recognised.confidence) {
                handedOn = false
                heldOverlap = nil
                taker.discard()
                reply = Reply(id: id + 1)
                emit(.ignored(text))
                emit(.mood(.idle))
                return
            }
            let joining = carried != nil
            taker.transcribed(Ending.of(text))
            reply.person = text
            // Answer as soon as the follow-up is known. Waiting out the rest
            // of the pause let the next sentence join this one, and cancelling
            // here left nobody answering.
            if joining {
                handedOn = true
                commit()
                taker.answer(at: Double(processed) / 16_000)
            }
            reply.guest = guestTalking
            var sureOfVoice = false
            if let voices, let print = reply.print {
                switch voices.peek(print, seconds: reply.seconds) {
                case .owner:
                    reply.guest = false
                    sureOfVoice = true
                case .guest:
                    reply.guest = true
                case .unsure:
                    break
                }
            }
            let guest = reply.guest
            // A guest sees only their side of the conversation, and nothing of its person's memory.
            let turns = Household.visible(history, toGuest: guest) + [Turn(.person, text, who: guest ? Household.guest : nil)]
            // Catching up and reminders only when it's sure it's its person: a
            // guest's short "hey" sounds like whoever spoke last.
            let sure = sureOfVoice
            var recollection = guest ? Recollection() : await memory?.recollect(for: text) ?? Recollection()
            if guest { recollection.talking = Self.guestWay }
            if let memory, !guest, let command = MemoryCommand.parse(text) {
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
            // In a dark place: that comes before everything else.
            // Clear words hold it for a while; words that might only mean a
            // hard day get one gentle "are you okay?".
            let heard = Crisis.heard(text)
            if heard == .clear {
                crisis = (.clear, turnCount, crisis?.told ?? false, crisis?.replies ?? 0)
            } else if let current = crisis, turnCount - current.since > Self.crisisLasts {
                crisis = nil
            }
            if let level = crisis?.level ?? heard {
                recollection.aside = [recollection.aside, Crisis.guidance(level, first: !(crisis?.told ?? false), region: region)]
                    .compactMap { $0 }.joined(separator: " ")
            }
            // What's coming up, or what they did: the calendar and the diary.
            let agenda = guest ? nil : Agenda.ask(in: text)
            if let agenda, let memory {
                recollection.aside = [recollection.aside, await memory.agenda(agenda)].compactMap { $0 }.joined(separator: " ")
            }
            // Now and then, when nothing else is going on: something to catch up on.
            // Something coming up today or tomorrow comes first, then how
            // something went.
            if let memory, crisis == nil, lookup == nil, agenda == nil, reply.memory == nil, turnCount >= Self.firstCheckIn,
               !guest, voices == nil || sure,
               turnCount - caughtUp >= Self.checkInEvery || caughtUp == 0 {
                if let (day, happening) = await memory.ahead() {
                    (recollection.coming, recollection.comingDay) = (happening, day)
                    reply.coming = happening
                } else if let note = await memory.checkIn() {
                    // Told it already, unasked: caught up.
                    if CheckIn.asked(text, about: note) {
                        await memory.checkedIn(note.id)
                    } else {
                        recollection.checkIn = note
                        reply.checkIn = note
                    }
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
                        // A help desk's sign-off, not a friend's: left unsaid. (Not
                        // while they're struggling: "I'm here if you need me" is right then.)
                        if crisis == nil, Manners.isFiller(sentence) { continue }
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
            if Task.isCancelled || reply.id != id {
                _ = try? await generation.value
                return
            }
            if pretended {
                _ = try? await generation.value
                try Task.checkCancellation()
            } else {
                for sentence in splitter.finish() where crisis != nil || !Manners.isFiller(sentence) {
                    if Honesty.pretends(sentence) {
                        await speak(Honesty.admission, id)
                        break
                    }
                    await speak(sentence, id)
                }
                // Two careful replies and the model still hasn't said who they
                // could talk to: it says so itself, once.
                if let current = crisis, !current.told, current.replies >= 2,
                   !Crisis.gave(reply.said.map(\.text).joined(separator: " "), region: region) {
                    await speak(Crisis.offer(region: region), id)
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
        // A crisis line's number, read digit by digit.
        let spoken = Crisis.spoken(sentence)
        guard let (samples, mouth) = try? await Task.detached(operation: { try voice.speakTimed(spoken, hint: hint) }).value,
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
        emit(.mood(crisis == nil && Tone.isCheerful(sentence) ? .cheerful : .speaking))
    }

    // MARK: the turn changes hands

    private func commit() {
        // The follow-up's write may already have committed, once the words
        // were known; a later pause must not say them again.
        guard !reply.committed else { return }
        // Joined into reply.person already, if this turn was a follow-up.
        carried = nil
        reply.committed = true
        // Their voice still being worked out: record the turn when it's in,
        // and only once the reply has actually been heard.
        if voices != nil, reply.print == nil, let printing = reply.printing {
            reply.awaitingVoice = true
            let id = reply.id
            Task {
                let print = await printing.value
                await self.voiceArrived(print, for: id)
            }
        } else {
            settleVoice()
        }
        emit(.heard(reply.person))
        emit(.timing(taker.model))
        if reply.held.isEmpty { emit(.mood(.thinking)) }
        for (sentence, samples, mouth) in reply.held { say(sentence, samples, mouth) }
        reply.held = []
    }

    private func voiceArrived(_ print: [Float]?, for id: Int) {
        guard reply.id == id, reply.awaitingVoice else { return }
        reply.print = print
        settleVoice()
        reply.awaitingVoice = false
        finishIfSaid()
    }

    /// Their words into the conversation, once the reply has been heard.
    /// Until then a follow-up is still this turn, and recording it now would
    /// make the model see two.
    private func keepTheirs(waitingForVoice: Bool = true) {
        guard reply.committed, !reply.recorded, !reply.person.isEmpty else { return }
        if waitingForVoice, reply.awaitingVoice { return }
        reply.recorded = true
        recordTheirs()
    }

    /// Now theirs for certain: whose voice it was, learning its person's.
    private func settleVoice() {
        if let voices, let print = reply.print {
            let heard = voices.hear(print, seconds: reply.seconds)
            switch heard {
            case let .owner(score):
                guestTalking = false
                ownerLoudness = ownerLoudness == 0 ? reply.loudness : ownerLoudness * 0.7 + reply.loudness * 0.3
                emit(.voice(String(format: "its person (%.2f)", score)))
            case let .guest(score):
                guestTalking = true
                emit(.voice(String(format: "a guest (%.2f to its person)", score)))
            case .unsure:
                emit(.voice(String(format: "not sure (%.1f s): still %@", reply.seconds, guestTalking ? "a guest" : "its person")))
            }
            let household = voices.current
            Task { [memory] in await memory?.keep(household) }
        }
    }

    /// Their turn into the conversation and its log, as whoever it was.
    private func recordTheirs() {
        // A guest's turn is marked, so the memory leaves it out.
        let turn = record(Turn(.person, reply.person, who: voices != nil && guestTalking ? Household.guest : nil))
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
    }

    /// Said everything it wrote: the turn is open again.
    private func finishIfSaid() {
        guard reply.committed, reply.written, !reply.finished, !reply.awaitingVoice, reply.held.isEmpty,
              audio.backlog <= 0 else { return }
        // Its last words are still coming back off the room: the turn isn't
        // open until they have, or they would open it.
        if let end = reply.said.last?.end, Duplex.now < end + echoDelay.delay + Self.ringing { return }
        keepTheirs()
        handedOn = false
        heldOverlap = nil
        reply.finished = true
        let text = reply.said.map(\.text).joined(separator: " ")
        if !text.isEmpty { record(Turn(.companion, text)) }
        if crisis != nil, !text.isEmpty {
            crisis?.replies += 1
            if Crisis.gave(text, region: region) { crisis?.told = true }
        }
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
    /// it is saying; a person interrupting says something else. Nothing
    /// audible playing is the person too: the reply can be committed and not
    /// yet started.
    ///
    /// Two signals, either enough to call it echo while the reply is playing:
    /// the words, and how loud it is against what was being played.
    private func check(overlapSince since: Double, reply id: Int) {
        let samples = audio.buffer.read(Int(since * 16_000), processed)
        let played = playedBehind(samples.count, behind: audio.buffer.count - processed)
        let quiet = echoLevel.isEcho(mic: samples, played: played)
        let playing = EchoLevel.isAudible(played)
        let loudness = echoLevel.leak.map { EchoLevel.level(samples) / max(1e-9, $0 * EchoLevel.level(played)) }
        Task {
            let heard = (try? await recognizer.transcribe(samples)) ?? ""
            await settle(overlap: heard, quiet: quiet, playing: playing, loudness: loudness, since: since, reply: id)
        }
    }

    private func settle(overlap heard: String, quiet: Bool?, playing: Bool, loudness: Double?, since: Double, reply id: Int) async {
        guard reply.id == id, case .replying = taker.phase else { return }
        let now = Duplex.now
        // What it was saying around the time it was talked over.
        let saying = reply.said.filter { $0.start <= now && $0.end >= now - 2 }.map(\.text).joined(separator: " ")
        let echo = Echo.isEcho(heard: heard, saying: saying, quiet: quiet, playing: playing)
        emit(.overlap(heard: heard, saying: saying, loudness: loudness, echo: echo))
        if echo {
            taker.overlapWasEcho()
            return
        }
        let sounded = reply.soundedAt != nil
        let scheduledAgo = reply.said.map(\.start).min().map { now - $0 }
        let playbackBegun = sounded || playing || (scheduledAgo.map { $0 >= Echo.heardAfter } ?? false)
        // Only a reply that has not been heard, and whose words are not
        // already with a generation. Playback — a sounded frame, or the
        // voice having been out for a moment — and a handed-on reply both
        // take the ordinary interruption path below.
        if Echo.continuesTurn(audible: playing, soundedBefore: sounded, scheduledAgo: scheduledAgo, handedOn: handedOn),
           !reply.person.isEmpty || carried != nil {
            handedOn = false
            heldOverlap = nil
            if !reply.person.isEmpty { carried = reply.person }
            audio.silence()
            let next = reply.id + 1
            reply = Reply(id: next)
            await generations.cancel()
            guard reply.id == next, case .replying = taker.phase else { return }
            taker.carriedOn(at: Double(processed) / 16_000)
            emit(.withdrew)
            emit(.timing(taker.model))
            emit(.mood(.listening))
            anticipate()
            return
        }
        // The joined turn is already being answered, and nothing of it has
        // been heard. Cancelling it now is how a run goes quiet for the rest
        // of the script. Hold this sentence and interrupt once the voice is out.
        if handedOn, !playbackBegun {
            heldOverlap = min(heldOverlap ?? since, since)
            return
        }
        heldOverlap = nil
        audio.silence()
        let said = reply.said.filter { $0.start <= now }.map(\.text).joined(separator: " ")
        keepTheirs(waitingForVoice: false)
        carried = nil
        handedOn = false
        let next = reply.id + 1
        reply = Reply(id: next)
        await generations.cancel()
        guard reply.id == next, case .replying = taker.phase else { return }
        if !said.isEmpty { record(Turn(.companion, said, interrupted: true)) }
        lastReply = (said, now)
        emit(.hushed(at: now))
        emit(.replied(said, interrupted: true))
        taker.interrupted(since: since, at: Double(processed) / 16_000)
        turnStart = max(0, Int(since * 16_000) - Self.preroll)
        emit(.timing(taker.model))
        emit(.mood(.listening))
        anticipate()
    }

    /// An overlap that arrived before a handed-on reply was audible.
    /// Once the voice is out, that sentence interrupts from where it began.
    private func releaseHeldOverlap() {
        guard let since = heldOverlap, handedOn, case .replying = taker.phase else { return }
        let ago = reply.said.map(\.start).min().map { Duplex.now - $0 }
        let begun = reply.soundedAt != nil || (ago.map { $0 >= Echo.heardAfter } ?? false)
        guard begun else { return }
        heldOverlap = nil
        check(overlapSince: since, reply: reply.id)
    }

    /// Say something nobody asked for (being shaken, say), if nobody is
    /// talking; false if somebody is.
    public func interject(_ text: String) async -> Bool {
        guard taker.phase == .waiting else { return false }
        let voice = voice
        guard let (samples, mouth) = try? await Task.detached(operation: { try voice.speakTimed(text) }).value,
              !samples.isEmpty, taker.speakUnprompted(at: Double(processed) / 16_000)
        else { return false }
        await generations.cancel()
        reply = Reply(id: reply.id + 1)
        reply.committed = true
        reply.written = true
        say(text, samples, mouth)
        return true
    }

    /// Say hello as they open it, if they've been away a while: a few words
    /// from the model, with anything coming up or worth catching up on.
    /// Quiet if they start talking first.
    public func greet() async {
        let last = await memory?.lastTalked()
        let coming = await memory?.ahead()
        let checkIn = coming == nil ? await memory?.checkIn() : nil
        guard let cue = Greeting.cue(last: last, checkIn: checkIn, coming: coming), taker.phase == .waiting else { return }
        let recollection = await memory?.standing() ?? Recollection()
        emit(.mood(.thinking))
        let brain = brain
        guard let text = try? await brain.reply(to: [Turn(.person, cue)], remembering: recollection) { _ in },
              !text.isEmpty, taker.phase == .waiting
        else {
            emit(.mood(.idle))
            return
        }
        let greeting = text.split(separator: "\n").joined(separator: " ")
        guard await interject(greeting) else { emit(.mood(.idle)); return }
        caughtUp = turnCount
        if let happening = coming?.happening, CheckIn.mentions(greeting, happening.text) {
            await memory?.reminded(happening.id)
        }
        if let note = checkIn, CheckIn.asked(greeting, about: note) {
            await memory?.checkedIn(note.id)
        }
    }

    /// Have the model read the conversation so far while they talk.
    private func anticipate() {
        // As the next reply will see it: whoever spoke last, and only their side.
        let guest = voices != nil && guestTalking
        let (brain, memory, visible) = (brain, memory, Household.visible(history, toGuest: guest))
        Task {
            let standing = guest ? Recollection() : await memory?.standing() ?? Recollection()
            try? await brain.anticipate(visible, remembering: standing)
        }
    }

    /// Keep a turn in the conversation and its log; returns its place in the log.
    @discardableResult
    private func record(_ turn: Turn) -> Int? {
        turnCount += 1
        lastExchange = Duplex.now
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
