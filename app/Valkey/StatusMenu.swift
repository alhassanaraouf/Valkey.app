import SwiftUI
import ServiceManagement

/// Contents of the menu-bar menu: each server with its own actions, then app-level items.
struct StatusMenu: View {
    @EnvironmentObject var store: ServerStore
    @Environment(\.openWindow) private var openWindow
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

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
        Toggle("Open at Login", isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin))
        Divider()
        Button("Quit Valkey.app") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled { try service.register() } else { try service.unregister() }
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
        }
        openAtLogin = service.status == .enabled
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
