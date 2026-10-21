import CompanionCore
import Foundation

/// Music in the microphone, for the face to dance to: each block of audio
/// listened through for kicks as it arrives, and the dance read by the face
/// every frame.
public final class BeatSense: @unchecked Sendable {
    private let lock = NSLock()
    private var detector = KickDetector()
    private var dance = Dance()
    private var on = true

    public init() {}

    /// The pattern to dance, or nil not to.
    public var pattern: Dance.Pattern? {
        get { lock.withLock { on ? dance.pattern : nil } }
        set {
            lock.withLock {
                on = newValue != nil
                if let newValue, newValue != dance.pattern { dance = Dance(pattern: newValue) }
            }
        }
    }

    /// The next block of microphone audio at 16 kHz, just arrived.
    public func hear(_ block: [Float]) {
        let start = Duplex.now - Double(block.count) / 16_000
        lock.withLock {
            dance.hear(detector.hear(block, at: start))
        }
    }

    /// Where the head is in the dance, if it is dancing.
    public func step(at time: Double = Duplex.now) -> (point: Point, amount: Double)? {
        lock.withLock { on ? dance.at(time) : nil }
    }
}
