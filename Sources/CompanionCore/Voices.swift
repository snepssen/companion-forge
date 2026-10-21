import Foundation

// Telling the people in a household apart by their voices, so each has their
// own memory: what one told it isn't brought up with another.
//
// Each person is a voiceprint (CAM++, from FluidAudio): the average of the
// prints of what they've said, which steadies as it hears more. Measured with
// ccrun --speakers on thirteen system voices, eight clips each: matched
// against averaged prints at 0.80, every clip over 1.5 s went to the right
// voice and no clip at all to a wrong one. A single clip from a voice it had
// never heard was too often taken for someone it knew, so a new person takes
// two longer turns in a row that match nobody and match each other.
// When unsure, it keeps to whoever was talking. The first voice is the owner,
// and has every note from before there were voices.

/// One person, by their voice.
public struct Voice: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String?
    /// The average print of what they've said, unit length.
    public var print: [Float]
    /// How many turns went into it.
    public var heard: Int
    public var first: Date
    public var last: Date

    public init(id: String = UUID().uuidString, name: String? = nil, print: [Float], heard: Int = 1, at date: Date) {
        self.id = id
        self.name = name
        self.print = print
        self.heard = heard
        first = date
        last = date
    }
}

public struct Household: Codable, Equatable, Sendable {
    public private(set) var voices: [Voice] = []
    /// Longer turns that matched nobody, waiting to become someone new.
    private var strangers: [[Float]] = []

    /// This close to a voice is that person.
    public static let same: Float = 0.80
    /// Further than this from everyone might be someone new.
    public static let stranger: Float = 0.70
    /// Two such turns this close to each other are one new person.
    public static let together: Float = 0.75
    /// Shorter turns are too little to go on: "yeah", "hm".
    public static let long = 1.5
    /// An average stops weighting new turns less after this many.
    static let memory = 50

    public init() {}

    enum CodingKeys: String, CodingKey { case voices }

    public init(from decoder: Decoder) throws {
        voices = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([Voice].self, forKey: .voices) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(voices, forKey: .voices)
    }

    /// The first voice it knew: the one whose notes are from before there were voices.
    public var owner: Voice? { voices.first }

    public func voice(_ id: String?) -> Voice? { id.flatMap { id in voices.first { $0.id == id } } }

    public enum Heard: Equatable, Sendable {
        /// Someone it knows, and how sure.
        case known(String, Float)
        /// Someone it hadn't heard before, now known.
        case new(String)
        /// A longer turn like nobody it knows: perhaps someone new. Nothing
        /// personal is brought up until it's sure who it is.
        case stranger(best: Float, previous: Float?)
        /// Too short or too close to call.
        case unsure
    }

    /// A turn's print, `seconds` long, at `date`.
    public mutating func hear(_ print: [Float], seconds: Double, at date: Date = Date()) -> Heard {
        guard !print.isEmpty else { return .unsure }
        guard !voices.isEmpty else {
            guard seconds >= Self.long else { return .unsure }
            voices.append(Voice(print: print, at: date))
            return .new(voices[0].id)
        }
        let scores = voices.map { Self.cosine($0.print, print) }
        let best = scores.indices.max { scores[$0] < scores[$1] }!
        if scores[best] >= Self.same {
            strangers = []
            if seconds >= Self.long { learn(print, into: best, at: date) }
            voices[best].last = date
            return .known(voices[best].id, scores[best])
        }
        guard seconds >= Self.long, scores[best] < Self.stranger else { return .unsure }
        let together = strangers.last.map { Self.cosine($0, print) }
        if let previous = strangers.last, let together, together >= Self.together {
            let voice = Voice(print: Self.average([previous, print]), heard: 2, at: date)
            voices.append(voice)
            strangers = []
            return .new(voice.id)
        }
        strangers = [print]
        return .stranger(best: scores[best], previous: together)
    }

    /// A known voice's print moved towards `print`.
    mutating func learn(_ print: [Float], into index: Int, at date: Date) {
        let weight = Float(min(voices[index].heard, Self.memory))
        voices[index].print = Self.normalised(zip(voices[index].print, print).map { $0 * weight + $1 })
        voices[index].heard += 1
    }

    public mutating func name(_ id: String, _ name: String) {
        if let i = voices.firstIndex(where: { $0.id == id }) { voices[i].name = name }
    }

    public mutating func forget(_ id: String) {
        voices.removeAll { $0.id == id }
        strangers = []
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    static func normalised(_ v: [Float]) -> [Float] {
        let length = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? v.map { $0 / length } : v
    }

    static func average(_ prints: [[Float]]) -> [Float] {
        var sum = [Float](repeating: 0, count: prints[0].count)
        for p in prints { for k in sum.indices { sum[k] += p[k] } }
        return normalised(sum)
    }

    /// The conversation as `who` may see it: their turns and the replies to
    /// them, not another person's. Told everything in one window, it told
    /// Sam about Lin's nerves over her sister, which Lin had said minutes
    /// before. Turns from before voices (no `who`) are everyone's.
    public static func visible(_ turns: [Turn], to who: String?) -> [Turn] {
        guard let who else { return turns }
        var lastPerson: String?
        return turns.filter { turn in
            if turn.speaker == .person {
                lastPerson = turn.who
                return turn.who == nil || turn.who == who
            }
            return lastPerson == nil || lastPerson == who
        }
    }

    /// A name they gave: "I'm Lin", "my name is Sam", "call me Pip". Only a
    /// capitalised word that isn't a feeling, so "I'm Tired" from a shouty
    /// transcript doesn't name anyone.
    public static func introduces(_ text: String) -> String? {
        guard let match = text.firstMatch(of: /(?:^|[.!?,]\s*|\b)(?:[Ii]'m|[Ii] am|[Mm]y name(?:'s| is)|[Cc]all me|[Tt]his is|[Ii]t's)\s+([A-Z][a-z]{1,15})\b/)
        else { return nil }
        let name = String(match.1)
        let notNames: Set<String> = ["Fine", "Good", "Okay", "Ok", "Tired", "Back", "Here", "Home", "Just", "Not", "So", "Sorry",
                                     "Sure", "Going", "Done", "Ready", "Busy", "Great", "Well", "Bored", "Hungry", "Sad",
                                     "Happy", "Late", "Still", "The", "That", "This", "What", "Me", "Really", "Very", "Pretty",
                                     "Feeling", "Doing", "Gonna", "About", "Also", "Actually", "Honestly", "Monday",
                                     "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "English", "French"]
        return notNames.contains(name) ? nil : name
    }
}
