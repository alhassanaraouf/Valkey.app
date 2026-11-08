// Compile the real ServerStore against small process/download doubles. No app, Keychain or network.
import Foundation

@MainActor
final class ValkeyServer {
    struct Config: Codable, Equatable {
        var id = UUID()
        var name: String
        var version: String
        var port: Int
        var dataDirectory: String
        var maxMemory: String?
        var evictionPolicy: String?
        struct User: Codable, Equatable { var name: String; var password: String }
        var accounts: [User] = []
        var enabledModules: [String] = []
        mutating func loadSecrets() {}
        func saveSecrets() {}
        func deleteSecrets() {}
    }
    static let rootDir = URL(fileURLWithPath: "/unused")
    var config: Config { didSet { onConfigChange?() } }
    var onConfigChange: (() -> Void)?
    var id: UUID { config.id }
    var isRunning = false
    init(config: Config) { self.config = config }
    func stop(then: (() -> Void)? = nil) { then?() }
}

@MainActor
final class VersionStore {
    struct Entry { var version: String }
    struct ModuleEntry { var name: String; var title: String }
    static let shared = VersionStore()
    var installed = ["1.0"]
    var available = [Entry(version: "1.0"), Entry(version: "2.0")]
    var allVersions: [String] { available.map(\.version) }
    var knownModules: [ModuleEntry] { [] }
    var onInstall: (() async -> Void)?
    func installedModule(_ name: String, for version: String) -> ModuleEntry? { nil }
    func availableModule(_ name: String, for version: String) -> ModuleEntry? { nil }
    static func isNewer(_ a: String, than b: String) -> Bool { a > b }
    static func line(of version: String) -> String { version }
    func install(_ entry: Entry) async throws { await onInstall?() }
    func install(_ entry: ModuleEntry) async throws {}
}

enum CLI {
    struct Failure: Error { var message: String }
}

@main
struct StoreCommitTests {
    @MainActor static func main() async throws {
        // Isolate the store's UserDefaults from real saved settings on the CI machine.
        let suite = "StoreCommitTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ServerStore(defaults: defaults)
        let versions = VersionStore.shared
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print(condition ? "ok   \(name)" : "FAIL \(name)")
            if !condition { failures += 1 }
        }
        func rejected(_ config: ValkeyServer.Config, original: ValkeyServer.Config?) async -> Bool {
            do { try await store.commit(config, original: original); return false }
            catch { return true }
        }
        func config(_ port: Int, version: String = "1.0") -> ValkeyServer.Config {
            .init(name: "cache", version: version, port: port, dataDirectory: "/unused/\(port)")
        }
        let original = config(6379)
        let server = try await store.commit(original, original: nil)
        var edited = original
        edited.name = "renamed"
        try await store.commit(edited, original: original)
        var stale = original
        stale.maxMemory = "256mb"
        check("stale snapshot rejected before downloads", await rejected(stale, original: original))
        check("newer settings preserved", server.config == edited)

        // Pause an actual store commit inside installRequirements, then commit a competing edit.
        var pending = config(6380, version: "2.0")
        store.add(pending)
        let baseline = pending
        pending.enabledModules = []
        pending.name = "downloaded edit"
        var entered: CheckedContinuation<Void, Never>?
        var resume: CheckedContinuation<Void, Never>?
        versions.onInstall = {
            entered?.resume()
            await withCheckedContinuation { resume = $0 }
        }
        let task = Task { @MainActor in await rejected(pending, original: baseline) }
        await withCheckedContinuation { entered = $0 }
        var newer = baseline
        newer.name = "newer edit"
        store.server(id: baseline.id)!.config = newer
        resume?.resume()
        check("edit during download rejected", await task.value)
        check("download cannot overwrite newer edit", store.server(id: baseline.id)?.config == newer)

        // Deletion during a download must not mutate a detached server or re-add it.
        versions.onInstall = { store.remove(store.server(id: baseline.id)!) }
        check("deletion during download rejected", await rejected(pending, original: newer))
        check("deleted server stays deleted", store.server(id: baseline.id) == nil)

        // A create that was valid before awaiting must recheck shared port/directory ownership.
        let collision = config(6390, version: "2.0")
        versions.onInstall = { store.add(config(6390)) }
        check("port claimed during download rejected", await rejected(collision, original: nil))
        check("only one server owns port", store.servers.filter { $0.config.port == 6390 }.count == 1)
        let directoryCollision = config(6391, version: "2.0")
        versions.onInstall = {
            var other = config(6392)
            other.dataDirectory = directoryCollision.dataDirectory
            store.add(other)
        }
        check("directory claimed during download rejected", await rejected(directoryCollision, original: nil))
        check("directory collision not saved", store.server(id: directoryCollision.id) == nil)
        print(failures == 0 ? "all store commit tests passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
