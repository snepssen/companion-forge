import Foundation

/// When something happens, read from how people say it: "tonight",
/// "tomorrow", "on Friday", "this weekend", "on the 3rd", "March 12th",
/// "12 March", "next week", "in two weeks". Counted from the day it was
/// said, so a note written on Wednesday about "Friday" means that Friday.
public struct When: Codable, Equatable, Sendable {
    public enum Part: String, Codable, Sendable {
        /// Some time that day.
        case day
        /// That evening.
        case evening
        /// That weekend; `day` is its Saturday.
        case weekend
        /// About then ("next week", "in a month"): not a day to remind them on.
        case around
    }

    /// The start of the day it falls on.
    public var day: Date
    public var part: Part
    /// Comes round every year: a birthday, an anniversary.
    public var yearly: Bool

    public init(day: Date, part: Part, yearly: Bool = false) {
        self.day = day
        self.part = part
        self.yearly = yearly
    }

    static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
                         "october", "november", "december"]
    static let monthPattern = "(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|"
        + "sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"
    static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// The time `text` speaks of, said on `said`; nil if it names none.
    public static func read(_ text: String, said: Date, calendar: Calendar = .current) -> When? {
        let lower = text.lowercased()
        let today = calendar.startOfDay(for: said)
        let yearly = lower.range(of: #"\b(?:birthday|anniversary)\b"#, options: .regularExpression) != nil
        func plus(_ days: Int) -> Date { calendar.date(byAdding: .day, value: days, to: today) ?? today }
        func has(_ pattern: String) -> Bool { lower.range(of: pattern, options: .regularExpression) != nil }
        func groups(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower))
            else { return nil }
            return (1..<match.numberOfRanges).map { i in
                Range(match.range(at: i), in: lower).map { String(lower[$0]) } ?? ""
            }
        }
        func month(_ name: String) -> Int? { months.firstIndex { $0.hasPrefix(String(name.prefix(3))) }.map { $0 + 1 } }

        // A date: "12 March", "the 12th of March", "March 12th".
        let ordinal = #"(\d{1,2})(?:st|nd|rd|th)?"#
        var named: (month: Int, day: Int)?
        if let g = groups(#"\b(?:the )?"# + ordinal + #"(?: of)? "# + monthPattern + #"\b"#), let d = Int(g[0]), let m = month(g[1]) {
            named = (m, d)
        } else if let g = groups(#"\b"# + monthPattern + #" (?:the )?"# + ordinal + #"\b"#), let m = month(g[0]), let d = Int(g[1]) {
            named = (m, d)
        }
        if let named, (1...31).contains(named.day) {
            let year = calendar.component(.year, from: today)
            for y in [year, year + 1] {
                if let date = calendar.date(from: DateComponents(year: y, month: named.month, day: named.day)), date >= today {
                    return When(day: date, part: .day, yearly: yearly)
                }
            }
        }
        // "On the 3rd": this month, or next if it's gone.
        if let g = groups(#"\bon the (\d{1,2})(?:st|nd|rd|th)\b"#), let d = Int(g[0]), (1...31).contains(d) {
            var parts = calendar.dateComponents([.year, .month], from: today)
            parts.day = d
            for _ in 0..<3 {
                if let date = calendar.date(from: parts), date >= today, calendar.component(.day, from: date) == d {
                    return When(day: date, part: .day, yearly: yearly)
                }
                parts.month = (parts.month ?? 1) + 1
            }
        }

        if has(#"\b(?:tonight|this evening|later tonight)\b"#) { return When(day: today, part: .evening) }
        if has(#"\bday after tomorrow\b"#) { return When(day: plus(2), part: .day) }
        if has(#"\btomorrow (?:night|evening)\b"#) { return When(day: plus(1), part: .evening) }
        if has(#"\btomorrow\b"#) { return When(day: plus(1), part: .day) }
        if has(#"\b(?:today|this afternoon|later today|this morning)\b"#) { return When(day: today, part: .day) }
        let weekday = calendar.component(.weekday, from: today) - 1  // 0 Sunday
        let saturday = (6 - weekday + 7) % 7
        if has(#"\bnext weekend\b"#) { return When(day: plus(saturday + 7), part: .weekend) }
        if has(#"\b(?:this weekend|at the weekend|on the weekend|over the weekend)\b"#) {
            return When(day: plus(saturday), part: .weekend)
        }
        for (index, name) in weekdays.enumerated() where has(#"\b"# + name + #"s?\b"#) {
            var ahead = (index - weekday + 7) % 7
            if ahead == 0 { ahead = 7 }
            if has(#"\bnext "# + name) && ahead < 4 { ahead += 7 }
            let evening = has(name + #" (?:night|evening)\b"#)
            return When(day: plus(ahead), part: evening ? .evening : .day, yearly: yearly)
        }
        if let g = groups(#"\bin (a|an|one|two|three|four|five|six|\d+) (day|week|month)s?\b"#) {
            let counts = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6]
            let n = counts[g[0]] ?? Int(g[0]) ?? 1
            let days = n * (g[1] == "day" ? 1 : g[1] == "week" ? 7 : 30)
            return When(day: plus(days), part: g[1] == "day" ? .day : .around)
        }
        if has(#"\bnext week\b"#) { return When(day: plus(7), part: .around) }
        if has(#"\bnext month\b"#) { return When(day: plus(30), part: .around) }
        // "Before March", "by April": the start of that month, about then.
        if let g = groups(#"\b(?:before|by|in) "# + monthPattern + #"\b"#), let m = month(g[0]) {
            let year = calendar.component(.year, from: today)
            for y in [year, year + 1] {
                if let date = calendar.date(from: DateComponents(year: y, month: m, day: 1)), date >= today {
                    return When(day: date, part: .around)
                }
            }
        }
        return nil
    }

    /// The next time it comes round on or after `date`: itself, or for a
    /// yearly thing, this year's or next year's.
    public func next(onOrAfter date: Date, calendar: Calendar = .current) -> Date? {
        let start = calendar.startOfDay(for: date)
        guard yearly else { return day >= start ? day : nil }
        let parts = calendar.dateComponents([.month, .day], from: day)
        let year = calendar.component(.year, from: start)
        for y in [year, year + 1] {
            if let candidate = calendar.date(from: DateComponents(year: y, month: parts.month, day: parts.day)),
               candidate >= start {
                return candidate
            }
        }
        return nil
    }
}
