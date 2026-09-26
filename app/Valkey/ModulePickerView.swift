import SwiftUI

/// Searchable catalog of registry modules to add to a server; scales to any number of modules.
/// Modules without a build for the server's Valkey line are listed but can't be added.
struct ModulePickerView: View {
    @EnvironmentObject var versions: VersionStore
    @Environment(\.dismiss) private var dismiss
    let valkeyVersion: String
    let enabled: [String]
    let onAdd: (String) -> Void
    @State private var query = ""

    private func isAvailable(_ module: VersionStore.ModuleEntry) -> Bool {
        versions.installedModule(module.name, for: valkeyVersion) != nil
            || versions.availableModule(module.name, for: valkeyVersion) != nil
    }

    /// Matching modules not yet on the server; ones this Valkey version can't load sort last.
    private var results: [VersionStore.ModuleEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return versions.knownModules
            .filter { !enabled.contains($0.name) }
            .filter { q.isEmpty || [$0.title, $0.name, $0.summary].contains { $0.localizedCaseInsensitiveContains(q) } }
            .sorted { isAvailable($0) != isAvailable($1) ? isAvailable($0) : $0.title < $1.title }
    }

    private func status(_ module: VersionStore.ModuleEntry) -> String {
        if let installed = versions.installedModule(module.name, for: valkeyVersion) {
            return "Installed \(installed.version)"
        }
        if let available = versions.availableModule(module.name, for: valkeyVersion) {
            return "\(available.version) · \(ByteCountFormatter.string(fromByteCount: Int64(available.size), countStyle: .file)) download"
        }
        return "Not available for Valkey \(VersionStore.line(of: valkeyVersion))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Module").font(.headline)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search modules", text: $query).textFieldStyle(.plain)
            }
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)

            List(results) { module in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(module.title).fontWeight(.medium)
                        Text(module.summary).font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(status(module)).font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Add") { onAdd(module.name) }.disabled(!isAvailable(module))
                }
                .padding(.vertical, 4)
                .opacity(isAvailable(module) ? 1 : 0.6)
            }
            .frame(minHeight: 260)
            .overlay {
                if results.isEmpty {
                    Text(versions.knownModules.isEmpty
                         ? (versions.registryError ?? "No modules available yet.")
                         : query.isEmpty ? "Every available module is already added." : "No modules match “\(query)”.")
                        .foregroundColor(.secondary).multilineTextAlignment(.center).padding()
                }
            }

            HStack {
                Text("Modules download when you save the server.").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 440)
    }
}
