import SwiftUI

/// Create a new server, or edit an existing one. New servers may pick any known version (it's
/// installed on Create); existing servers can only move to an installed version that isn't older.
struct ServerSettingsView: View {
    @EnvironmentObject var store: ServerStore
    @EnvironmentObject var versions: VersionStore
    @Environment(\.dismiss) private var dismiss
    let isNew: Bool
    let onSave: (ValkeyServer.Config) -> Void
    private let originalVersion: String
    @State private var config: ValkeyServer.Config
    @State private var portText: String
    @State private var customDataDir: String?
    @State private var installError: String?

    init(request: SheetRequest, onSave: @escaping (ValkeyServer.Config) -> Void) {
        isNew = request.isNew
        self.onSave = onSave
        originalVersion = request.config.version
        _config = State(initialValue: request.config)
        _portText = State(initialValue: String(request.config.port))
    }

    private var result: ValkeyServer.Config {
        var c = config
        c.port = Int(portText) ?? 0
        if isNew { c.dataDirectory = customDataDir ?? store.defaultDataDirectory(port: c.port) }
        return c
    }

    private var versionChoices: [String] {
        if isNew { return versions.allVersions }
        let upgrades = versions.installed.filter { !VersionStore.isNewer(originalVersion, than: $0) }
        return upgrades.contains(originalVersion) ? upgrades : upgrades + [originalVersion]
    }

    private var isInstalling: Bool { versions.progress[config.version] != nil }

    private func label(for version: String) -> String {
        guard !versions.installed.contains(version) else { return "Valkey \(version)" }
        if let entry = versions.available.first(where: { $0.version == version }) {
            return "Valkey \(version) — download \(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))"
        }
        return "Valkey \(version) (not installed)"
    }

    var body: some View {
        let problem = config.version.isEmpty ? "No versions available yet." : store.problem(with: result)
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New Server" : "Server Settings").font(.headline)
            Form {
                TextField("Name", text: $config.name)
                Picker("Version", selection: $config.version) {
                    ForEach(versionChoices, id: \.self) { Text(label(for: $0)).tag($0) }
                }
                .onChange(of: config.version) { v in
                    // Keep the default name in step with the chosen version.
                    if isNew && versions.allVersions.contains(where: { config.name == "Valkey \($0)" }) {
                        config.name = "Valkey \(v)"
                    }
                }
                TextField("Port", text: $portText)
                LabeledContent("Data Directory") {
                    HStack {
                        Text(result.dataDirectory).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        if isNew { Button("Choose…", action: chooseDataDir) }
                    }
                }
                Toggle("Start automatically when Valkey.app opens", isOn: $config.startAutomatically)
            }
            .disabled(isInstalling)

            if !isNew && config.version != originalVersion {
                Text("Upgrading to Valkey \(config.version) can't be undone: older versions may not read its data files.")
                    .font(.callout).foregroundColor(.secondary)
            }
            if isNew && versions.allVersions.isEmpty {
                HStack {
                    Text(versions.registryError ?? "Loading available versions…").font(.callout).foregroundColor(.secondary)
                    Button("Retry") { Task { await versions.refresh() } }.disabled(versions.isRefreshing)
                }
            }
            if let fraction = versions.progress[config.version] {
                ProgressView("Downloading Valkey \(config.version)…", value: fraction)
            }
            if let message = installError ?? problem {
                Text(message).font(.callout).foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create Server" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || isInstalling)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            if versions.allVersions.isEmpty { await versions.refresh() }
            if config.version.isEmpty, let newest = versions.allVersions.first {
                config.version = newest
                config.name = "Valkey \(newest)"
            }
        }
    }

    /// Installs the chosen version first if needed, then saves.
    private func save() {
        let result = result
        Task {
            do {
                if !versions.installed.contains(result.version),
                   let entry = versions.available.first(where: { $0.version == result.version }) {
                    installError = nil
                    try await versions.install(entry)
                }
                onSave(result)
                dismiss()
            } catch {
                installError = error.localizedDescription
            }
        }
    }

    private func chooseDataDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { customDataDir = url.path }
    }
}
