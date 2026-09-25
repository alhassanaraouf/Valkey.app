import SwiftUI

/// Create a new server, or edit an existing one (version and data directory are fixed once created).
struct ServerSettingsView: View {
    @EnvironmentObject var store: ServerStore
    @Environment(\.dismiss) private var dismiss
    let isNew: Bool
    let onSave: (ValkeyServer.Config) -> Void
    @State private var config: ValkeyServer.Config
    @State private var portText: String
    @State private var customDataDir: String?

    init(request: SheetRequest, onSave: @escaping (ValkeyServer.Config) -> Void) {
        isNew = request.isNew
        self.onSave = onSave
        _config = State(initialValue: request.config)
        _portText = State(initialValue: String(request.config.port))
    }

    private var result: ValkeyServer.Config {
        var c = config
        c.port = Int(portText) ?? 0
        if isNew { c.dataDirectory = customDataDir ?? store.defaultDataDirectory(port: c.port) }
        return c
    }

    var body: some View {
        let problem = store.problem(with: result)
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New Server" : "Server Settings").font(.headline)
            Form {
                TextField("Name", text: $config.name)
                if isNew {
                    Picker("Version", selection: $config.version) {
                        ForEach(ValkeyServer.availableVersions, id: \.self) { Text("Valkey \($0)").tag($0) }
                    }
                    .onChange(of: config.version) { v in
                        // Keep the default name in step with the chosen version.
                        if ValkeyServer.availableVersions.contains(where: { config.name == "Valkey \($0)" }) {
                            config.name = "Valkey \(v)"
                        }
                    }
                } else {
                    LabeledContent("Version", value: "Valkey \(config.version)")
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
            if let problem {
                Text(problem).font(.callout).foregroundColor(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create Server" : "Save") {
                    onSave(result)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 480)
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
