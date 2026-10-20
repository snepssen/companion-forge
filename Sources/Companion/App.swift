import AppKit
import CompanionEngine
import CompanionUI
import SwiftUI

@main
struct CompanionApp: App {
    @NSApplicationDelegateAdaptor private var delegate: Delegate
    @State private var companion = Companion()

    var body: some Scene {
        WindowGroup("Companion") {
            ContentView(companion: companion)
                .frame(minWidth: 480, minHeight: 420)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    companion.stop()
                }
        }
        .defaultSize(width: 760, height: 620)
        .windowResizability(.contentMinSize)
    }

    /// It listens for as long as its window is open: closing it quits.
    final class Delegate: NSObject, NSApplicationDelegate {
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    }
}
