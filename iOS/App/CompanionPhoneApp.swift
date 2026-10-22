import CompanionEngine
import CompanionUI
import SwiftUI

@main
struct CompanionPhoneApp: App {
    @State private var companion = Companion()

    var body: some Scene {
        WindowGroup {
            ContentView(companion: companion)
                // It listens while it is on screen, as interpreter-forge's
                // Interpreter does: iOS takes the microphone and the GPU away
                // from an app in the background. Leaving stops it and writes
                // the conversation up; coming back starts it again.
                //
                // While it's in front, the screen stays on: it's a face to talk
                // to, not something to wake every minute. Leaving lets it sleep.
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                    UIApplication.shared.isIdleTimerDisabled = false
                    companion.stop()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    UIApplication.shared.isIdleTimerDisabled = true
                    Task { await companion.start() }
                }
        }
    }
}
