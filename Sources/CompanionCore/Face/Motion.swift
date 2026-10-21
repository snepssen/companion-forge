import Foundation

/// Where the eyes are looking: a point within -1...1 each way, right and down.
///
/// Eyes that never move read as a picture of a face. Left alone it looks
/// around: a quick dart (a saccade, under a tenth of a second) to somewhere
/// new, a hold of one to five seconds, often back to the middle. Its mood sets
/// where it looks and how far it wanders: at you while it listens, up and to
/// one side while it thinks, down while it is still waking up.
public struct Gaze: Sendable {
    static let saccade = 0.08
    /// Each mood's resting point and how far it wanders from it.
    static func aim(_ mood: Mood) -> (target: Point, wander: Double) {
        switch mood {
        case .idle: (.zero, 1)
        case .listening: (.zero, 0.15)
        case .thinking: (Point(0.7, -0.75), 0.2)
        case .speaking, .cheerful: (.zero, 0.35)
        case .surprised: (.zero, 0)
        case .waking: (Point(0, 0.6), 0.25)
        case .sleepy: (Point(0, 0.5), 0.1)
        }
    }

    /// Times it moves, and where to.
    let moves: [(time: Double, to: Point)]

    public init(duration: Double = 6 * 3600, seed: UInt32 = 1_234_567) {
        var state = seed & 0x7FFF_FFFF
        func next() -> Double {
            state = (1_103_515_245 &* state &+ 12345) & 0x7FFF_FFFF
            return Double(state) / Double(0x7FFF_FFFF)
        }
        var moves: [(Double, Point)] = []
        var time = 0.6
        while time < duration {
            // Back to the middle about a third of the time; otherwise anywhere,
            // wider than tall, as eyes range.
            let to = next() < 0.35 ? Point.zero : Point(next() * 2 - 1, (next() * 2 - 1) * 0.6)
            moves.append((time, to))
            time += 1.0 + 4.0 * pow(next(), 1.5)
        }
        self.moves = moves
    }

    /// Where it wanders at `time`, before the mood is applied.
    public func wandering(at time: Double) -> Point {
        var (low, high) = (0, moves.count)
        while low < high {
            let middle = (low + high) / 2
            if moves[middle].time <= time { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return .zero }
        let current = moves[low - 1]
        let previous = low > 1 ? moves[low - 2].to : .zero
        let progress = min(1, (time - current.time) / Self.saccade)
        return previous + (current.to - previous) * (progress * progress * (3 - 2 * progress))
    }
}

/// The face hanging behind the glass on a spring: when the device moves, the
/// face lags and swings back, and when it turns, the face tilts after it.
///
/// Driven by the device's own acceleration (in g, x right and y up, gravity
/// removed) and its rate of turn about the screen (radians a second). Stepped
/// on a fixed 120 Hz clock, so it settles the same whichever sensor feeds it
/// and however often.
public struct Sway: Sendable {
    static let stiffness = 60.0
    static let damping = 7.0
    /// One g held steady moves the face this far, in face widths.
    static let reach = 0.05
    static let tiltReach = 8.0  // degrees, for 3 radians a second
    static let step = 1.0 / 120

    public private(set) var offset = Point.zero
    private var velocity = Point.zero
    public private(set) var tilt = 0.0
    private var spin = 0.0
    private var clock: Double?
    private var push = Point.zero
    private var turn = 0.0
    private var pushedAt = -1e9

    public init() {}

    /// The device moved like this at `time`.
    public mutating func feel(acceleration: Point, rotation: Double, at time: Double) {
        advance(to: time)
        push = acceleration
        turn = rotation
        pushedAt = time
    }

    /// Bring it up to `time`. A push older than a few steps has stopped.
    public mutating func advance(to time: Double) {
        guard let start = clock else {
            clock = time
            return
        }
        var now = start
        while now + Self.step <= time {
            let live = now - pushedAt < 0.05
            let (a, r) = live ? (push, turn) : (.zero, 0)
            // The face is left behind: pushed the other way. Screen y is down.
            let force = Point(-a.x, a.y) * (Self.reach * Self.stiffness)
            let acceleration = force - offset * Self.stiffness - velocity * Self.damping
            velocity += acceleration * Self.step
            offset += velocity * Self.step
            let torque = -r * (Self.tiltReach / 3) * Self.stiffness
            spin += (torque - tilt * Self.stiffness - spin * Self.damping) * Self.step
            tilt += spin * Self.step
            now += Self.step
        }
        clock = now
        // A hard enough jolt is still only a jolt: the face stays on the visor.
        let limit = 0.12
        offset = Point(min(limit, max(-limit, offset.x)), min(limit, max(-limit, offset.y)))
        tilt = min(20, max(-20, tilt))
    }
}

/// Whether it is being shaken, and when that has gone on long enough to
/// say something about it.
///
/// Energy is the square of the device's acceleration in g, gathered and
/// leaking away over about two thirds of a second. Walking with it measures
/// about 0.05; a deliberate shake 2 and up.
public struct Shaking: Sendable {
    static let leak = 0.6
    /// Enough to widen the eyes.
    public static let startled = 0.35
    /// Enough to say something.
    public static let tooMuch = 1.2
    /// And not again for this long.
    public static let patience = 25.0

    public private(set) var energy = 0.0
    private var last: Double?
    private var spoke = -1e9

    public init() {}

    /// 0 when still, 1 when shaken hard: for the eyes.
    public var level: Double { min(1, max(0, (energy - Self.startled * 0.5) / (Self.tooMuch - Self.startled * 0.5))) }

    /// Feel `acceleration` (g) at `time`; true when it is time to complain.
    public mutating func feel(_ acceleration: Point, at time: Double) -> Bool {
        let dt = min(0.1, max(0, time - (last ?? time)))
        last = time
        let squared = acceleration.x * acceleration.x + acceleration.y * acceleration.y
        energy = energy * exp(-dt / Self.leak) + squared * dt
        guard energy >= Self.tooMuch, time - spoke >= Self.patience else { return false }
        spoke = time
        return true
    }

    /// Let it calm down up to `time` without feeling anything new.
    public mutating func settle(at time: Double) {
        let dt = max(0, time - (last ?? time))
        guard dt > 0 else { return }
        last = time
        energy *= exp(-dt / Self.leak)
    }

    /// What it says when shaken, in turn.
    public static let complaints = [
        "Woah there! This ain't a rodeo. Slow down, please.",
        "Easy, easy! My visor's spinning.",
        "Hey! I'm in here, you know. Gently, please.",
        "Whoa, whoa! Is that an earthquake, or is that you?",
        "Okay, okay, I'm awake! You can stop shaking me now.",
    ]
}

/// What the face feels of the device at a moment: how far it has swung, how
/// far it has tilted, and how shaken it is (0 to 1).
public struct Felt: Sendable, Equatable {
    public var offset: Point
    public var tilt: Double
    public var shaken: Double

    public init(offset: Point = .zero, tilt: Double = 0, shaken: Double = 0) {
        self.offset = offset
        self.tilt = tilt
        self.shaken = shaken
    }

    public static let still = Felt()

    /// `pose` as the device moved it: swung, tilted, and wide-eyed when shaken.
    public func apply(to pose: Pose) -> Pose {
        var pose = pose
        pose.offset += offset
        pose.tilt += tilt
        if shaken > 0 {
            let open = pose.face.eye.openness
            pose.face.eye = pose.face.eye.blended(Expression.wide.face.eye, shaken)
            pose.face.eye.openness = max(open, shaken)
            pose.gaze = pose.gaze * (1 - shaken)
        }
        return pose
    }
}
