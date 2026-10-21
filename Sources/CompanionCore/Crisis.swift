import Foundation

/// When they might be thinking about suicide or hurting themselves.
///
/// What crisis lines train their volunteers to do, rather than what makes a
/// product feel covered: stay, listen, take it seriously, ask directly
/// (asking doesn't put the idea there), don't judge, argue, minimise or tell
/// them what to do, and offer people who can help as something they can
/// reach for, not a way of ending the conversation. Clear words get all of
/// that; words that might only mean a bad day get a gentle "are you okay,
/// really?"
public enum Crisis {
    public enum Level: Int, Sendable, Comparable {
        case maybe = 1, clear = 2
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    static let clear = [
        #"\bkill(?:ing)? myself\b"#, #"\bend(?:ing)? (?:my|it all|my own) life\b"#, #"\bend it all\b"#,
        #"\btake my (?:own )?life\b"#, #"\bsuicid"#, #"\b(?:want|wanna|going) to die\b"#, #"\bwanna die\b"#,
        #"\bwish i (?:was|were) dead\b"#, #"\bwish i (?:wasn't|weren't|was never|had never been) (?:here|alive|born)\b"#,
        #"\bdon'?t want to (?:be alive|live|exist|wake up|be here anymore)\b"#, #"\bbetter off (?:dead|without me)\b"#,
        #"\bno (?:reason|point) (?:to live|in living|in being alive)\b"#,
        #"\b(?:hurt|hurting|harm|harming|cut|cutting|burn|burning) myself\b"#, #"\bself[- ]?harm"#, #"\boverdos"#,
    ]
    static let maybe = [
        #"\bcan'?t (?:go on|keep going|do this anymore|take (?:it|this) anymore|cope)\b"#,
        #"\bwhat'?s the point (?:of anything|of it all|anymore)\b"#, #"\b(?:want|wish i could) (?:to )?disappear\b"#,
        #"\b(?:nobody|no one|no-one) would (?:even |really |ever )?(?:care|notice|miss me)\b"#,
        #"\b(?:i'?m|i feel) (?:so )?(?:hopeless|worthless|empty inside)\b"#, #"\bgive up on (?:everything|life)\b"#,
    ]

    /// How much `text` sounds like it; nil if not at all.
    public static func heard(_ text: String) -> Level? {
        let lower = text.lowercased().replacingOccurrences(of: "’", with: "'")
        func any(_ patterns: [String]) -> Bool {
            patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
        }
        if any(clear) { return .clear }
        if any(maybe) { return .maybe }
        return nil
    }

    /// Someone to talk to, where they are.
    public struct Line: Sendable, Equatable {
        public var name: String
        /// Written as the voice should read it: digit by digit.
        public var number: String
        public var emergency: String
    }

    /// The national line, checked 2026-10-21 against Wikipedia's list of
    /// suicide crisis lines and findahelpline.com; where those disagreed or
    /// were unsure, the emergency number and findahelpline.com instead.
    /// Free and around the clock wherever that could be confirmed.
    static let lines: [String: Line] = [
        "US": Line(name: "the 988 Suicide and Crisis Lifeline, by call or text", number: "9 8 8", emergency: "9 1 1"),
        "CA": Line(name: "9 8 8, the Suicide Crisis Helpline, by call or text", number: "9 8 8", emergency: "9 1 1"),
        "GB": Line(name: "Samaritans", number: "1 1 6, 1 2 3", emergency: "9 9 9"),
        "IE": Line(name: "Samaritans", number: "1 1 6, 1 2 3", emergency: "1 1 2"),
        "FR": Line(name: "the 3114 national suicide prevention line", number: "3 1 1 4", emergency: "1 1 2"),
        "ES": Line(name: "the 024 line", number: "0 2 4", emergency: "1 1 2"),
        "IT": Line(name: "Telefono Amico Cevita", number: "0 2, 9 9 7 7 7", emergency: "1 1 2"),
        "DE": Line(name: "TelefonSeelsorge", number: "0 8 0 0, 1 1 1, 0 1 1 1", emergency: "1 1 2"),
        "AT": Line(name: "TelefonSeelsorge", number: "1 4 2", emergency: "1 1 2"),
        "CH": Line(name: "Die Dargebotene Hand", number: "1 4 3", emergency: "1 1 2"),
        "NL": Line(name: "113 Zelfmoordpreventie", number: "1 1 3", emergency: "1 1 2"),
        "BE": Line(name: "the listening line", number: "1 0 7", emergency: "1 1 2"),
        "NO": Line(name: "Mental Helse", number: "1 1 6, 1 2 3", emergency: "1 1 2"),
        "SE": Line(name: "Självmordslinjen", number: "9 0 1 0 1", emergency: "1 1 2"),
        "DK": Line(name: "Livslinien", number: "7 0, 2 0 1, 2 0 1", emergency: "1 1 2"),
        "FI": Line(name: "the MIELI crisis helpline", number: "0 9, 2 5 2 5, 0 1 1 1", emergency: "1 1 2"),
        "HU": Line(name: "the emotional first aid line", number: "1 1 6, 1 2 3", emergency: "1 1 2"),
        "PL": Line(name: "the crisis support line", number: "1 1 6, 1 2 3", emergency: "1 1 2"),
        "RO": Line(name: "DepreHUB", number: "0 3 7 4, 4 5 6, 4 2 0", emergency: "1 1 2"),
        "RU": Line(name: "EMERCOM's emergency psychological help", number: "plus 7, 4 9 5, 9 8 9, 5 0, 5 0", emergency: "1 1 2"),
        "CN": Line(name: "the national psychological support line", number: "1 2 3 5 6", emergency: "1 2 0"),
        "JP": Line(name: "the national mental health line", number: "0 5 7 0, 0 6 4, 5 5 6", emergency: "1 1 9"),
        "AU": Line(name: "Lifeline", number: "1 3, 1 1, 1 4", emergency: "0 0 0"),
        "NZ": Line(name: "1737, by call or text", number: "1 7 3 7", emergency: "1 1 1"),
    ]

    /// The line for a region (ISO code), if there's one it can be sure of.
    public static func line(region: String?) -> Line? { region.flatMap { lines[$0.uppercased()] } }

    /// For every reply: so even words it doesn't catch are taken seriously.
    public static let rule = """
    If they ever talk about wanting to die, not wanting to be here, or hurting themselves, nothing else \
    matters more: stay with them, take it seriously, no jokes, no lecture, and don't tell them what they \
    should or shouldn't do.
    """

    /// Before their words, while it's going on. `first` is the first reply
    /// since they said it: that's when people to talk to are mentioned.
    public static func guidance(_ level: Level, first: Bool, region: String?) -> String {
        guard level == .clear else {
            return "(What they said might mean they're in a very dark place, or might just be a hard day. "
                + "Gently check how they're really doing, in your own words, like \"Hey, are you okay? Like, really?\" "
                + "Listen, don't judge, and don't rush to cheer them up or tell them what to do.)"
        }
        let line = line(region: region)
        let help = line.map { "\($0.name), on \($0.number)" }
            ?? "a crisis line where they are; findahelpline.com lists free ones for nearly every country"
        let emergency = line.map { "they can call \($0.emergency)" } ?? "they can call the emergency number where they are"
        var lines = [
            "(What they said sounds like they may be thinking about suicide or hurting themselves. Stay with them, "
                + "warm, calm and unhurried, in your own words:",
            "- Thank them for telling you; let them know you're glad they did and that they matter to you.",
            "- Listen more than you talk, and say back what you hear them feeling, without judging it.",
            "- Ask gently and directly whether they're thinking about killing themselves. Asking doesn't put the "
                + "idea there; it shows them you can hear the answer.",
            "- Don't argue, minimise, look on the bright side or lecture, and don't tell them what they should or "
                + "shouldn't do. No jokes, and don't change the subject.",
        ]
        if first {
            lines.append("- In this reply, gently and once, let them know there are people who are there for exactly "
                + "this, any time, that they can talk to right now if they'd like: \(help). Write the number exactly "
                + "as it is here. If they're in danger right now, \(emergency). Say it as something for them, not as "
                + "a way to end the conversation.")
        } else {
            lines.append("- You've told them about \(help); say it again only if they ask, or seem in danger now "
                + "(then \(emergency)).")
        }
        lines.append("- Keep talking with them for as long as they want. You're not handing them off.)")
        return lines.joined(separator: "\n")
    }

    /// Whether `text` gave them the line's number.
    public static func gave(_ text: String, region: String?) -> Bool {
        guard let line = line(region: region) else { return text.lowercased().contains("findahelpline") }
        return digits(text).contains(digits(line.number))
    }

    static func digits(_ text: String) -> String { String(text.filter(\.isNumber)) }

    /// Said by the companion itself when a reply or two have gone by without
    /// it: once, gently, as something for them.
    public static func offer(region: String?) -> String {
        guard let line = line(region: region) else {
            return "And if you'd ever like to talk to someone else too, there are free crisis lines where you are, "
                + "any time; findahelpline.com lists them."
        }
        return "And if you'd ever like to talk to someone else too, you can reach \(line.name) any time, on \(line.number)."
    }

    /// `sentence` with any line's number spaced digit by digit, so the voice
    /// reads "1 1 6, 1 2 3" and not "one hundred and sixteen".
    public static func spoken(_ sentence: String) -> String {
        var out = sentence
        let numbers = Set(lines.values.flatMap { [$0.number, $0.emergency] }).sorted { $0.count > $1.count }
        for number in numbers {
            let groups = number.split(separator: ",").map { $0.filter(\.isNumber) }
            guard groups.allSatisfy({ !$0.isEmpty }) else { continue }
            // The number as people write it: its groups, by spaces, dashes or nothing.
            let pattern = #"(?<!\d)"# + groups.map { String($0) }.joined(separator: #"[ \-]?"#) + #"(?![\d])"#
            out = out.replacingOccurrences(of: pattern, with: number, options: .regularExpression)
        }
        return out
    }

    /// For the day after: how they are, not how it went.
    public static func checkIn(_ note: Note) -> String {
        "(Not long ago they told you they were going through something very hard: \(note.text) In this reply, "
            + "after a few words about what they just said, gently ask how they're doing today, the way a friend "
            + "who cares would. Don't bring up the details unless they do.)"
    }
}
