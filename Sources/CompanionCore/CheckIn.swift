import Foundation

/// Catching up, as a friend does: a note about something with a time to it
/// (an interview on Friday, Sam coming over tonight, guitar lessons just
/// started) becomes worth asking about once it has happened or had a few
/// days to go somewhere, and mid-conversation, at a calm moment, it asks how
/// it went. Their answer is written up like anything else they say, so the
/// memory moves on with them.
///
/// Whether a note has a time to it is read from its words, not asked of the
/// model: a 4B model asked to mark lasting notes seldom did (`looksLasting`).
public enum CheckIn {
    /// Past this long after it fell due, it's old news: let it go.
    public static let stale: TimeInterval = 21 * 86_400

    /// When `text`, said at `said`, becomes worth asking about; nil if it has
    /// no time to it, or has happened already.
    public static func due(_ text: String, said: Date, calendar: Calendar = .current) -> Date? {
        let lower = text.lowercased()
        // Told after the fact: they already said how it went.
        if lower.range(of: #"^(?:they|their [\w' ]+?) (?:had|went|was|were|did|got|finished|passed|failed|loved|hated|enjoyed|liked)\b"#,
                       options: .regularExpression) != nil {
            return nil
        }
        let day = calendar.startOfDay(for: said)
        func on(_ days: Int, hour: Int = 17) -> Date? {
            calendar.date(byAdding: DateComponents(day: days, hour: hour), to: day)
        }
        func has(_ pattern: String) -> Bool { lower.range(of: pattern, options: .regularExpression) != nil }

        // An evening thing is asked about the next day; anything else from
        // the evening of its day.
        if has(#"\b(?:tonight|this evening|later tonight)\b"#) { return on(1, hour: 8) }
        if has(#"\bday after tomorrow\b"#) { return on(2) }
        if has(#"\btomorrow\b"#) { return on(1) }
        if has(#"\b(?:today|this afternoon|later today|this morning)\b"#) { return on(0) }
        if has(#"\bnext weekend\b"#) { return saturday(after: day, weeks: 1, calendar: calendar) }
        if has(#"\b(?:this weekend|at the weekend|on the weekend|over the weekend)\b"#) {
            return saturday(after: day, weeks: 0, calendar: calendar)
        }
        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        for (index, name) in weekdays.enumerated() where has(#"\b"# + name + #"s?\b"#) {
            let today = calendar.component(.weekday, from: day) - 1
            var ahead = (index - today + 7) % 7
            if ahead == 0 { ahead = 7 }
            return on(ahead)
        }
        if let match = lower.firstMatch(of: /\bin (a|an|one|two|three|four|five|six|\d+) (day|week|month)s?\b/) {
            let counts = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6]
            let n = counts[String(match.1)] ?? Int(match.1) ?? 1
            let days = n * (match.2 == "day" ? 1 : match.2 == "week" ? 7 : 30)
            return on(days)
        }
        if has(#"\bnext week\b"#) { return on(7) }
        if has(#"\bnext month\b"#) { return on(30) }
        if has(#"\bsoon\b"#) { return on(5) }
        // Something under way: give it a few days.
        if has(#"\b(?:started|starting|just began|is learning|are learning|learning to|learning how|is sick|are sick|has a cold|has the flu|is ill|is unwell|is recovering|is looking for|are looking for|is trying to|are trying to|is working on|are working on|training for|is reading|is moving|are moving|is planning|are planning)\b"#) {
            return on(4)
        }
        // An occasion with no day given: a couple of days on.
        if has(#"\b(?:interview|exam|test|appointment|doctor|dentist|surgery|operation|date|trip|holiday|vacation|flight|party|wedding|birthday|concert|gig|match|deadline|presentation|results|first day|new job|visit|visiting|coming over|coming to stay)\b"#) {
            return on(2)
        }
        return nil
    }

    static func saturday(after day: Date, weeks: Int, calendar: Calendar) -> Date? {
        let today = calendar.component(.weekday, from: day) - 1  // 0 Sunday
        let ahead = (6 - today + 7) % 7 + 7 * weeks
        // Asked about the Monday after: the weekend is over by then.
        return calendar.date(byAdding: DateComponents(day: ahead + 2, hour: 8), to: day)
    }

    /// The note to ask about now, if any: fallen due, not yet asked about,
    /// not yet old news; the one that fell due first.
    public static func pick(_ notes: [Note], now: Date = Date()) -> Note? {
        notes.filter { note in
            guard let due = note.due, note.checked == nil else { return false }
            return due <= now && now.timeIntervalSince(due) < stale
        }
        .min { ($0.due ?? now) < ($1.due ?? now) }
    }

    /// What goes before their words for the reply that asks. Told "if it
    /// fits", both Gemmas found it never did; the moment is chosen in code,
    /// so the reply is simply told to.
    public static func prompt(_ note: Note, now: Date = Date()) -> String {
        "(\(Remembering.when(note.at, now: now)) they told you: \(note.text) In this reply, after a few words about "
            + "what they just said, catch up on it the way a friend suddenly remembers, like \"Oh wait, how did the "
            + "interview go?\" Only if they're upset about something, leave it for another time.)"
    }

    /// Whether `reply` brought `note` up: shares a word with it. "I hope
    /// the interview went well" catches up as well as a question does.
    public static func asked(_ reply: String, about note: Note) -> Bool {
        let ordinary: Set<String> = ["they", "their", "them", "have", "has", "with", "this", "that", "next", "week",
                                     "tonight", "tomorrow", "today", "going", "over", "some", "about"]
        let theirs = MemoryStore.words(note.text).subtracting(ordinary.map { MemoryStore.stem($0) })
        return !theirs.isDisjoint(with: MemoryStore.words(reply))
    }
}
