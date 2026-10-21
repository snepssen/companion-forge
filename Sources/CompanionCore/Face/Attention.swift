import Foundation

// Turning towards whoever is talking. Two ways of knowing where they are:
// the level difference between a stereo microphone's two sides, and a camera
// that sees faces and whose mouth is moving. Either gives a bearing on the
// screen as the viewer sees it: x from -1 (its left edge) to 1 (its right),
// y from -1 (top) to 1 (bottom). The face looks there.

/// Left or right from a stereo microphone: the level difference between its
/// two sides. Six decibels is most of the way to one side.
public enum StereoBearing {
    static let spread = 6.0

    /// -1 to 1, or nil when there is too little sound to tell.
    /// `flipped` swaps the sides, for a microphone that presents them mirrored.
    public static func across(left: Double, right: Double, flipped: Bool = false) -> Double? {
        guard left > 1e-4 || right > 1e-4 else { return nil }
        let difference = 20 * log10(max(right, 1e-6) / max(left, 1e-6))
        let bearing = tanh(difference / spread)
        return flipped ? -bearing : bearing
    }
}

/// A face the camera sees: where it is, and how open its mouth has been.
public struct SeenFace: Sendable, Equatable {
    /// Where on screen, as the viewer sees it.
    public var position: Point
    /// How much of the picture it fills: nearer is bigger.
    public var size: Double
    /// Mouth openness, oldest first, as a fraction of the face's height.
    public var mouth: [Double]

    public init(position: Point, size: Double, mouth: [Double]) {
        self.position = position
        self.size = size
        self.mouth = mouth
    }

    /// How much the mouth has been moving: talking opens and shuts it
    /// several times a second; a smile holds it still.
    public var talking: Double {
        guard mouth.count >= 4 else { return 0 }
        let mean = mouth.reduce(0, +) / Double(mouth.count)
        let variance = mouth.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(mouth.count)
        return variance.squareRoot()
    }

    /// A mouth moving more than this is talking.
    public static let talks = 0.02

    /// Whom to look at: the face that is talking most, if any is; otherwise
    /// the nearest, more gently. nil with nobody there.
    public static func lookAt(_ faces: [SeenFace]) -> (position: Point, weight: Double)? {
        if let talker = faces.max(by: { $0.talking < $1.talking }), talker.talking >= talks {
            return (talker.position, 1)
        }
        guard let nearest = faces.max(by: { $0.size < $1.size }) else { return nil }
        return (nearest.position, 0.4)
    }
}

/// Where the face's attention is: the bearings it has been given, smoothed,
/// and let go of when nothing new has come for a while.
public struct Attention: Sendable {
    /// How quickly it turns: most of the way in a third of a second.
    static let turn = 0.3
    /// How long it keeps looking after the last bearing.
    public static let memory = 2.5

    public private(set) var target: Point?
    private var last = -1e9

    public init() {}

    /// A bearing at `time`, as sure as `weight` (0 to 1).
    public mutating func hear(_ bearing: Point, weight: Double = 1, at time: Double) {
        let bearing = Point(min(1, max(-1, bearing.x)), min(1, max(-1, bearing.y)))
        guard let current = target, time - last < Self.memory else {
            target = bearing
            last = time
            return
        }
        let step = min(1, max(0, time - last) / Self.turn) * min(1, max(0, weight))
        target = current + (bearing - current) * step
        last = time
    }

    /// Where to look at `time`, if anywhere.
    public func look(at time: Double) -> Point? {
        time - last < Self.memory ? target : nil
    }

    /// How much each mood gives itself to looking: all of it while
    /// listening, most while speaking to them, a glance while thinking.
    public static func strength(_ mood: Mood) -> Double {
        switch mood {
        case .listening: 1
        case .speaking, .cheerful: 0.7
        case .idle: 0.6
        case .thinking, .sleepy: 0.2
        case .surprised, .waking: 0
        }
    }

    /// `pose` turned towards `look`: the eyes go there, and the head turns a
    /// little after them.
    public static func apply(_ look: Point?, mood: Mood, to pose: Pose) -> Pose {
        guard let look else { return pose }
        let strength = strength(mood)
        var pose = pose
        pose.gaze = pose.gaze + (look - pose.gaze) * strength
        pose.offset.x += look.x * 0.02 * strength
        pose.tilt += look.x * 2.5 * strength
        return pose
    }
}
