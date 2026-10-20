import CompanionEngine
import CompanionUI
import SwiftUI

@main
struct CompanionPhoneApp: App {
    @State private var companion = Companion()

    var body: some Scene {
        WindowGroup {
            ContentView(companion: companion)
                // Listening is foreground-only, as translate-core's is: iOS
                // takes the microphone and the GPU away from an app in the
                // background. Leaving stops the conversation, which also
                // writes it up.
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                    companion.stop()
                }
        }
    }
}
