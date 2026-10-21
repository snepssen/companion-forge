import Foundation

/// A word the voice says, timed from the start of its clip.
public struct SpokenWord: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(_ text: String, _ start: Double, _ end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }

    /// Word times for a clip of `duration` seconds saying `text`, shared out by
    /// length. Piper doesn't say where its words fall; spelling-length timing,
    /// smoothed the way protoke smooths, is close enough for a mouth.
    public static func estimate(_ text: String, duration: Double) -> [SpokenWord] {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let (lead, tail) = (0.06, 0.12)
        let available = max(0, duration - lead - tail)
        let weights = words.map { Double($0.filter(\.isLetter).count + 1) }
        let total = weights.reduce(0, +)
        guard total > 0, available > 0 else { return [] }
        var cursor = lead
        return zip(words, weights).map { word, weight in
            let span = available * weight / total
            defer { cursor += span }
            return SpokenWord(word, cursor, cursor + span * 0.9)
        }
    }
}

/// Words to a moving mouth (protoke's face_visemes.py): each word split into
/// the articulations you can see, its time shared out between them, and the
/// mouth gliding between shapes rather than cutting.
public enum Visemes {
    static let vowelGroups: [String: Viseme] = [
        "oo": .oo, "ou": .oh, "ow": .oh, "oa": .oh, "oi": .oh, "oy": .oh,
        "ee": .ee, "ea": .ee, "ie": .ee, "ei": .ee, "ey": .ee,
        "ai": .eh, "ay": .eh, "au": .oh, "aw": .oh,
        "ue": .oo, "ui": .oo, "eu": .oo, "ew": .oo,
    ]
    static let vowels: [Character: Viseme] = ["a": .ah, "e": .eh, "i": .ee, "o": .oh, "u": .oo, "y": .ee]
    /// Consonants worth a shape of their own; the rest ride on the vowel beside them.
    static let consonants: [String: Viseme] = [
        "m": .mm, "b": .mm, "p": .mm, "f": .ff, "v": .ff, "w": .oo, "r": .oo,
        "th": .th, "s": .th, "z": .th, "sh": .oo, "ch": .oo, "j": .oo, "l": .ll,
    ]
    static let vowelWeight = 2.2
    static let consonantWeight = 1.0

    /// How long the mouth takes to settle after a phrase, and how early it
    /// starts forming the next: the mouth shapes a sound before it is heard.
    public static let release = 0.14
    public static let anticipate = 0.13
    /// Shorter gaps are inside a phrase: the mouth glides on without closing.
    static let glideGap = 0.40
    static let betweenWords = Mouth(0.84, 0.10, 0.50)

    static func sequence(_ word: String) -> [(Viseme, Double)] {
        let text = Array(word.lowercased().filter(\.isLetter))
        guard !text.isEmpty else { return [(.rest, 1)] }
        var sequence: [(Viseme, Double)] = []
        var index = 0
        while index < text.count {
            if index + 1 < text.count {
                let pair = String(text[index...index + 1])
                if let viseme = vowelGroups[pair] {
                    sequence.append((viseme, vowelWeight))
                    index += 2
                    continue
                }
                if let viseme = consonants[pair] {
                    sequence.append((viseme, consonantWeight))
                    index += 2
                    continue
                }
            }
            if let viseme = vowels[text[index]] {
                sequence.append((viseme, vowelWeight))
            } else if let viseme = consonants[String(text[index])] {
                sequence.append((viseme, consonantWeight))
            }
            index += 1
        }
        // An all-invisible word ("shh") still opens the mouth a little.
        guard var collapsed = sequence.first.map({ [$0] }) else { return [(.ll, 1)] }
        for (viseme, weight) in sequence.dropFirst() {
            if viseme == collapsed[collapsed.count - 1].0 {
                collapsed[collapsed.count - 1].1 += weight * 0.4
            } else {
                collapsed.append((viseme, weight))
            }
        }
        return collapsed
    }

    /// Spans covering every word, in order, shared out by spelling.
    public static func timeline(_ words: [SpokenWord], minimumHold: Double = 0.055) -> [VisemeSpan] {
        var spans: [VisemeSpan] = []
        for word in words {
            let end = max(word.end, word.start + minimumHold)
            var sequence = self.sequence(word.text)
            let available = end - word.start
            // Too short to show every articulation: keep the strongest, in order.
            let affordable = max(1, Int(available / minimumHold))
            if sequence.count > affordable {
                let strongest = sequence.indices.sorted { sequence[$0].1 > sequence[$1].1 }.prefix(affordable)
                sequence = strongest.sorted().map { sequence[$0] }
            }
            let total = sequence.reduce(0) { $0 + $1.1 }
            var cursor = word.start
            for (viseme, weight) in sequence {
                let step = available * weight / (total == 0 ? 1 : total)
                spans.append(VisemeSpan(cursor, cursor + step, viseme))
                cursor += step
            }
        }
        return spans.sorted { $0.start < $1.start }
    }

    /// Mouth keys: one at the centre of each articulation, none inside a
    /// phrase so the mouth travels straight on, a ready position across a
    /// longer gap, and rest at the end.
    public static func keys(_ words: [SpokenWord]) -> [(time: Double, mouth: Mouth)] { keys(timeline(words)) }

    public static func keys(_ spans: [VisemeSpan]) -> [(time: Double, mouth: Mouth)] {
        guard let first = spans.first else { return [] }
        let rest = Viseme.rest.mouth
        var keys: [(time: Double, mouth: Mouth)] = [(max(0, first.start - anticipate), rest)]
        for (index, span) in spans.enumerated() {
            keys.append(((span.start + span.end) / 2, span.viseme.mouth))
            guard index + 1 < spans.count else {
                keys.append((span.end + release, rest))
                continue
            }
            let following = spans[index + 1]
            if following.start - span.end > glideGap {
                keys.append((span.end + release, betweenWords))
                keys.append((following.start - anticipate, betweenWords))
            }
        }
        return keys.sorted { $0.time < $1.time }
    }

    static func smoothstep(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    /// The mouth at `time`, eased between the keys either side.
    public static func mouth(_ keys: [(time: Double, mouth: Mouth)], at time: Double) -> Mouth {
        guard let first = keys.first, let last = keys.last else { return Viseme.rest.mouth }
        if time <= first.time { return first.mouth }
        if time >= last.time { return last.mouth }
        // The last key at or before `time`.
        var (low, high) = (0, keys.count - 1)
        while low < high {
            let middle = (low + high + 1) / 2
            if keys[middle].time <= time { low = middle } else { high = middle - 1 }
        }
        let (a, b) = (keys[low], keys[min(low + 1, keys.count - 1)])
        let span = b.time - a.time
        guard span > 0 else { return b.mouth }
        return a.mouth.blended(b.mouth, smoothstep(min(1, max(0, (time - a.time) / span))))
    }
}

/// Blinks, as protoke draws them: skewed intervals averaging one every few
/// seconds, some in pairs, from a fixed seed so the schedule can be looked up
/// rather than kept up.
public struct Blinks: Sendable {
    public static let length = 0.16
    public static let every = 4.5
    static let doubleChance = 0.18
    static let doubleGap = 0.14
    let times: [Double]

    public init(duration: Double = 6 * 3600, seed: UInt32 = 20_260_906, every: Double = every) {
        var state = seed & 0x7FFF_FFFF
        func next() -> Double {
            state = (1_103_515_245 &* state &+ 12345) & 0x7FFF_FFFF
            return Double(state) / Double(0x7FFF_FFFF)
        }
        var times: [Double] = []
        var time = every * (0.25 + 0.55 * next())
        while time < duration {
            // Right-skewed around the average: mostly a little under, sometimes much longer.
            time += every * (0.42 + 1.567 * pow(next(), 1.7))
            times.append(time)
            if next() < Self.doubleChance {
                time += Self.length + Self.doubleGap
                times.append(time)
            }
        }
        self.times = times
    }

    /// 1 open, 0 shut.
    public func openness(at time: Double) -> Double {
        var (low, high) = (0, times.count)
        while low < high {
            let middle = (low + high) / 2
            if times[middle] <= time { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return 1 }
        let start = times[low - 1]
        guard time < start + Self.length else { return 1 }
        let half = Self.length / 2
        let closed = time < start + half ? (time - start) / half : (start + Self.length - time) / half
        return max(0, 1 - min(1, closed))
    }
}

/// The invisible head the visor is mounted on. With no music to dance to
/// (`Dance`) it breathes, sways and tilts on unrelated periods so it never
/// loops, and moves a little more freely while listening than while talking.
/// Faintly: at three times this it read as floating (2026-10-21).
public struct HeadMotion: Sendable {
    static let bob = 0.008
    static let sway = 0.004
    static let tiltDegrees = 0.5
    static let listening = 1.25
    static let breath = 4.7
    static let tempo = 100.0
    let phase: Double

    public init(seed: UInt32 = 20_260_906) { phase = Double(seed % 1000) / 1000 * 2 * .pi }

    /// `(dx, dy)` as fractions of the face width, and tilt in degrees.
    public func at(_ time: Double, speaking: Bool, amount: Double = 1) -> (offset: Point, tilt: Double) {
        let beats = time * Self.tempo / 60
        let breathing = sin(2 * .pi * time / Self.breath) * 0.34
        let sway = sin(2 * .pi * beats / 8 + phase)
        let tilt = sin(2 * .pi * beats / 6 + phase * 0.7)
        let drift = sin(2 * .pi * time / 17.3 + phase)
        let freedom = amount * (speaking ? 1 : Self.listening)
        return (Point(Self.sway * freedom * (sway * 0.7 + drift * 0.3), Self.bob * freedom * breathing),
                Self.tiltDegrees * freedom * (tilt * 0.75 + drift * 0.25))
    }
}

/// What the companion is doing, as the face shows it.
public enum Mood: String, Sendable {
    case idle, listening, thinking, speaking, surprised
    /// Saying something glad: protoke's happy eyes, ^ ^.
    case cheerful
    /// Still loading its models: half asleep.
    case waking

    public var expression: Expression {
        switch self {
        case .idle: .visor
        case .listening: .curious
        case .thinking: .smug
        case .speaking: .visor
        case .surprised: .wide
        case .cheerful: .happy
        case .waking: .sleepy
        }
    }

    public var isSpeaking: Bool { self == .speaking || self == .cheerful }
}

/// One frame of the face: its dials, where the head is, and how far the mouth
/// swings beyond it.
public struct Pose: Sendable {
    public var face: Face
    /// Fractions of the face width.
    public var offset: Point
    public var tilt: Double
    /// Face units.
    public var muzzle: Point
    /// Where the eyes look, -1...1 each way.
    public var gaze: Point

    public init(face: Face, offset: Point = .zero, tilt: Double = 0, muzzle: Point = .zero, gaze: Point = .zero) {
        self.face = face
        self.offset = offset
        self.tilt = tilt
        self.muzzle = muzzle
        self.gaze = gaze
    }
}

/// The live face: a mood it is easing into, the mouth keys of whatever the
/// voice is saying, blinks and the head. Times are on one clock the caller
/// chooses (the app uses system uptime); `pose(at:)` is a pure function of it,
/// so a view can ask at any frame rate.
public struct FacePerformance: Sendable {
    public static let moodBlend = 0.35
    /// How long the handover to the resting face takes once the voice stops.
    static let idleBlend = 0.4

    public private(set) var mood = Mood.idle
    private var from = Mood.idle.expression.face
    private var fromAim = Gaze.aim(.idle)
    private var changed = -1e9
    private var keys: [(time: Double, mouth: Mouth)] = []
    private var spans: [(start: Double, end: Double)] = []
    private let blinks = Blinks()
    private let head = HeadMotion()
    private let gaze = Gaze()
    private let origin: Double

    public init(origin: Double) { self.origin = origin }

    public mutating func set(_ mood: Mood, at time: Double) {
        guard mood != self.mood else { return }
        from = resting(at: time)
        fromAim = aim(at: time)
        self.mood = mood
        changed = time
    }

    /// The voice starts saying `words` at `start`, timed by their spelling.
    public mutating func say(_ words: [SpokenWord], at start: Double) {
        say(Visemes.timeline(words), at: start)
    }

    /// The voice starts saying these mouth shapes at `start`.
    public mutating func say(_ shapes: [VisemeSpan], at start: Double) {
        let new = Visemes.keys(shapes).map { (time: $0.time + start, mouth: $0.mouth) }
        guard let first = new.first, let last = new.last else { return }
        keys.removeAll { $0.time < start - 30 || $0.time >= first.time }
        keys += new
        spans.removeAll { $0.end < start - 30 }
        if let previous = spans.last, first.time - previous.end < 1.0 {
            spans[spans.count - 1].end = max(previous.end, last.time)
        } else {
            spans.append((first.time, last.time))
        }
    }

    /// The voice was cut off at `time`: close the mouth from there.
    public mutating func hush(at time: Double) {
        let mouth = Visemes.mouth(keys, at: time)
        keys.removeAll { $0.time > time }
        keys += [(time, mouth), (time + Visemes.release, Viseme.rest.mouth)]
        if let last = spans.indices.last { spans[last].end = min(spans[last].end, time + Visemes.release) }
    }

    func resting(at time: Double) -> Face {
        from.blended(mood.expression.face, moodBlend(at: time))
    }

    func moodBlend(at time: Double) -> Double { Visemes.smoothstep(min(1, max(0, (time - changed) / Self.moodBlend))) }

    /// Where the mood points the eyes and how far they wander, eased between moods.
    func aim(at time: Double) -> (target: Point, wander: Double) {
        let blend = moodBlend(at: time)
        let to = Gaze.aim(mood)
        return (fromAim.target + (to.target - fromAim.target) * blend, fromAim.wander + (to.wander - fromAim.wander) * blend)
    }

    /// 0 while the voice is going, 1 once the face has settled back to rest.
    func idleness(at time: Double) -> Double {
        for span in spans.reversed() where span.start - Self.idleBlend <= time && time <= span.end + Self.idleBlend {
            if time < span.start { return (span.start - time) / Self.idleBlend }
            if time > span.end { return (time - span.end) / Self.idleBlend }
            return 0
        }
        return 1
    }

    public func pose(at time: Double) -> Pose {
        let resting = resting(at: time)
        let idle = idleness(at: time)
        let speaking = Face(resting.eye, Visemes.mouth(keys, at: time), sharpness: resting.sharpness)
        var face = speaking.blended(resting, idle)
        face.eye.openness *= blinks.openness(at: time - origin)
        let (offset, tilt) = head.at(time - origin, speaking: idle < 1, amount: mood.expression.motion)
        let extra = FaceGeometry.mouthParallax - 1
        let muzzle = Point(offset.x * FaceGeometry.unit * extra, offset.y * FaceGeometry.unit * extra * 0.5)
        let (target, wander) = aim(at: time)
        let look = target + gaze.wandering(at: time - origin) * wander
        return Pose(face: face, offset: offset, tilt: tilt, muzzle: muzzle,
                    gaze: Point(min(1, max(-1, look.x)), min(1, max(-1, look.y))))
    }
}
