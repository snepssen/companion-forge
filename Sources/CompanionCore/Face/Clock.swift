import Foundation

/// The time of day as the face feels it.
public enum Clock {
    /// Drowsy from eleven at night until six in the morning.
    public static let night = (from: 23, until: 6)
    /// Quiet this long, at night, before it nods off.
    public static let nodsOff = 30.0

    public static func isNight(_ date: Date = Date(), calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= night.from || hour < night.until
    }
}
