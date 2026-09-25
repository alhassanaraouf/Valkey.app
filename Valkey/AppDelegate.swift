import Cocoa
import SwiftUI

@main
struct ValkeyApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @ObservedObject private var store = ServerStore.shared

    var body: some Scene {
        // SwiftUI owns the window so the split view's toolbar and safe areas lay out correctly.
        Window("Valkey", id: "main") {
            ContentView().environmentObject(store)
        }
        .defaultSize(width: 900, height: 600)

        MenuBarExtra {
            StatusMenu().environmentObject(store)
        } label: {
            Image("ValkeySymbol")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ServerStore.shared.servers.filter(\.config.startAutomatically).forEach { $0.start() }
        // Menu-bar (LSUIElement) apps aren't activated automatically, so bring the window forward.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Stop every server before quitting so none outlives the app.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = ServerStore.shared
        guard store.servers.contains(where: \.isRunning) else { return .terminateNow }
        store.stopAll { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
