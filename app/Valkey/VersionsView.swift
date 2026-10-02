import SwiftUI

/// Lists installed Valkey versions and modules, and those offered by the registry, with Install / Remove.
struct VersionsView: View {
    @EnvironmentObject var versions: VersionStore
    @EnvironmentObject var store: ServerStore
    @Environment(\.dismiss) private var dismiss
    @State private var installError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Valkey Versions").font(.headline)
                Spacer()
                if versions.isRefreshing { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await versions.refresh() } }.disabled(versions.isRefreshing)
            }

            List {
                Section("Valkey") {
                    ForEach(versions.allVersions, id: \.self) { row(for: $0) }
                }
                if !moduleBuilds.isEmpty {
                    Section("Modules") {
                        ForEach(moduleBuilds) { moduleRow(for: $0) }
                    }
                }
            }
            .frame(minHeight: 340)
            .overlay {
                if versions.allVersions.isEmpty && !versions.isRefreshing {
                    Text("No versions available.").foregroundColor(.secondary)
                }
            }

            if let message = installError ?? versions.registryError {
                ErrorMessage(message: message)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { await versions.refresh() }
    }

    /// Every module build, installed or offered, by title then newest first.
    private var moduleBuilds: [VersionStore.ModuleEntry] {
        var seen = Set<String>()
        return (versions.installedModules + versions.availableModules)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.title != $1.title ? $0.title < $1.title : VersionStore.isNewer($0.version, than: $1.version) }
    }

    private func moduleRow(for module: VersionStore.ModuleEntry) -> some View {
        let isInstalled = versions.installedModules.contains { $0.id == module.id }
        // A build is in use when a server with the module on would load exactly this build.
        let users = store.servers.filter {
            $0.config.enabledModules.contains(module.name)
                && versions.installedModule(module.name, for: $0.config.version)?.id == module.id
        }.map(\.config.name)
        let lines = module.valkey.count > 1 ? "\(module.valkey.first!)–\(module.valkey.last!)" : module.valkey.first ?? ""
        var details = ["for Valkey \(lines)"]
        if isInstalled { details.append("Installed") }
        if !users.isEmpty { details.append("used by " + users.joined(separator: ", ")) }
        if !isInstalled { details.append(ByteCountFormatter.string(fromByteCount: Int64(module.size), countStyle: .file)) }

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(module.title) \(module.version)")
                Text(details.joined(separator: " · ")).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if let fraction = versions.progress[module.id] {
                ProgressView(value: fraction).frame(width: 100)
            } else if isInstalled {
                Button("Remove") { versions.remove(module) }
                    .disabled(!users.isEmpty)
                    .help(users.isEmpty ? "Delete this module build" : "In use by a server")
            } else {
                Button("Install") {
                    Task {
                        do {
                            installError = nil
                            try await versions.install(module)
                        } catch {
                            installError = error.localizedDescription
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func row(for version: String) -> some View {
        let entry = versions.available.first { $0.version == version }
        let users = store.servers.filter { $0.config.version == version }.map(\.config.name)
        let isInstalled = versions.installed.contains(version)
        var details: [String] = []
        if isInstalled { details.append("Installed") }
        if !users.isEmpty { details.append("used by " + users.joined(separator: ", ")) }
        if let entry, !isInstalled {
            details.append("released \(entry.published)")
            details.append(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
        }

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Valkey \(version)")
                Text(details.joined(separator: " · ")).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if let fraction = versions.progress[version] {
                ProgressView(value: fraction).frame(width: 100)
            } else if isInstalled {
                Button("Remove") { versions.remove(version) }
                    .disabled(!users.isEmpty)
                    .help(users.isEmpty ? "Delete this version" : "In use by a server")
            } else if let entry {
                Button("Install") {
                    Task {
                        do {
                            installError = nil
                            try await versions.install(entry)
                        } catch {
                            installError = error.localizedDescription
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
