import SwiftUI

/// Create a new server, or edit an existing one. New servers may pick any known version (it's
/// installed on Create); existing servers can only move to an installed version that isn't older.
/// Modules are offered for the chosen version's minor line and installed on save.
struct ServerSettingsView: View {
    @EnvironmentObject var store: ServerStore
    @EnvironmentObject var versions: VersionStore
    @Environment(\.dismiss) private var dismiss
    let isNew: Bool
    let onSave: (ValkeyServer.Config) -> Void
    private let originalVersion: String
    private let originalModules: [String]
    @State private var config: ValkeyServer.Config
    @State private var portText: String
    @State private var customDataDir: String?
    @State private var installError: String?
    @State private var saving = false
    @State private var addingModule = false

    init(request: SheetRequest, onSave: @escaping (ValkeyServer.Config) -> Void) {
        isNew = request.isNew
        self.onSave = onSave
        originalVersion = request.config.version
        originalModules = request.config.enabledModules
        _config = State(initialValue: request.config)
        _portText = State(initialValue: String(request.config.port))
    }

    private static let evictionPolicies = ["noeviction", "allkeys-lru", "allkeys-lfu", "allkeys-random",
                                          "volatile-lru", "volatile-lfu", "volatile-random", "volatile-ttl"]

    private var memoryProblem: String? {
        guard let m = config.maxMemory,
              m.range(of: #"^\d+([kmg]b?|b)?$"#, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        return "Max Memory must be a size like 256mb or 2gb."
    }

    private var usersProblem: String? {
        var seen: Set<String> = ["default"]
        for user in config.accounts {
            if user.name.isEmpty || user.name.contains(where: { $0.isWhitespace || $0.isNewline }) {
                return "User names can't be empty or contain spaces."
            }
            if !seen.insert(user.name).inserted { return "User “\(user.name)” is listed twice (or is “default”)." }
            if user.password.isEmpty { return "Give user “\(user.name)” a password." }
        }
        return nil
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

    private var isInstalling: Bool { saving || versions.progress[config.version] != nil }

    /// Enabled modules without an installed build for the chosen version, with the build to install.
    private var modulesToInstall: [VersionStore.ModuleEntry] {
        config.enabledModules.compactMap { name in
            versions.installedModule(name, for: config.version) == nil ? versions.availableModule(name, for: config.version) : nil
        }
    }

    /// An enabled module the chosen version can't load.
    private var moduleProblem: String? {
        for name in config.enabledModules where versions.installedModule(name, for: config.version) == nil
            && versions.availableModule(name, for: config.version) == nil {
            let title = versions.knownModules.first { $0.name == name }?.title ?? name
            return "The \(title) module isn't available for Valkey \(VersionStore.line(of: config.version))."
        }
        return nil
    }

    private func label(for version: String) -> String {
        guard !versions.installed.contains(version) else { return "Valkey \(version)" }
        if let entry = versions.available.first(where: { $0.version == version }) {
            return "Valkey \(version) — download \(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))"
        }
        return "Valkey \(version) (not installed)"
    }

    private func title(ofModule name: String) -> String {
        versions.knownModules.first { $0.name == name }?.title ?? name
    }

    /// Status of an enabled module for the chosen version, and whether it's a problem.
    private func moduleStatus(_ name: String) -> (text: String, isProblem: Bool) {
        if let installed = versions.installedModule(name, for: config.version) {
            return ("Installed \(installed.version)", false)
        }
        if let available = versions.availableModule(name, for: config.version) {
            return ("Downloads \(ByteCountFormatter.string(fromByteCount: Int64(available.size), countStyle: .file)) when you save", false)
        }
        return ("Not available for Valkey \(VersionStore.line(of: config.version))", true)
    }

    var body: some View {
        let problem = config.version.isEmpty ? "No versions available yet." : store.problem(with: result) ?? memoryProblem ?? usersProblem ?? moduleProblem
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
                SecureField("Password", text: Binding(
                    get: { config.password ?? "" }, set: { config.password = $0.isEmpty ? nil : $0 }))
                Toggle("Save data to disk", isOn: Binding(
                    get: { config.persistence ?? true }, set: { config.persistence = $0 ? nil : false }))
                TextField("Max Memory", text: Binding(
                    get: { config.maxMemory ?? "" }, set: { config.maxMemory = $0.isEmpty ? nil : $0 }),
                    prompt: Text("No limit, e.g. 256mb"))
                Picker("When Full", selection: Binding(
                    get: { config.evictionPolicy ?? "noeviction" },
                    set: { config.evictionPolicy = $0 == "noeviction" ? nil : $0 })) {
                    ForEach(Self.evictionPolicies, id: \.self) { Text($0).tag($0) }
                }
                .disabled(config.maxMemory == nil)
                LabeledContent("Users") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach($config.accounts) { $user in
                            HStack {
                                TextField("Name", text: $user.name).frame(width: 90)
                                SecureField("Password", text: $user.password)
                                Picker("", selection: $user.readOnly) {
                                    Text("Full access").tag(false)
                                    Text("Read only").tag(true)
                                }
                                .labelsHidden().fixedSize()
                                Button { config.accounts.removeAll { $0.id == user.id } } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Button("Add User") { config.accounts.append(.init()) }
                        Text("The default user is open unless a password is set above.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                // Only the server's own modules are listed; the full catalog is in Add Module….
                LabeledContent("Modules") {
                    VStack(alignment: .leading, spacing: 6) {
                        if config.enabledModules.isEmpty {
                            Text("None").foregroundColor(.secondary)
                        }
                        ForEach(config.enabledModules, id: \.self) { name in
                            let status = moduleStatus(name)
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(title(ofModule: name))
                                    Text(status.text).font(.caption).foregroundColor(status.isProblem ? .red : .secondary)
                                }
                                Spacer()
                                Button { config.enabledModules.removeAll { $0 == name } } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove \(title(ofModule: name)) from this server")
                            }
                        }
                        Button("Add Module…") { addingModule = true }
                    }
                }
            }
            .disabled(isInstalling)

            if !isNew && !Set(originalModules).isSubset(of: config.enabledModules) {
                Text("Data saved while a module was on can stop this server from starting without that module.")
                    .font(.callout).foregroundColor(.secondary)
            }
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
            ForEach(modulesToInstall) { module in
                if let fraction = versions.progress[module.id] {
                    ProgressView("Downloading the \(module.title) module…", value: fraction)
                }
            }
            if let message = installError {
                ErrorMessage(message: message)
            } else if let message = problem {
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
        .sheet(isPresented: $addingModule) {
            ModulePickerView(valkeyVersion: config.version, enabled: config.enabledModules) { name in
                config.enabledModules = (config.enabledModules + [name]).sorted()
            }
            .environmentObject(versions)
        }
        .task {
            if versions.allVersions.isEmpty { await versions.refresh() }
            if config.version.isEmpty, let newest = versions.allVersions.first {
                config.version = newest
                config.name = "Valkey \(newest)"
            }
        }
    }

    /// Installs the chosen version and any modules it needs, then saves.
    private func save() {
        let result = result
        saving = true
        installError = nil
        Task {
            defer { saving = false }
            do {
                if !versions.installed.contains(result.version),
                   let entry = versions.available.first(where: { $0.version == result.version }) {
                    try await versions.install(entry)
                }
                for module in modulesToInstall { try await versions.install(module) }
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
