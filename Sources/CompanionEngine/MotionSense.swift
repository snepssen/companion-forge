import CompanionCore
import Foundation
#if os(iOS)
import CoreMotion
#endif

/// The device's movement, felt by the face: on a phone or tablet its motion
/// sensors; on a Mac, whatever feeds it (the window being dragged about).
/// Read every frame by the face; complains once in a while when shaken.
public final class MotionSense: @unchecked Sendable {
    private let lock = NSLock()
    private var sway = Sway()
    private var shaking = Shaking()
    private var complaints = 0
    /// Called, off the main thread, with something to say about being shaken.
    public var onShaken: (@Sendable (String) -> Void)?
    #if os(iOS)
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    #endif

    public init() {}

    /// The device moved like this (g, x right and y up; radians a second
    /// about the screen) at `time`, on `Duplex.now`'s clock.
    public func feel(acceleration: Point, rotation: Double = 0, at time: Double) {
        let complaint: String? = lock.withLock {
            sway.feel(acceleration: acceleration, rotation: rotation, at: time)
            guard shaking.feel(acceleration, at: time) else { return nil }
            defer { complaints += 1 }
            return Shaking.complaints[complaints % Shaking.complaints.count]
        }
        if let complaint { onShaken?(complaint) }
    }

    /// What the face feels now.
    public func felt(at time: Double = Duplex.now) -> Felt {
        lock.withLock {
            sway.advance(to: time)
            shaking.settle(at: time)
            return Felt(offset: sway.offset, tilt: sway.tilt, shaken: shaking.level)
        }
    }

    /// Start the motion sensors, where there are any.
    public func start() {
        #if os(iOS)
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let motion else { return }
            // Device axes, portrait: x to the right of the screen, y up it.
            self?.feel(acceleration: Point(motion.userAcceleration.x, motion.userAcceleration.y),
                       rotation: motion.rotationRate.z, at: Duplex.now)
        }
        #endif
    }

    public func stop() {
        #if os(iOS)
        manager.stopDeviceMotionUpdates()
        #endif
    }
}
