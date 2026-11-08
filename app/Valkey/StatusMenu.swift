import SwiftUI

/// Contents of the menu-bar menu: each server with its own actions, then app-level items.
struct StatusMenu: View {
    @EnvironmentObject var store: ServerStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(store.servers) { ServerMenu(server: $0) }
        if store.servers.isEmpty {
            Text("No servers")
        }
        Divider()
        Button("Open Valkey…") {
            showWindow { openWindow(id: "main") }
        }
        .onAppear { MainWindow.open = { openWindow(id: "main") } }
        settingsItem
        CheckForUpdatesButton()
        SendFeedbackButtons()
        Divider()
        // No ⌘Q hint: ⌘Q only closes to the menu bar, while this really quits.
        Button("Quit Valkey.app") { AppDelegate.quitCompletely() }
    }

    /// No ⌘, hint here: shortcuts only work in the app's own menu, not while this menu is open.
    @ViewBuilder private var settingsItem: some View {
        if #available(macOS 14, *) {
            OpenSettingsButton()
        } else {
            Button("Settings…") {
                showWindow { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
            }
        }
    }
}

/// With no window open the app is menu-bar only and inactive. Opening a window then is unreliable: it
/// stays behind other apps, and Settings sometimes doesn't open while the app is inactive. So join the
/// Dock, open, activate, and if the window still isn't there once the menu has closed, open it again.
/// (Activating first instead makes SwiftUI also open the main window.)
private func showWindow(_ open: @escaping () -> Void) {
    let titled = { NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) } }
    let before = Set(titled().map(ObjectIdentifier.init))
    NSApp.setActivationPolicy(.regular)
    open()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        NSApp.activate(ignoringOtherApps: true)
        if titled().allSatisfy({ before.contains(ObjectIdentifier($0)) }) { open() }
        DispatchQueue.main.async {
            titled().last?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// SettingsLink can't activate the app first, so open Settings programmatically instead.
@available(macOS 14, *)
private struct OpenSettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            showWindow { openSettings() }
        }
    }
}

private struct ServerMenu: View {
    @ObservedObject var server: ValkeyServer

    var body: some View {
        Menu {
            Button(server.isStopping ? "Stopping…" : server.isRunning ? "Stop" : "Start") {
                server.isRunning ? server.stop() : server.start()
            }
            .disabled(server.isStopping)
            Button("Connect…") { server.openCLI() }.disabled(!server.isRunning || server.isStopping)
            CopyURLButton(server: server)
            Button("Show Data Directory") { server.showDataDir() }
        } label: {
            Label("\(server.config.name) — Port \(String(server.config.port))",
                  systemImage: server.isRunning ? "checkmark.circle.fill" : "circle")
        }
    }
}

/// Copies the connection URL; with ACL users it becomes a menu with one entry per user.
struct CopyURLButton: View {
    @ObservedObject var server: ValkeyServer

    var body: some View {
        if server.config.accounts.isEmpty {
            Button("Copy URL") { server.copyConnectionURL() }
        } else {
            Menu("Copy URL") {
                Button("Default user") { server.copyConnectionURL() }
                ForEach(server.config.accounts) { user in
                    Button(user.name) { server.copyConnectionURL(for: user) }
                }
            }
        }
    }
}
