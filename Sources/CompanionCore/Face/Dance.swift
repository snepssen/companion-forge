import Foundation

// Dancing to music in the room: the kick drum heard in the microphone, the
// tempo of the music, and the head (and eyes) moving point to point along a
// pattern, each move landing on the next kick.

/// Kick drums in microphone audio: the thump below about 150 Hz rising
/// sharply over a few hundredths of a second. Every hundredth of a second it
/// also reports how sharply that low end rose (its onset strength), which is
/// what the tempo is found from: a kick it misses still shows there.
///
/// Speech has energy down there too, and its onsets get through; what speech
/// lacks is a steady beat, which `Tempo` asks for before anything dances.
public struct KickDetector: Sendable {
    let rate: Double
    let hop: Int
    private let pole: Float
    private var low1: Float = 0
    private var low2: Float = 0
    private var sum = 0.0
    private var filled = 0
    private var levels: [Double] = []  // the last few hops' low-band level, dB
    private var rises: [Double] = []  // the last second and a half of rises
    private var last = -1e9

    /// Nothing quieter than this, in dB of low-band level, is a kick.
    static let floor = -48.0
    /// A rise of at least this many dB, and well above the recent ones.
    static let rise = 5.0
    /// Two kicks closer than this are one.
    static let refractory = 0.2

    public init(rate: Double = 16_000) {
        self.rate = rate
        hop = Int(rate / 100)
        pole = Float(1 - exp(-2 * Double.pi * 150 / rate))
    }

    public struct Heard: Sendable {
        /// When kicks were heard.
        public var kicks: [Double] = []
        /// Onset strength, one a hundredth of a second, the last at `end`.
        public var strengths: [Double] = []
        public var end: Double = 0
    }

    /// Feeds the next samples of the stream, whose first sample is at
    /// `start` seconds on the caller's clock.
    public mutating func hear(_ block: [Float], at start: Double) -> Heard {
        var heard = Heard(end: start)
        for (i, x) in block.enumerated() {
            low1 += pole * (x - low1)
            low2 += pole * (low1 - low2)
            sum += Double(low2 * low2)
            filled += 1
            guard filled == hop else { continue }
            let level = 10 * log10(sum / Double(hop) + 1e-12)
            sum = 0
            filled = 0
            let rise = level > Self.floor ? max(0, level - (levels.min() ?? level)) : 0
            levels.append(level)
            if levels.count > 3 { levels.removeFirst() }
            let mean = rises.isEmpty ? 0 : rises.reduce(0, +) / Double(rises.count)
            let spread = rises.isEmpty ? 0
                : (rises.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(rises.count)).squareRoot()
            rises.append(rise)
            if rises.count > 150 { rises.removeFirst() }
            let time = start + Double(i + 1) / rate
            heard.strengths.append(rise)
            heard.end = time
            // A third of a second to learn what the room sounds like first.
            if rises.count > 30, rise > max(Self.rise, mean + 2 * spread), time - last > Self.refractory {
                heard.kicks.append(time)
                last = time
            }
        }
        return heard
    }
}

/// How long a beat is: the onset strength of the last six seconds compared
/// with itself shifted, and the shift at which it lines up best (a kick
/// that skips a beat, or one missed, hardly matters). Leaning towards 120
/// beats a minute where a song could be counted either way, and keeping the
/// beat it has while that still fits nearly as well.
public struct Tempo: Sendable {
    static let window = 600  // hundredths of a second
    /// 60 to 200 beats a minute, in hundredths.
    static let lags = 30...100
    /// How well the best shift must line up, as a share of a perfect fit,
    /// to start dancing, and to keep on. Measured: speech alone never went
    /// past 0.22; songs with a beat sat between 0.4 and 0.8.
    static let sure = 0.3
    static let stillSure = 0.22

    private var strengths: [Double] = []
    private var pending = 0
    private var heardAt = -1e9
    public private(set) var current: Double?
    public private(set) var confidence = 0.0

    public init() {}

    public mutating func hear(_ more: [Double], at end: Double) {
        strengths += more
        if strengths.count > Self.window { strengths.removeFirst(strengths.count - Self.window) }
        pending += more.count
        heardAt = end
        // Twice a second, once there are four seconds to go on.
        if pending >= 50, strengths.count >= 400 {
            pending = 0
            estimate()
        }
    }

    /// Seconds a beat, or nil while there is no steady beat.
    public func beat(at time: Double) -> Double? { time - heardAt < 1 ? current : nil }

    mutating func estimate() {
        let mean = strengths.reduce(0, +) / Double(strengths.count)
        let e = strengths.map { $0 - mean }
        let energy = e.reduce(0) { $0 + $1 * $1 }
        guard energy > 1e-9 else { current = nil; return }
        var fit = [Double](repeating: 0, count: Self.lags.upperBound + 2)
        for lag in (Self.lags.lowerBound - 1)...(Self.lags.upperBound + 1) {
            var sum = 0.0
            for i in lag..<e.count { sum += e[i] * e[i - lag] }
            fit[lag] = sum / energy
        }
        func weighted(_ lag: Int) -> Double { fit[lag] * exp(-0.5 * pow(log2(Double(lag) / 50), 2)) }
        guard var best = Self.lags.max(by: { weighted($0) < weighted($1) }) else { return }
        // Keep the beat it has, if that still fits nearly as well; and when
        // the best is just twice or half it (the same music counted the
        // other way), a little less well will do.
        if let current {
            let kept = Int((current * 100).rounded())
            let octave = [0.5, 2].contains { abs(Double(best) / Double(kept) - $0) < 0.06 }
            if Self.lags.contains(kept), let near = (kept - 2...kept + 2).filter({ Self.lags.contains($0) })
                .max(by: { weighted($0) < weighted($1) }), weighted(near) >= (octave ? 0.6 : 0.8) * weighted(best) {
                best = near
            }
        }
        confidence = fit[best]
        guard confidence >= (current == nil ? Self.sure : Self.stillSure) else { current = nil; return }
        // Between the hundredths: the peak of a parabola through three.
        let (a, b, c) = (fit[best - 1], fit[best], fit[best + 1])
        let shift = a - 2 * b + c < 0 ? 0.5 * (a - c) / (a - 2 * b + c) : 0
        current = (Double(best) + max(-0.5, min(0.5, shift))) / 100
    }
}

public struct Dance: Sendable {
    public enum Pattern: String, CaseIterable, Sendable {
        /// Up and down, a nod a beat.
        case nod
        /// A figure of eight through four points.
        case infinity
    }

    public var pattern: Pattern
    private var tempo = Tempo()
    /// The kick it last set off on: from where along the pattern, to which point.
    private var anchor: (time: Double, from: Double, to: Int, beat: Double)?
    private var began = -1e9
    private var lastKick = -1e9
    /// When the tempo was last known.
    private var sure = -1e9

    public init(pattern: Pattern = .infinity) { self.pattern = pattern }

    /// How far along the pattern point `index` is. Increasing, so a move
    /// always goes forward along the curve.
    public func angle(_ index: Int) -> Double {
        switch pattern {
        case .nod: Double(index) * .pi
        case .infinity: .pi / 4 + Double(index) * .pi / 2
        }
    }

    /// Where on the pattern `angle` is, -1...1 each way, y down.
    public func place(_ angle: Double) -> Point {
        switch pattern {
        // Down on the beat, up between.
        case .nod: Point(0, -cos(angle))
        // A lemniscate: through the middle, round one side, through the
        // middle again, round the other. Its four points are its corners;
        // the loops reach a little wider between them.
        case .infinity: Point(cos(angle), sin(2 * angle))
        }
    }

    static func ease(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        return 0.6 * t * t * (3 - 2 * t) + 0.4 * t
    }

    /// The angle along the pattern at `time`, from the last kick it set off on.
    func angle(at time: Double) -> Double? {
        guard let anchor else { return nil }
        let elapsed = max(0, (time - anchor.time) / anchor.beat)
        let n = Int(elapsed)
        let progress = Self.ease(elapsed - Double(n))
        let from = n == 0 ? anchor.from : angle(anchor.to + n - 1)
        return from + (angle(anchor.to + n) - from) * progress
    }

    /// What the microphone just heard: onset strengths for the tempo, and
    /// kicks to step on.
    public mutating func hear(_ heard: KickDetector.Heard) {
        tempo.hear(heard.strengths, at: heard.end)
        if tempo.beat(at: heard.end) != nil { sure = heard.end }
        for kick in heard.kicks { self.kick(at: kick) }
    }

    /// A kick at `time`. Once the tempo is known it steps on it, if it falls
    /// on the beat.
    public mutating func kick(at time: Double) {
        let wasDancing = amount(at: time) > 0
        lastKick = time
        guard let beat = tempo.beat(at: time).map(Self.step) else { return }
        guard wasDancing, let anchor, let now = angle(at: time) else {
            // Starting: from the first point, to the second.
            anchor = (time, angle(0), 1, beat)
            began = time
            return
        }
        // Where in its beat the kick fell. Near the end: on time, it has
        // arrived; near the start: a little late, it has only just left.
        // In between: a kick off the beat, which it lets pass.
        let elapsed = (time - anchor.time) / anchor.beat
        let n = Int(elapsed), progress = elapsed - Double(n)
        guard progress >= 0.75 || progress <= 0.25 else { return }
        let target = anchor.to + n + (progress >= 0.75 ? 1 : 0)
        self.anchor = (time, now, target, beat)
    }

    /// Seconds a beat, while there is a steady one.
    public func beat(at time: Double) -> Double? { tempo.beat(at: time) }
    /// How well the music lines up with its beat (0 to 1), for measuring.
    public var confidence: Double { tempo.confidence }

    /// How long a move takes for a beat this long: a beat each, or two
    /// above 150 beats a minute, where a move a beat is a frantic one.
    public static func step(_ beat: Double) -> Double { beat < 0.4 ? beat * 2 : beat }

    /// For tests and measuring: the tempo found directly, as from onset strengths.
    public mutating func hearTempo(_ strengths: [Double], at end: Double) {
        tempo.hear(strengths, at: end)
        if tempo.beat(at: end) != nil { sure = end }
    }

    /// 0 to 1: how much it is dancing. Rises over a beat once it steps to
    /// a steady beat, and falls over a second once the beat or the kicks stop.
    public func amount(at time: Double) -> Double {
        guard let anchor else { return 0 }
        let lost = max(time - sure - 2, time - lastKick - max(2, 3 * anchor.beat))
        let rising = (time - began) / anchor.beat
        return min(1, max(0, rising), max(0, 1 - lost))
    }

    /// Where the head is on the pattern at `time` (-1...1 each way, y
    /// down), and how much it is dancing. nil when it isn't.
    public func at(_ time: Double) -> (point: Point, amount: Double)? {
        let amount = amount(at: time)
        guard amount > 0, let angle = angle(at: time) else { return nil }
        return (place(angle), amount)
    }

    /// How far the head goes, in face widths, and how far the eyes go.
    static let reach = Point(0.035, 0.025)
    static let gaze = 0.6
    static let tiltDegrees = 2.0

    /// `pose` moved to `step`: the head along the pattern, the eyes with it,
    /// arriving together on the beat.
    public static func apply(_ step: (point: Point, amount: Double)?, to pose: Pose) -> Pose {
        guard let step else { return pose }
        var pose = pose
        let move = step.point * step.amount
        pose.offset = pose.offset + move * reach
        pose.tilt += move.x * tiltDegrees
        pose.gaze = pose.gaze + (step.point * gaze - pose.gaze) * step.amount
        return pose
    }
}
