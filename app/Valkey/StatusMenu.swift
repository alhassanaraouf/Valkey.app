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
        Divider()
        Button("Quit Valkey.app") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    @ViewBuilder private var settingsItem: some View {
        if #available(macOS 14, *) {
            SettingsLink { Text("Settings…") }.keyboardShortcut(",")
        } else {
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .keyboardShortcut(",")
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
