import Foundation

/// How a transcript ends, as evidence of whether the speaker has finished.
///
/// Parakeet punctuates, but it puts a full stop on almost anything followed by
/// silence, "and." included. So the last word is read before the mark: a
/// sentence that stops on a conjunction or a filler is still going, whatever
/// punctuation it was given.
public enum Ending: String, Codable, Sendable {
    /// Asked, and waiting for the answer: the quickest to reply to.
    case question
    /// A full stop or an exclamation after a word that can end a sentence.
    case statement
    /// A comma, a conjunction, a filler, no punctuation: more is coming.
    case open

    /// Words a finished sentence doesn't stop on.
    static let continuing: Set<String> = [
        "and", "but", "so", "or", "because", "cause", "if", "when", "while", "then", "that", "which", "who",
        "um", "uh", "er", "erm", "hmm", "like", "the", "a", "an", "to", "of", "with", "for", "in", "on",
        "my", "your", "our", "their", "is", "was", "are", "were", "i", "we", "you", "it's", "i'm", "just",
    ]

    public static func of(_ text: String) -> Ending {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mark = trimmed.last else { return .open }
        let lastWord = trimmed.split(whereSeparator: { $0.isWhitespace }).last
            .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) } ?? ""
        if continuing.contains(lastWord) { return .open }
        if mark == "?" { return .question }
        if mark == "." || mark == "!" { return .statement }
        return .open
    }
}

/// How long this person pauses mid-thought, learned from the pauses they came
/// back from, and so how long a silence means they have finished.
///
/// interpreter-forge waited on pauses, punctuation and a fixed 5 s ceiling. A
/// conversation can do better: every time someone goes quiet and then carries
/// on, that gap was a pause inside their turn, and the turn is over once a
/// silence runs longer than nearly all of those. The wait sits at the 90th
/// percentile of the pauses they came back from, shortened after a question,
/// lengthened when the words so far trail off, and pushed out further every
/// time a reply cut them off.
public struct PauseModel: Codable, Sendable, Equatable {
    public static let floor = 0.45
    public static let ceiling = 2.2
    /// Until there is enough to learn from.
    public static let starting = 0.9
    static let enough = 8
    static let kept = 200
    /// Shorter than this is the voice detector fluttering inside a word.
    static let shortest = 0.15
    static let biasStep = 0.25
    static let biasLimit = 1.0
    /// Each reply that lands cleanly lets the cut-in penalty fade a little.
    static let biasFade = 0.9

    /// Mid-turn pauses they came back from, oldest first, at most `kept`.
    public private(set) var pauses: [Double] = []
    /// Seconds added after replies that cut in.
    public private(set) var bias = 0.0
    public private(set) var replies = 0
    public private(set) var cutIns = 0

    public init() {}

    /// The silence that ends a turn ending this way.
    public func wait(after ending: Ending) -> Double {
        let base = pauses.count < Self.enough ? Self.starting : Self.quantile(pauses, 0.9) + 0.15
        let factor: Double = switch ending {
        case .question: 0.8
        case .statement: 1.0
        case .open: 1.6
        }
        return min(Self.ceiling, max(Self.floor, base * factor + bias))
    }

    /// When to start thinking. A reply drafted from here is mostly ready by
    /// the time the wait is over, and is thrown away if they carry on.
    public func draft() -> Double { max(0.3, wait(after: .question) * 0.5) }

    /// They went quiet for `pause` seconds and then carried on.
    public mutating func resumed(after pause: Double) {
        guard pause >= Self.shortest, pause <= Self.ceiling * 1.5 else { return }
        pauses.append(pause)
        if pauses.count > Self.kept { pauses.removeFirst(pauses.count - Self.kept) }
    }

    /// A reply started and they were not finished.
    public mutating func cutIn() {
        cutIns += 1
        bias = min(Self.biasLimit, bias + Self.biasStep)
    }

    /// A turn ended and was answered.
    public mutating func replied() {
        replies += 1
        bias *= Self.biasFade
    }

    static func quantile(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let position = q * Double(sorted.count - 1)
        let low = Int(position.rounded(.down))
        let high = min(sorted.count - 1, low + 1)
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }
}

/// Whose turn it is, frame by frame, from the voice detector alone. The
/// engine does what it says: transcribe and start thinking at `.draft`, throw
/// that away at `.abandon`, speak at `.commit`, check for an echo at
/// `.overlap`. Times are stream seconds.
public struct TurnTaker: Sendable {
    public enum Phase: Equatable, Sendable {
        /// Nobody is talking.
        case waiting
        case hearing
        /// They went quiet at `since`.
        case pausing(since: Double)
        /// The companion has the turn, whether or not its voice has started.
        case replying(since: Double)
    }

    public enum Action: Equatable, Sendable {
        case none
        /// Speech began at this stream time.
        case turnStarted(at: Double)
        /// Transcribe what was said and start the reply, without speaking it.
        case draft
        /// They carried on: the draft is out of date.
        case abandon
        /// The turn is over: speak the reply.
        case commit
        /// Sustained, confident speech over the reply since this time: theirs,
        /// or the reply's own echo. The engine decides and says which.
        case overlap(since: Double)
    }

    /// Speech over the reply must last this long to count as interrupting.
    public static let bargeIn = 0.35
    /// And this sure: the echo canceller's leftovers are quieter and less speech-like.
    public static let bargeInProbability: Float = 0.7
    /// A reply interrupted this soon after it began started too early.
    public static let cutInWindow = 2.0

    public var model: PauseModel
    public private(set) var phase = Phase.waiting
    public private(set) var ending = Ending.statement
    private var drafted = false
    private var heard = false
    private var lastSpeech = 0.0
    private var overlapStart: Double?
    private var overlapReported = false
    /// The pause the last reply came after, in case it cuts in.
    private var replyPause = 0.0
    /// The companion spoke without being spoken to: talking over that isn't
    /// a sign it replied too soon.
    private var unprompted = false

    public init(model: PauseModel = PauseModel()) { self.model = model }

    /// The silence this turn is waiting for, now.
    public var wait: Double { model.wait(after: ending) }

    public mutating func tick(at t: Double, speech: Bool, probability: Float) -> Action {
        switch phase {
        case .waiting:
            guard speech else { return .none }
            phase = .hearing
            lastSpeech = t
            ending = .statement
            return .turnStarted(at: t)

        case .hearing:
            if speech { lastSpeech = t } else { phase = .pausing(since: lastSpeech) }
            return .none

        case let .pausing(since):
            let gap = t - since
            if speech {
                model.resumed(after: gap)
                phase = .hearing
                lastSpeech = t
                if drafted {
                    drafted = false
                    heard = false
                    return .abandon
                }
                return .none
            }
            if !drafted && gap >= model.draft() {
                drafted = true
                return .draft
            }
            if drafted && heard && gap >= model.wait(after: ending) {
                phase = .replying(since: t)
                unprompted = false
                replyPause = gap
                drafted = false
                heard = false
                model.replied()
                return .commit
            }
            return .none

        case .replying:
            guard speech && probability >= Self.bargeInProbability else {
                overlapStart = nil
                overlapReported = false
                return .none
            }
            let start = overlapStart ?? t
            overlapStart = start
            if !overlapReported && t - start >= Self.bargeIn {
                overlapReported = true
                return .overlap(since: start)
            }
            return .none
        }
    }

    /// The draft's transcript ended this way; the turn can now be committed.
    public mutating func transcribed(_ ending: Ending) {
        self.ending = ending
        heard = true
    }

    /// The draft heard no words: noise, a cough. Nobody's turn.
    public mutating func discard() {
        phase = .waiting
        drafted = false
        heard = false
    }

    /// The overlap was the reply's own voice coming back: keep talking.
    public mutating func overlapWasEcho() {
        overlapStart = nil
        overlapReported = false
    }

    /// They talked over the reply from `since`; it stops, and the turn is theirs.
    public mutating func interrupted(since: Double) {
        if case let .replying(started) = phase, since - started < Self.cutInWindow, !unprompted {
            // They hadn't finished: that pause was inside their turn.
            model.resumed(after: replyPause)
            model.cutIn()
        }
        phase = .hearing
        lastSpeech = since
        ending = .statement
        overlapStart = nil
        overlapReported = false
    }

    /// The companion says something of its own accord, with nobody talking;
    /// false if somebody is.
    public mutating func speakUnprompted(at t: Double) -> Bool {
        guard phase == .waiting else { return false }
        phase = .replying(since: t)
        unprompted = true
        return true
    }

    /// The reply has been said in full.
    public mutating func replyFinished() {
        phase = .waiting
        overlapStart = nil
        overlapReported = false
    }
}
