import Foundation

// Knowing its person's voice. It's one person's companion, a talking journal:
// it learns what they sound like, and anyone else is a guest, met kindly,
// told nothing it knows about its person, and kept out of its memory.
//
// The voice is a voiceprint (CAM++, from FluidAudio): the average of the
// prints of what its person has said, steadier the more it hears. Measured
// with ccrun --speakers on thirteen system voices, eight clips each: matched
// against an averaged print at 0.80, every clip over 1.5 s went to the right
// voice and none to a wrong one. Short turns decide nothing.

/// Its person's voice.
public struct OwnerVoice: Codable, Equatable, Sendable {
    /// The average print of what they've said, unit length.
    public var print: [Float]
    /// How many turns went into it.
    public var heard: Int
    public var first: Date
    public var last: Date
}

public struct Household: Codable, Equatable, Sendable {
    /// Its person, once heard: the first voice it hears for long enough.
    public private(set) var owner: OwnerVoice?

    /// This close to their print is them.
    public static let same: Float = 0.80
    /// Further than this is someone else.
    public static let other: Float = 0.70
    /// Shorter turns are too little to go on: "yeah", "hm".
    public static let long = 1.5
    /// The average stops weighting new turns less after this many.
    static let memory = 50

    public init() {}

    public enum Heard: Equatable, Sendable {
        /// Its person, and how alike.
        case owner(Float)
        /// Someone else, and how alike to its person.
        case guest(Float)
        /// Too short or too close to call: whoever was talking still is.
        case unsure
    }

    /// A turn's print, `seconds` long, at `date`, learning their voice from
    /// it when it's surely theirs.
    public mutating func hear(_ print: [Float], seconds: Double, at date: Date = Date()) -> Heard {
        guard !print.isEmpty else { return .unsure }
        guard var owner else {
            guard seconds >= Self.long else { return .unsure }
            owner = OwnerVoice(print: print, heard: 1, first: date, last: date)
            return .owner(1)
        }
        let score = Self.cosine(owner.print, print)
        if score >= Self.same {
            if seconds >= Self.long {
                let weight = Float(min(owner.heard, Self.memory))
                owner.print = Self.normalised(zip(owner.print, print).map { $0 * weight + $1 })
                owner.heard += 1
            }
            owner.last = date
            self.owner = owner
            return .owner(score)
        }
        return seconds >= Self.long && score < Self.other ? .guest(score) : .unsure
    }

    /// How like its person `print` is, if it knows them yet.
    public func likeness(_ print: [Float]) -> Float? { owner.map { Self.cosine($0.print, print) } }

    /// Whether a turn sounds enough like its person to wake it: a longer
    /// one clearly, a short "hey" (too short to be sure of) roughly. Before
    /// it knows them, anyone does.
    public func wakes(_ print: [Float]?, seconds: Double) -> Bool {
        guard let owner else { return true }
        guard let print else { return false }
        let score = Self.cosine(owner.print, print)
        return score >= (seconds >= Self.long ? Self.same : Self.roughly)
    }

    /// A short turn this like its person may be them.
    public static let roughly: Float = 0.6

    /// Forget their voice, to learn it again.
    public mutating func forget() { owner = nil }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    static func normalised(_ v: [Float]) -> [Float] {
        let length = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? v.map { $0 / length } : v
    }

    /// A guest's turn is marked so; its person's turns aren't marked at
    /// all, as no turn was before there were voices.
    public static let guest = "guest"

    /// The conversation as whoever is talking may see it: each only their
    /// own side. Told everything, it told a guest about its person's nerves
    /// over a visit mentioned minutes before; and shown the guest's side, it
    /// told its person about a cousin it had made up for the guest.
    public static func visible(_ turns: [Turn], toGuest: Bool) -> [Turn] {
        var lastPerson: String?
        return turns.filter { turn in
            if turn.speaker == .person { lastPerson = turn.who }
            return (lastPerson == guest) == toGuest
        }
    }

    /// The conversation as its memory keeps it: without a guest's turns or
    /// the replies to them.
    public static func ownersOnly(_ turns: [(index: Int, turn: Turn)]) -> [(index: Int, turn: Turn)] {
        var lastPerson: String?
        return turns.filter { item in
            if item.turn.speaker == .person { lastPerson = item.turn.who }
            return lastPerson != guest
        }
    }
}
