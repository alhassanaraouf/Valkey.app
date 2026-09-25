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
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
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
            SettingsLink { Text("Settings…") }
        } else {
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
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
