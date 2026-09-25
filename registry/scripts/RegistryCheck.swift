// Driven by registry/scripts/check-registry.sh: exercises app/Valkey/VersionStore.swift against a local registry.
// Usage: RegistryCheck <registry-url> <public-key> <install-dir> <site-dir>
import Foundation

/// Stand-in for the app's ValkeyServer, which VersionStore only needs for its default install dir.
enum ValkeyServer {
    static let rootDir = FileManager.default.temporaryDirectory
}

@main
struct RegistryCheck {
    @MainActor
    static func main() async throws {
        let a = CommandLine.arguments
        let site = URL(fileURLWithPath: a[4])
        let registryFile = site.appendingPathComponent("registry.json")
        let tarball = site.appendingPathComponent("valkey-9.9.9.tar.gz")
        let store = VersionStore(registryURL: URL(string: a[1])!, publicKey: a[2], installDir: URL(fileURLWithPath: a[3]))

        // 1. A correctly signed registry lists the version, and installing it works.
        await store.refresh()
        precondition(store.registryError == nil, "valid registry rejected: \(store.registryError ?? "")")
        precondition(store.available.map(\.version) == ["9.9.9"], "unexpected versions \(store.available.map(\.version))")
        try await store.install(store.available[0])
        precondition(store.installed == ["9.9.9"], "install failed")
        precondition(FileManager.default.isExecutableFile(atPath: store.binary("valkey-server", version: "9.9.9").path))
        print("ok: signed registry verified, version installed")

        // 2. A registry modified after signing is refused.
        let original = try Data(contentsOf: registryFile)
        try (original + Data(" ".utf8)).write(to: registryFile)
        await store.refresh()
        precondition(store.registryError != nil && store.available.isEmpty, "tampered registry accepted")
        try original.write(to: registryFile)
        print("ok: tampered registry rejected")

        // 3. A download that doesn't match the registry's checksum is discarded and nothing is installed.
        await store.refresh()
        store.remove("9.9.9")
        var bytes = try Data(contentsOf: tarball)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: tarball)
        do {
            try await store.install(store.available[0])
            preconditionFailure("corrupted download installed")
        } catch {
            precondition(store.installed.isEmpty, "corrupted download left files behind")
        }
        print("ok: corrupted download rejected")
    }
}
