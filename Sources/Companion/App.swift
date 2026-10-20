import CompanionEngine
import CompanionUI
import SwiftUI

@main
struct CompanionApp: App {
    @State private var companion = Companion()

    var body: some Scene {
        WindowGroup("Companion") {
            ContentView(companion: companion)
                .frame(minWidth: 480, minHeight: 420)
        }
        .defaultSize(width: 760, height: 620)
        .windowResizability(.contentMinSize)
    }
}
