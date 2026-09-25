import SwiftUI

struct SheetRequest: Identifiable {
    let id = UUID()
    let config: ValkeyServer.Config
    let isNew: Bool
}

struct ContentView: View {
    @EnvironmentObject var store: ServerStore
    @EnvironmentObject var versions: VersionStore
    @State private var selection: UUID?
    @State private var showingVersions = false
    @State private var sheet: SheetRequest?
    @State private var removing: ValkeyServer?
    @State private var columns = NavigationSplitViewVisibility.all
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(store.servers, selection: $selection) { server in
                ServerRow(server: server).tag(server.id)
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button { sheet = SheetRequest(config: store.newConfig(), isNew: true) } label: {
                        Image(systemName: "plus")
                    }.help("Add server")
                    Button { removing = store.server(id: selection) } label: {
                        Image(systemName: "minus")
                    }.help("Remove server").disabled(selection == nil)
                    Spacer()
                    Button("Versions…") { showingVersions = true }.help("Install or remove Valkey versions")
                }
                .buttonStyle(.borderless).padding(10)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if let server = store.server(id: selection) {
                ServerDetailView(server: server) {
                    sheet = SheetRequest(config: server.config, isNew: false)
                }
            } else if store.servers.isEmpty {
                VStack(spacing: 12) {
                    Text("No servers yet").font(.title2)
                    Button("Create Server…") { sheet = SheetRequest(config: store.newConfig(), isNew: true) }
                        .controlSize(.large)
                }
            } else {
                Text("Select a server.").foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            selection = selection ?? store.servers.first?.id
            MainWindow.open = { openWindow(id: "main") }
        }
        .sheet(item: $sheet) { request in
            ServerSettingsView(request: request) { config in
                if request.isNew {
                    store.add(config)
                    selection = config.id
                } else {
                    store.server(id: config.id)?.config = config
                }
            }
            .environmentObject(store)
            .environmentObject(versions)
        }
        .sheet(isPresented: $showingVersions) {
            VersionsView().environmentObject(store).environmentObject(versions)
        }
        .alert("Remove “\(removing?.config.name ?? "")”?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), presenting: removing) { server in
            Button("Remove", role: .destructive) {
                store.remove(server)
                selection = store.servers.first?.id
            }
            Button("Cancel", role: .cancel) {}
        } message: { server in
            Text("The server will be stopped. Its data directory is kept at \(server.config.dataDirectory).")
        }
    }
}

private struct StatusIcon: View {
    @ObservedObject var server: ValkeyServer

    var body: some View {
        if server.isStopping {
            Image(systemName: "hourglass.circle.fill").foregroundColor(.orange)
        } else if server.isRunning {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        } else if server.failure != nil {
            Image(systemName: "exclamationmark.circle.fill").foregroundColor(.red)
        } else {
            Image(systemName: "circle").foregroundColor(.secondary)
        }
    }
}

private struct ServerRow: View {
    @ObservedObject var server: ValkeyServer

    var body: some View {
        HStack(spacing: 10) {
            StatusIcon(server: server).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.config.name).font(.headline)
                Text("Port \(String(server.config.port)) – v\(server.config.version)")
                    .font(.subheadline).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct ServerDetailView: View {
    @ObservedObject var server: ValkeyServer
    let openSettings: () -> Void

    private var statusText: String {
        server.isStopping ? "Stopping…" : server.isRunning ? "Running" : "Not running"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(server.config.name).font(.largeTitle)
                    HStack(spacing: 8) {
                        StatusIcon(server: server)
                        Text(statusText).font(.title3)
                    }
                    if let failure = server.failure {
                        Text(failure).font(.callout).foregroundColor(.red)
                    }
                }
                Spacer()
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88)
            }

            HStack {
                Button("Server Settings…", action: openSettings)
                Button("Connect…") { server.openCLI() }
                    .disabled(!server.isRunning || server.isStopping)
                    .help("Open valkey-cli in Terminal")
                Button("Show in Finder") { server.showDataDir() }
                Spacer()
                Button("Stop") { server.stop() }.disabled(!server.isRunning || server.isStopping)
                Button("Start") { server.start() }.disabled(server.isRunning)
            }
            .controlSize(.large)
            .padding(.top, 20)

            Divider().padding(.vertical, 16)

            HStack {
                Text("Log").font(.headline)
                Spacer()
                Button("Open Log File") { NSWorkspace.shared.open(server.logURL) }
                    .buttonStyle(.link)
                    .disabled(!FileManager.default.fileExists(atPath: server.logURL.path))
            }
            .padding(.bottom, 8)
            LogView(text: server.log)
        }
        .padding(24)
    }
}

private struct LogView: View {
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text.isEmpty ? "No log output yet." : text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(text.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)
            .onAppear { proxy.scrollTo("end") }
            .onChange(of: text) { _ in proxy.scrollTo("end") }
        }
    }
}
