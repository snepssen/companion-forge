import Foundation

/// Saying hello when they open it, as a friend does when you walk in: a few
/// words, fitting the time of day and how long it's been, and anything worth
/// catching up on. Not when they were only just here.
public enum Greeting {
    /// Back within this long: no hello, they never really left.
    public static let away: TimeInterval = 2 * 3600

    /// What goes to the model in place of their words; nil when it should
    /// stay quiet. `last` is when they last talked, nil if they never have.
    /// Something to catch up on, or coming up, goes into the same hello:
    /// told separately, both Gemmas left it out of a greeting.
    public static func cue(last: Date?, checkIn: Note? = nil, coming: (day: Date, happening: Happening)? = nil,
                           now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let last else {
            return "(They've just opened you for the very first time. Say hi in a sentence or two: you're glad to "
                + "meet them, and you'd like to know their name. Don't list what you can do.)"
        }
        guard now.timeIntervalSince(last) >= away else { return nil }
        let when = calendar.isDate(last, inSameDayAs: now) ? "earlier today" : Remembering.when(last, now: now).lowercased()
        var cue = "(They've just opened you; you last talked \(when). Greet them in a few words, like a friend who's "
            + "glad to see them. Don't describe the weather or the light, which you can't see, and don't ask how you "
            + "can help."
        if let (day, happening) = coming {
            let on = calendar.isDate(day, inSameDayAs: now) ? "today" : "tomorrow"
            cue += " In the same breath, mention what's coming up \(on), from what they told you: \(happening.text)"
        } else if let checkIn {
            let told = Remembering.when(checkIn.at, now: now).lowercased()
            cue += Crisis.heard(checkIn.text) != nil
                ? " Then gently ask how they're doing today; \(told) they were going through something very hard."
                : " Then ask how this went, as a friend catching up (they told you \(told)): \(checkIn.text)"
        }
        return cue + ")"
    }

    /// In the conversation the model reads, before its greeting: chat
    /// templates want their words first, and without it the greeting was
    /// dropped, and with it what it had asked them.
    public static let opened = "(They've just opened the app.)"
}
