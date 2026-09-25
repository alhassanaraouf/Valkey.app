import Foundation

/// The list of servers, persisted in UserDefaults.
final class ServerStore: ObservableObject {
    static let shared = ServerStore()

    @Published private(set) var servers: [ValkeyServer] = []
    private let defaultsKey = "servers"

    private init() {
        let saved = UserDefaults.standard.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode([ValkeyServer.Config].self, from: $0) }
        servers = (saved ?? [newConfig()]).map(makeServer)
        if saved == nil { save() }
    }

    private func makeServer(_ config: ValkeyServer.Config) -> ValkeyServer {
        let server = ValkeyServer(config: config)
        server.onConfigChange = { [weak self] in self?.save() }
        return server
    }

    private func save() {
        let data = try? JSONEncoder().encode(servers.map(\.config))
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    func server(id: UUID?) -> ValkeyServer? {
        servers.first { $0.id == id }
    }

    /// A new config on the newest bundled version and the first free port from 6379.
    func newConfig() -> ValkeyServer.Config {
        let version = ValkeyServer.availableVersions.first ?? ""
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

    /// Why `config` can't be saved, or nil if it can.
    func problem(with config: ValkeyServer.Config) -> String? {
        let others = servers.map(\.config).filter { $0.id != config.id }
        if config.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a name." }
        guard (1...65535).contains(config.port) else { return "Port must be between 1 and 65535." }
        if let other = others.first(where: { $0.port == config.port }) {
            return "Port \(config.port) is already used by “\(other.name)”."
        }
        if let other = others.first(where: { $0.dataDirectory == config.dataDirectory }) {
            return "That data directory is already used by “\(other.name)”."
        }
        return nil
    }

    func add(_ config: ValkeyServer.Config) {
        servers.append(makeServer(config))
        save()
    }

    /// Stops the server and forgets it; its data directory is left on disk.
    func remove(_ server: ValkeyServer) {
        server.stop()
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
