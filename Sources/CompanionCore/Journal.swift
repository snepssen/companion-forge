import Foundation

// Under the notes, two layers the person never sees: a journal, a few lines
// the companion writes about each conversation as a diary of their days, and
// a calendar of everything they mentioned with a date to it, each entry
// pointing at the note and the journal entry it came from. Neither is a
// real calendar or anything they set up: it's what a friend who listens
// would know, so it can say "isn't your mum's birthday tomorrow?" about
// something they never thought to write down.

/// A diary entry about one stretch of conversation.
public struct JournalEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    /// When the conversation was.
    public var at: Date
    /// The log it was written from, and the turns in it.
    public var session: String
    public var turns: ClosedRange<Int>
    public var text: String
    public var vector: [Float]

    public init(id: String = UUID().uuidString, at: Date, session: String, turns: ClosedRange<Int>, text: String,
                vector: [Float]) {
        self.id = id
        self.at = at
        self.session = session
        self.turns = turns
        self.text = text
        self.vector = vector
    }
}

/// Something on their calendar: what, when, and where it was heard.
public struct Happening: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var when: When
    /// The note it was read from, and the journal entry of that conversation.
    public var note: String?
    public var journal: String?
    /// When it last reminded them it was coming.
    public var reminded: Date?

    public init(id: String = UUID().uuidString, text: String, when: When, note: String? = nil, journal: String? = nil,
                reminded: Date? = nil) {
        self.id = id
        self.text = text
        self.when = when
        self.note = note
        self.journal = journal
        self.reminded = reminded
    }
}

public enum Journal {
    public static let instructions = """
    You are a companion that talks out loud with one person, and you keep a private diary about your days \
    with them. In the conversation, "Companion" is you and "Person" is them. Write today's diary entry about \
    this conversation: two to four plain sentences about them, what they did, what happened to them, how they \
    seemed, and anything coming up for them, with days and dates as they said them. Write about them as \
    "they". Only what they said; nothing you suggested or guessed. No greeting, no title, no lists: just the \
    entry. If nothing at all happened worth a line, write only: NONE
    """

    /// An entry's sentences, and its clauses joined by "and": "a job
    /// interview on Tuesday and a present for their mum's birthday on 22
    /// October" is two things on two days.
    public static func sentences(_ text: String) -> [String] {
        text.split(whereSeparator: { ".!?;".contains($0) })
            .flatMap { $0.components(separatedBy: " and ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.split(separator: " ").count >= 3 }
    }

    /// The model's entry, tidied; nil when it wrote nothing worth keeping.
    public static func entry(from output: String) -> String? {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacing(/^(?:\*\*)?(?:dear diary|diary entry|entry)[:,.]?(?:\*\*)?\s*/.ignoresCase(), with: "")
        text = text.replacing(/\b(?:the )?[Cc]ompanion\b/) { _ in "I" }
        // A date for a heading ("October 15th."), often the wrong one: not the entry.
        text = text.replacing(/^(?:[A-Za-z]+,? )?(?:[A-Za-z]+ \d{1,2}(?:st|nd|rd|th)?|\d{1,2}(?:st|nd|rd|th)? [A-Za-z]+)(?:,? \d{4})?[.:\n]\s*/, with: "")
        guard text.uppercased() != "NONE", text.split(separator: " ").count >= 4 else { return nil }
        return text
    }
}

/// Asking about their days: what's coming up, or what they did.
public enum Agenda {
    public enum Ask: Equatable, Sendable {
        /// What's on, from `start` to the end of `end`'s day, as they put it.
        case coming(from: Date, to: Date, label: String)
        /// What they did.
        case past(from: Date, to: Date, label: String)
    }

    /// The question in `text`, if it's one.
    public static func ask(in text: String, now: Date = Date(), calendar: Calendar = .current) -> Ask? {
        let lower = text.lowercased()
        func has(_ pattern: String) -> Bool { lower.range(of: pattern, options: .regularExpression) != nil }
        let today = calendar.startOfDay(for: now)
        func plus(_ days: Int) -> Date { calendar.date(byAdding: .day, value: days, to: today) ?? today }
        let weekday = calendar.component(.weekday, from: today) - 1  // 0 Sunday
        let saturday = (6 - weekday + 7) % 7
        let monday = (1 - weekday + 7) % 7 == 0 ? 7 : (1 - weekday + 7) % 7

        let coming = #"\b(?:what(?:'s| is) (?:on|happening|coming up|planned)|what do i have|what have i got|what am i (?:doing|up to)|anything (?:on|coming up|planned|happening)|do i have anything|have i got anything|am i (?:busy|doing anything)|my plans|what(?:'s| is) my (?:week|day|weekend)|what are my plans|is there anything (?:on|coming))\b"#
        let past = #"\b(?:what did i (?:do|get up to|talk|tell|say|mention)|what was i (?:doing|up to|talking about|saying)|what happened (?:on|last|yesterday|this)|how was my|what did we (?:talk|chat|discuss|do)|what were we (?:talking|chatting) about|did i (?:tell|mention|say)|did we (?:talk|speak|chat))\b"#
        if has(coming) {
            if has(#"\b(?:today|tonight)\b"#) { return .coming(from: today, to: today, label: "today") }
            if has(#"\btomorrow\b"#) { return .coming(from: plus(1), to: plus(1), label: "tomorrow") }
            if has(#"\b(?:this )?weekend\b"#) { return .coming(from: plus(saturday), to: plus(saturday + 1), label: "this weekend") }
            if has(#"\bnext week\b"#) { return .coming(from: plus(monday), to: plus(monday + 6), label: "next week") }
            if has(#"\b(?:this )?month\b"#) { return .coming(from: today, to: plus(30), label: "this month") }
            return .coming(from: today, to: plus(7), label: "this week")
        }
        if has(past) {
            if has(#"\byesterday\b"#) { return .past(from: plus(-1), to: plus(-1), label: "yesterday") }
            if has(#"\blast weekend\b"#) {
                let back = (weekday + 1) % 7 + (weekday == 6 ? 7 : 0)  // the Saturday before this one
                return .past(from: plus(-back), to: plus(-back + 1), label: "last weekend")
            }
            if has(#"\blast week\b"#) { return .past(from: plus(-7 - weekday + 1), to: plus(-weekday), label: "last week") }
            if has(#"\b(?:today|this morning|earlier)\b"#) { return .past(from: today, to: today, label: "today") }
            for (index, name) in When.weekdays.enumerated() where has(#"\b(?:on |last )?"# + name + #"\b"#) {
                var back = (weekday - index + 7) % 7
                if back == 0 { back = 7 }
                return .past(from: plus(-back), to: plus(-back), label: "on " + name.capitalized)
            }
            return .past(from: plus(-7), to: today, label: "this past week")
        }
        return nil
    }

    /// What's on between two days (inclusive), soonest first, yearly things
    /// on this year's date.
    public static func coming(_ happenings: [Happening], from start: Date, to end: Date,
                              calendar: Calendar = .current) -> [(day: Date, happening: Happening)] {
        let last = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end
        return happenings.compactMap { happening -> (Date, Happening)? in
            guard let day = happening.when.next(onOrAfter: start, calendar: calendar), day < last else { return nil }
            return (day, happening)
        }
        .sorted { $0.0 < $1.0 }
    }

    /// For the reply to the question: what there is, or that there's nothing.
    public static func answer(_ ask: Ask, happenings: [Happening], journal: [JournalEntry],
                              calendar: Calendar = .current) -> String {
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.dateFormat = "EEEE d MMMM"
        switch ask {
        case let .coming(from, to, label):
            let found = coming(happenings, from: from, to: to, calendar: calendar)
            guard !found.isEmpty else {
                return "They haven't told you about anything \(label). Say so; don't make anything up."
            }
            return "What they've told you is coming up \(label) (from what they said, not a real calendar): "
                + found.map { "\(format.string(from: $0.day))\($0.happening.when.part == .around ? " or so" : ""): "
                    + $0.happening.text }.joined(separator: " ")
                + " Tell them in your own words, and add nothing that isn't here."
        case let .past(from, to, label):
            let last = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to)) ?? to
            let found = journal.filter { $0.at >= from && $0.at < last }.sorted { $0.at < $1.at }
            guard !found.isEmpty else {
                return "Your diary has nothing \(label); maybe you didn't talk then. Say so; don't make anything up."
            }
            return "Your diary, \(label): "
                + found.map { "\(format.string(from: $0.at)): \($0.text)" }.joined(separator: " ")
                + " Tell them in your own words, and add nothing that isn't here."
        }
    }

    /// Something to remind them of: on today (said before it's evening), or
    /// tomorrow, not reminded of in the last few days.
    public static func ahead(_ happenings: [Happening], now: Date = Date(),
                             calendar: Calendar = .current) -> (day: Date, happening: Happening)? {
        let today = calendar.startOfDay(for: now)
        let hour = calendar.component(.hour, from: now)
        return coming(happenings.filter { $0.when.part != .around }, from: today,
                      to: calendar.date(byAdding: .day, value: 1, to: today) ?? today, calendar: calendar)
            .first { day, happening in
                if let reminded = happening.reminded, now.timeIntervalSince(reminded) < 5 * 86_400 { return false }
                // Today's, early enough to still be ahead of them.
                return day > today || hour < (happening.when.part == .evening ? 18 : 12)
            }
    }

    /// What goes before their words for the reply that reminds them.
    public static func prompt(_ day: Date, _ happening: Happening, now: Date = Date(),
                              calendar: Calendar = .current) -> String {
        let when = calendar.isDate(day, inSameDayAs: now) ? "today" : "tomorrow"
        return "(Coming up \(when), from what they told you: \(happening.text) In this reply, after a few words "
            + "about what they just said, mention it in passing the way a friend remembers, like \"Oh, isn't it "
            + "your mum's birthday \(when)?\" Only if they're upset about something, leave it for another time.)"
    }
}
