#if os(macOS)
import AppKit
import CompanionCore
import CompanionEngine
import SwiftUI

/// A Mac has no motion sensors, but its window can be dragged about: the
/// window's own acceleration stands in for the device's, so the face swings
/// when it is thrown across the screen, and complains if it is shaken.
struct WindowMotion: NSViewRepresentable {
    let motion: MotionSense

    func makeNSView(context: Context) -> Watcher { Watcher(motion: motion) }
    func updateNSView(_ view: Watcher, context: Context) {}

    final class Watcher: NSView {
        /// Window travel, in points a second squared, that counts as one g.
        static let oneG = 3000.0
        let motion: MotionSense
        private var last: (position: CGPoint, time: Double)?
        private var velocity = CGVector.zero

        init(motion: MotionSense) {
            self.motion = motion
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Selector-based, so it is let go of with the view.
            NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: nil)
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(moved), name: NSWindow.didMoveNotification,
                                                   object: window)
        }

        @objc private func moved() {
            guard let window else { return }
            let now = Duplex.now
            let position = window.frame.origin
            defer { last = (position, now) }
            guard let last, now - last.time > 1.0 / 240 else { return }
            let dt = now - last.time
            // A pause in the drag starts afresh rather than reading as a jolt.
            let previous = dt > 0.2 ? .zero : velocity
            velocity = CGVector(dx: (position.x - last.position.x) / dt, dy: (position.y - last.position.y) / dt)
            let acceleration = Point((velocity.dx - previous.dx) / dt / Self.oneG, (velocity.dy - previous.dy) / dt / Self.oneG)
            // Screen y is up on a Mac, as it is on the device's own axes.
            motion.feel(acceleration: Point(max(-4, min(4, acceleration.x)), max(-4, min(4, acceleration.y))), at: now)
        }
    }
}
#endif
