import SwiftUI

/// Lists installed versions and those offered by the registry, with Install / Remove.
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

            List(versions.allVersions, id: \.self) { row(for: $0) }
                .frame(minHeight: 260)
                .overlay {
                    if versions.allVersions.isEmpty && !versions.isRefreshing {
                        Text("No versions available.").foregroundColor(.secondary)
                    }
                }

            if let message = installError ?? versions.registryError {
                Text(message).font(.callout).foregroundColor(.red)
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
