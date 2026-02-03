import SwiftUI
import AppKit

@main
struct PingletApp: App {
    @StateObject private var scanner = PingletScanner()

    init() {
        // Hide Dock icon and app switcher presence.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(scanner: scanner)
        } label: {
            PingletMenuBarIcon()
        }
        .menuBarExtraStyle(.window)
    }
}
