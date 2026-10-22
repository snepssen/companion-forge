import AppKit
import CompanionCore
import CompanionEngine
import CompanionUI
import SwiftUI

/// Moves preferences and the saved window off the old bundle ID before
/// SwiftUI or AppKit open either of them.
@main
enum CompanionMain {
    static func main() {
        BundleMigration.migrateMacLibrary()
        CompanionApp.main()
    }
}

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
