import Foundation

// The memory, in three layers. At the bottom, every conversation in full
// (`ConversationLog`). Above it, notes: short sentences about the person,
// written by the model after a conversation, each pointing back to the turns
// it came from. On top, the lasting notes (their name, their work, the people
// in their life), which go into every reply. Before each reply the notes are
// searched for what is relevant to what was just said; the full turns behind
// a note are read again only when the person asks about the past.

/// Something worth remembering, and where it came from.
public struct Note: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var text: String
    /// The conversation log it was written from, and the turns in it.
    public var session: String
    public var turns: ClosedRange<Int>
    public var at: Date
    /// Will stay true for months: who they are rather than what happened.
    public var lasting: Bool
    /// Its meaning, as the embedding model has it; unit length.
    public var vector: [Float]

    public init(id: String = UUID().uuidString, text: String, session: String, turns: ClosedRange<Int>, at: Date,
                lasting: Bool, vector: [Float]) {
        self.id = id
        self.text = text
        self.session = session
        self.turns = turns
        self.at = at
        self.lasting = lasting
        self.vector = vector
    }
}

/// Every note, and how far into each conversation they have been written.
public struct MemoryStore: Codable, Sendable, Equatable {
    /// A new note this close in meaning to an old one replaces it: the same
    /// thing said again. With bge-small (ccrun --recall), "They have no eggs
    /// at home" and "They don't have any eggs in the house" are 0.96 apart;
    /// two different facts about the same dog are 0.84, and both are kept. A
    /// fact that changed ("They moved to Leeds" after "They live in York",
    /// 0.70) is kept too, and both are dated: the newer is the one believed.
    public static let sameThing: Float = 0.92
    /// How relevant a note must be to be brought up at all, and how close to
    /// the most relevant. Measured with ccrun --memory: the right notes scored
    /// 0.58 to 0.68 and the next-best wrong ones 0.41 to 0.48, so a floor alone
    /// would either let those through or lose the right ones; what separates
    /// them is how far behind the best they are. "What's the weather like?"
    /// found nothing above 0.42. What it can't do is infer: "What should I
    /// make for breakfast?" scored the note about having no eggs 0.44.
    public static let relevant = 0.45
    public static let band = 0.12
    static let profileSize = 12

    public private(set) var notes: [Note] = []
    /// Per session, the first turn not yet written up.
    public private(set) var written: [String: Int] = [:]

    public init() {}

    /// Add a note; returns the notes it replaced.
    @discardableResult
    public mutating func add(_ note: Note) -> [Note] {
        let replaced = notes.filter { Self.cosine($0.vector, note.vector) >= Self.sameThing }
        var note = note
        // Once lasting, still lasting: a passing mention doesn't demote their name.
        if replaced.contains(where: \.lasting) { note.lasting = true }
        notes.removeAll { old in replaced.contains { $0.id == old.id } }
        notes.append(note)
        return replaced
    }

    public mutating func wrote(_ session: String, through next: Int) {
        written[session] = max(written[session] ?? 0, next)
    }

    public func next(in session: String) -> Int { written[session] ?? 0 }

    public mutating func forget(_ id: String) { notes.removeAll { $0.id == id } }

    public mutating func forgetAll() {
        notes = []
        written = [:]
    }

    /// The lasting notes, newest first: what it knows about them, always.
    public var profile: [Note] {
        Array(notes.filter(\.lasting).sorted { $0.at > $1.at }.prefix(Self.profileSize))
    }

    /// The notes most relevant to `text`, best first. Meaning counts most,
    /// shared words (names above all) add to it, and recency breaks near-ties.
    /// Lasting notes are left out: they are in every reply already.
    public func recall(_ text: String, vector: [Float], limit: Int = 3, atLeast floor: Double = relevant,
                       now: Date = Date()) -> [(note: Note, score: Double)] {
        let words = Self.words(text)
        let scored = notes.filter { !$0.lasting }
            .map { note -> (note: Note, score: Double) in
                let meaning = Double(Self.cosine(vector, note.vector))
                let shared = Self.overlap(words, Self.words(note.text))
                let days = now.timeIntervalSince(note.at) / 86_400
                return (note, meaning + 0.2 * shared + 0.02 * exp(-days / 30))
            }
            .filter { $0.score >= floor }
            .sorted { $0.score > $1.score }
        guard let best = scored.first?.score else { return [] }
        return scored.filter { $0.score >= best - Self.band }.prefix(limit).map { $0 }
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var (dot, x, y): (Float, Float, Float) = (0, 0, 0)
        for index in a.indices {
            dot += a[index] * b[index]
            x += a[index] * a[index]
            y += b[index] * b[index]
        }
        return x > 0 && y > 0 ? dot / (x.squareRoot() * y.squareRoot()) : 0
    }

    static let common: Set<String> = [
        "the", "a", "an", "and", "or", "but", "so", "to", "of", "in", "on", "at", "for", "with", "is", "are", "was",
        "were", "be", "been", "it", "its", "it's", "this", "that", "they", "them", "their", "i", "me", "my", "you",
        "your", "we", "our", "do", "did", "does", "have", "has", "had", "what", "how", "about", "just", "really",
        "some", "any", "not", "no", "yes", "can", "could", "would", "should", "will", "there", "here", "then", "too",
        "very", "like", "get", "got", "know", "think", "today", "now", "one",
    ]

    public static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init).filter { $0.count > 2 && !common.contains($0) }.map(stem))
    }

    /// Crudely, so "walking", "walked" and "walks" meet at "walk".
    static func stem(_ word: String) -> String {
        for suffix in ["ing", "ed", "es", "s"] where word.hasSuffix(suffix) && word.count - suffix.count >= 3 {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }
}

/// What the memory brings to one reply.
public struct Recollection: Sendable, Equatable {
    public var profile: [Note]
    public var notes: [Note]
    /// The turns behind the most relevant note, when they asked about the past.
    public var excerpt: [Turn]

    public init(profile: [Note] = [], notes: [Note] = [], excerpt: [Turn] = []) {
        self.profile = profile
        self.notes = notes
        self.excerpt = excerpt
    }

    public var isEmpty: Bool { profile.isEmpty && notes.isEmpty && excerpt.isEmpty }

    /// For the instructions: what it knows about them.
    public var knowing: String? {
        guard !profile.isEmpty else { return nil }
        return "What you know about them, from earlier conversations:\n"
            + profile.map { "- \($0.text)" }.joined(separator: "\n")
    }

    /// Put before what they just said: what came to mind.
    public func reminder(now: Date = Date()) -> String? {
        guard !notes.isEmpty || !excerpt.isEmpty else { return nil }
        var lines = ["(This came to mind from earlier conversations. Use it if it helps; don't recite it.)"]
        lines += notes.map { "- \(Remembering.when($0.at, now: now)): \($0.text)" }
        if !excerpt.isEmpty {
            lines.append("What was said then, word for word:")
            lines += excerpt.map { "  \($0.speaker == .person ? "Them" : "You"): \($0.text)" }
        }
        return lines.joined(separator: "\n")
    }
}

/// Writing notes from a conversation, and reading them back out of the model.
public enum Remembering {
    /// At most this many turns are written up at once.
    public static let chunk = 30
    /// Fewer new turns than this wait for more.
    public static let fewest = 2

    public static let instructions = """
    You keep the memory of a companion that talks out loud with one person. Read the conversation and write \
    down what is worth remembering about them later, as short notes, one per line, each starting with the \
    numbers of the turns it comes from, like this:
    - [3-5] They walked by the river this evening and loved it.
    - [8] Their sister is visiting next week.
    - [11] They work in a bakery. (lasting)
    Begin every note with "They" or "Their". Worth remembering: their name, facts about them and the people \
    and pets in their life, what they like and dislike, plans and promises, things that happened to them, how \
    they felt about something that mattered, anything they asked you to remember. Not worth it: greetings, \
    small talk, general questions, what the companion suggested unless they took it up, anything you already \
    know. If they say their name, always note it. End a note with (lasting) when it will stay true for months: \
    their name, their work, where they live, who the people and pets in their life are. Write at most eight \
    notes, only from what was said. If nothing is worth remembering, write only: NONE
    """

    /// The conversation as the note writer reads it, turns numbered as in the log.
    public static func transcript(_ turns: [(index: Int, turn: Turn)], known: [String]) -> String {
        var text = ""
        if !known.isEmpty {
            text += "You already know:\n" + known.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        text += "The conversation:\n"
        text += turns.map { "[\($0.index)] \($0.turn.speaker == .person ? "Person" : "Companion"): \($0.turn.text)" }
            .joined(separator: "\n")
        return text
    }

    public struct Written: Equatable, Sendable {
        public var turns: ClosedRange<Int>
        public var text: String
        public var lasting: Bool
    }

    /// The notes in the model's answer: lines like `- [3-5] They ...`, turn
    /// numbers held to the turns it was shown. Anything else is ignored.
    public static func parse(_ output: String, turns valid: ClosedRange<Int>) -> [Written] {
        output.split(separator: "\n").compactMap { line -> Written? in
            guard let match = line.firstMatch(of: /^\s*[-*•]?\s*\[(\d+)(?:\s*[-–]\s*(\d+))?\]\s*(.+?)\s*$/) else { return nil }
            guard let first = Int(match.1) else { return nil }
            let last = match.2.flatMap { Int($0) } ?? first
            let low = min(max(min(first, last), valid.lowerBound), valid.upperBound)
            let high = min(max(max(first, last), valid.lowerBound), valid.upperBound)
            var text = String(match.3)
            let lasting = text.range(of: "(lasting)", options: .caseInsensitive) != nil
            text = text.replacingOccurrences(of: "(lasting)", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespaces)
            guard text.split(separator: " ").count >= 3 else { return nil }
            return Written(turns: low...high, text: text, lasting: lasting || looksLasting(text))
        }
    }

    /// Notes that are about who they are, whether or not the model marked
    /// them: a 4B model asked to mark them seldom does (ccrun --memory).
    public static func looksLasting(_ text: String) -> Bool {
        let people = "sister|brother|mom|mum|mother|father|dad|partner|wife|husband|girlfriend|boyfriend|son|daughter"
            + "|kid|child|children|friend|best friend|roommate|flatmate|dog|cat|pet|puppy|kitten"
        let patterns = [
            "^their name is ", "^they(?:'re| are) called ", "^they (?:work|works) (?:as|at|in|for|on) ",
            "^they (?:live|lives) (?:in|at|near|with) ", "^they are \\d+ years old",
            "^their (?:\(people)) (?:\\w+ )?(?:is|are) (?:called|named) ",
            "^they (?:have|has|own|owns) an? (?:\(people))(?: \\w+)?,? (?:called|named) ",
        ]
        let lower = text.lowercased()
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    /// Asking about the past: then the turns behind a note are worth reading again.
    public static func asksAboutThePast(_ text: String) -> Bool {
        text.lowercased().contains(/\b(remember|recall|last time|the other day|you said|i said|i told you|we talked|did i (mention|say|tell)|what was (it|that)|earlier)\b/)
    }

    /// When, as people say it.
    public static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "Today"
        case 1: return "Yesterday"
        case 2..<7: return "\(days) days ago"
        case 7..<14: return "Last week"
        case 14..<31: return "\(days / 7) weeks ago"
        case 31..<60: return "Last month"
        case 60..<365: return "\(days / 30) months ago"
        default: return days < 730 ? "A year ago" : "\(days / 365) years ago"
        }
    }
}
