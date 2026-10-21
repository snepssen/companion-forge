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
        // A very hard time: how they're doing, the next morning.
        if Crisis.heard(text) != nil {
            return calendar.date(byAdding: DateComponents(day: 1, hour: 8), to: calendar.startOfDay(for: said))
        }
        // Told after the fact: they already said how it went.
        if happened(text) { return nil }
        let day = calendar.startOfDay(for: said)
        func on(_ days: Int, hour: Int = 17) -> Date? {
            calendar.date(byAdding: DateComponents(day: days, hour: hour), to: day)
        }
        func has(_ pattern: String) -> Bool { lower.range(of: pattern, options: .regularExpression) != nil }
        func at(_ date: Date, days: Int = 0, hour: Int = 17) -> Date? {
            calendar.date(byAdding: DateComponents(day: days, hour: hour), to: date)
        }

        // A time to it: asked about after. An evening thing the next
        // morning, a weekend on the Monday, anything else that evening.
        if let when = When.read(text, said: said, calendar: calendar) {
            switch when.part {
            case .evening: return at(when.day, days: 1, hour: 8)
            case .weekend: return at(when.day, days: 2, hour: 8)
            case .day, .around: return at(when.day)
            }
        }
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

    /// Told after the fact ("Their interview went well"): nothing to wait for.
    public static func happened(_ text: String) -> Bool {
        text.lowercased().range(of: #"^(?:they|their [\w' ]+?) (?:had|went|was|were|did|got|finished|passed|failed|loved|hated|enjoyed|liked)\b"#,
                                options: .regularExpression) != nil
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
        if Crisis.heard(note.text) != nil { return Crisis.checkIn(note) }
        return "(\(Remembering.when(note.at, now: now)) they told you: \(note.text) In this reply, after a few words about "
            + "what they just said, catch up on it the way a friend suddenly remembers, like \"Oh wait, how did the "
            + "interview go?\" Only if they're upset about something, leave it for another time.)"
    }

    /// Whether `reply` brought `note` up: shares a word with it. "I hope
    /// the interview went well" catches up as well as a question does.
    public static func asked(_ reply: String, about note: Note) -> Bool { mentions(reply, note.text) }

    /// Whether `reply` speaks of what `text` is about: a word they share,
    /// other than the ordinary ones every note has.
    public static func mentions(_ reply: String, _ text: String) -> Bool {
        let ordinary: Set<String> = ["they", "their", "them", "have", "has", "with", "this", "that", "next", "week",
                                     "tonight", "tomorrow", "today", "going", "over", "some", "about"]
        let theirs = MemoryStore.words(text).subtracting(ordinary.map { MemoryStore.stem($0) })
        return !theirs.isDisjoint(with: MemoryStore.words(reply))
    }
}
