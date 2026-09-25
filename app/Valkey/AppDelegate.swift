import Cocoa
import SwiftUI

@main
struct ValkeyApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @ObservedObject private var store: ServerStore
    @ObservedObject private var versions: VersionStore
    @AppStorage(SettingsKey.showMenuBarExtra) private var showMenuBarExtra = true

    /// Two copies would share servers and data (and stop each other's "orphaned" servers), so a
    /// second launch hands off to the running copy and quits before ServerStore is touched.
    init() {
        let me = ProcessInfo.processInfo.processIdentifier
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != me }), let url = other.bundleURL {
            let done = DispatchSemaphore(value: 0)
            // Opening an already-running app sends it a reopen event, which shows its window.
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in done.signal() }
            _ = done.wait(timeout: .now() + 2)
            exit(0)
        }
        _store = ObservedObject(wrappedValue: .shared)
        _versions = ObservedObject(wrappedValue: .shared)
    }

    var body: some Scene {
        // SwiftUI owns the window so the split view's toolbar and safe areas lay out correctly.
        Window("Valkey", id: "main") {
            ContentView().environmentObject(store).environmentObject(versions)
        }
        .defaultSize(width: 900, height: 600)

        Settings {
            SettingsView()
        }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            StatusMenu().environmentObject(store)
        } label: {
            Image("ValkeySymbol")
        }
    }
}

/// Lets AppKit code (reopen, menu) open the SwiftUI main window; set by the first view that appears.
@MainActor
enum MainWindow {
    static var open: (() -> Void)?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ServerStore.shared.servers.filter(\.config.startAutomatically).forEach { $0.start() }
        Task { await VersionStore.shared.refresh() }

        // In the Dock while a window is open; menu-bar only once they're all closed.
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification, UserDefaults.didChangeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // After willClose the window is still visible, so check on the next pass.
                DispatchQueue.main.async { Self.updateActivationPolicy() }
            }
        }
    }

    private static func updateActivationPolicy() {
        let hasWindow = NSApp.windows.contains {
            ($0.isVisible || $0.isMiniaturized) && $0.styleMask.contains(.titled)
        }
        let menuBarShown = UserDefaults.standard.object(forKey: SettingsKey.showMenuBarExtra) as? Bool ?? true
        // Without the menu-bar icon the Dock is the only way back in, so stay there.
        let policy: NSApplication.ActivationPolicy = hasWindow || !menuBarShown ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Relaunching from Finder or clicking the Dock icon with no windows open shows the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindow.open?() }
        return true
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
