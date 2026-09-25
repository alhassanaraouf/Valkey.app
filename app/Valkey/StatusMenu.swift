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
            bringAppForward()
            openWindow(id: "main")
        }
        .onAppear { MainWindow.open = { openWindow(id: "main") } }
        settingsItem
        CheckForUpdatesButton()
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
                bringAppForward()
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }
}

/// With no window open the app is menu-bar only and inactive, so a window opened from this menu
/// would stay hidden behind other apps. Join the Dock and activate first.
private func bringAppForward() {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
}

/// SettingsLink can't activate the app first, so open Settings programmatically instead.
@available(macOS 14, *)
private struct OpenSettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            bringAppForward()
            openSettings()
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
            Button("Show Data Directory") { server.showDataDir() }
        } label: {
            Label("\(server.config.name) — Port \(String(server.config.port))",
                  systemImage: server.isRunning ? "checkmark.circle.fill" : "circle")
        }
    }
}
