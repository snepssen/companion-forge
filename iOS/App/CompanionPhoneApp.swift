import CompanionEngine
import CompanionUI
import SwiftUI

@main
struct CompanionPhoneApp: App {
    @State private var companion = Companion()

    var body: some Scene {
        WindowGroup {
            ContentView(companion: companion)
                // It listens while it is on screen, as translate-core's
                // Interpreter does: iOS takes the microphone and the GPU away
                // from an app in the background. Leaving stops it and writes
                // the conversation up; coming back starts it again.
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                    companion.stop()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    Task { await companion.start() }
                }
        }
    }
}
