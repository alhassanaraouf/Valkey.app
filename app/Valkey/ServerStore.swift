import Combine
import Foundation

/// The list of servers, persisted in UserDefaults.
@MainActor
final class ServerStore: ObservableObject {
    static let shared = ServerStore()

    @Published private(set) var servers: [ValkeyServer] = []
    private let defaultsKey = "servers"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: defaultsKey) {
            do {
                servers = try JSONDecoder().decode([ValkeyServer.Config].self, from: data).map {
                    var config = $0
                    config.loadSecrets()
                    return makeServer(config)
                }
            } catch {
                // Don't let the next save() overwrite what we couldn't read.
                NSLog("Valkey: couldn't read saved servers (\(error)); keeping a copy under \(defaultsKey).corrupt")
                defaults.set(data, forKey: "\(defaultsKey).corrupt")
            }
        }
    }

    private func makeServer(_ config: ValkeyServer.Config) -> ValkeyServer {
        let server = ValkeyServer(config: config)
        server.onConfigChange = { [weak self] in self?.save() }
        return server
    }

    private func save() {
        // set(nil) would delete the saved list, so keep the old one if encoding fails.
        guard let data = try? JSONEncoder().encode(servers.map(\.config)) else {
            return NSLog("Valkey: couldn't encode servers; not saving")
        }
        servers.forEach { $0.config.saveSecrets() }
        defaults.set(data, forKey: defaultsKey)
    }

    func server(id: UUID?) -> ValkeyServer? {
        servers.first { $0.id == id }
    }

    /// A new config on the newest known version and the first free port from 6379.
    func newConfig() -> ValkeyServer.Config {
        let version = VersionStore.shared.allVersions.first ?? ""
        let usedPorts = Set(servers.map(\.config.port))
        let port = (6379...65535).first { !usedPorts.contains($0) } ?? 6379
        return .init(name: "Valkey \(version)", version: version, port: port,
                     dataDirectory: defaultDataDirectory(port: port))
    }

    func defaultDataDirectory(port: Int) -> String {
        let used = Set(servers.map(\.config.dataDirectory))
        var n = 1
        var path: String
        repeat {
            path = ValkeyServer.rootDir.appendingPathComponent(n == 1 ? "var-\(port)" : "var-\(port)-\(n)").path
            n += 1
        } while used.contains(path)
        return path
    }

    /// Why `config` can't be saved, or nil if it can. Server Settings and the CLI both check this.
    func problem(with config: ValkeyServer.Config) -> String? {
        let versions = VersionStore.shared
        let others = servers.map(\.config).filter { $0.id != config.id }
        if config.version.isEmpty { return "No versions available yet." }
        if let original = server(id: config.id)?.config.version, original != config.version {
            // An existing server only moves to an installed version that isn't older.
            guard versions.installed.contains(config.version) else { return "Valkey \(config.version) isn't installed." }
            if VersionStore.isNewer(original, than: config.version) {
                return "Valkey \(config.version) is older than \(original); older versions may not read its data files."
            }
        } else if !versions.allVersions.contains(config.version) {
            return "Valkey \(config.version) isn't installed or available."
        }
        if config.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a name." }
        guard (1...65535).contains(config.port) else { return "Port must be between 1 and 65535." }
        if let other = others.first(where: { $0.port == config.port }) {
            return "Port \(config.port) is already used by “\(other.name)”."
        }
        if let other = others.first(where: { $0.dataDirectory == config.dataDirectory }) {
            return "That data directory is already used by “\(other.name)”."
        }
        if let problem = ConfigRules.maxMemoryProblem(config.maxMemory) { return problem }
        if let policy = config.evictionPolicy, !ConfigRules.evictionPolicies.contains(policy) {
            return "When Full must be one of: \(ConfigRules.evictionPolicies.joined(separator: ", "))."
        }
        if let problem = ConfigRules.usersProblem(config.accounts.map { ($0.name, $0.password) }) { return problem }
        for name in config.enabledModules where versions.installedModule(name, for: config.version) == nil
            && versions.availableModule(name, for: config.version) == nil {
            let title = versions.knownModules.first { $0.name == name }?.title ?? name
            return "The \(title) module isn't available for Valkey \(VersionStore.line(of: config.version))."
        }
        return nil
    }

    /// Enabled modules without an installed build for the config's version, with the build to install.
    func modulesToInstall(for config: ValkeyServer.Config) -> [VersionStore.ModuleEntry] {
        let versions = VersionStore.shared
        return config.enabledModules.compactMap { name in
            versions.installedModule(name, for: config.version) == nil ? versions.availableModule(name, for: config.version) : nil
        }
    }

    /// Downloads the config's version and modules if they aren't installed yet; run before saving it.
    func installRequirements(for config: ValkeyServer.Config) async throws {
        let versions = VersionStore.shared
        if !versions.installed.contains(config.version),
           let entry = versions.available.first(where: { $0.version == config.version }) {
            try await versions.install(entry)
        }
        for module in modulesToInstall(for: config) { try await versions.install(module) }
    }

    /// Validate both sides of downloads, then save without suspending again. An edit's snapshot
    /// also protects against concurrent UI/CLI edits and deletion while the registry loads.
    @discardableResult
    func commit(_ config: ValkeyServer.Config, original: ValkeyServer.Config?) async throws -> ValkeyServer {
        func validate() throws {
            if let original, let problem = ConfigRules.editProblem(original: original, current: server(id: original.id)?.config) {
                throw CLI.Failure(message: problem)
            }
            if let problem = problem(with: config) { throw CLI.Failure(message: problem) }
        }
        try validate()
        try await installRequirements(for: config)
        try validate()
        if let original, let server = server(id: original.id) {
            server.config = config
            return server
        }
        add(config)
        return server(id: config.id)!
    }

    func add(_ config: ValkeyServer.Config) {
        servers.append(makeServer(config))
        save()
    }

    /// Stops the server and forgets it; its data directory is left on disk.
    func remove(_ server: ValkeyServer) {
        server.stop()
        server.config.deleteSecrets()
        servers.removeAll { $0.id == server.id }
        save()
    }

    func stopAll(then: @escaping () -> Void) {
        let group = DispatchGroup()
        for server in servers where server.isRunning {
            group.enter()
            server.stop { group.leave() }
        }
        group.notify(queue: .main, execute: then)
    }
}
