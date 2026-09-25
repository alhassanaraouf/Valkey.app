import CryptoKit
import Foundation

/// Valkey builds: those installed in Application Support, and those offered by the signed registry.
///
/// The registry (registry.json + registry.json.sig) must carry a valid Ed25519 signature from
/// `releaseKey`'s private half, and each download must match the size and SHA-256 listed in it.
@MainActor
final class VersionStore: ObservableObject {
    /// One installable build. Keep in sync with registry/scripts/registry.swift.
    struct Entry: Codable, Identifiable {
        let version: String
        let url: String
        let sha256: String
        let size: Int
        let minimumMacOS: String
        let published: String
        var id: String { version }
    }

    private struct Registry: Codable {
        let schemaVersion: Int
        let versions: [Entry]
    }

    struct InstallError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Public half of the registry signing key; CI signs registry/registry.json with the private half.
    nonisolated static let releaseKey = "YbChZ7UV/onvaqksSqWct/VymACmimHwEoeo/yx5Tag="
    /// Override with `defaults write app.valkey.Valkey registryURL <url>` to test or self-host.
    nonisolated static let defaultRegistryURL = URL(string: UserDefaults.standard.string(forKey: "registryURL")
                                        ?? "https://valkey.app/registry.json")!

    static let shared = VersionStore()

    @Published private(set) var installed: [String] = []
    @Published private(set) var available: [Entry] = []
    @Published private(set) var registryError: String?
    @Published private(set) var isRefreshing = false
    /// Download progress (0...1) of in-flight installs, by version.
    @Published private(set) var progress: [String: Double] = [:]

    let installDir: URL
    private let registryURL: URL
    private let publicKey: String

    init(registryURL: URL = defaultRegistryURL, publicKey: String = releaseKey,
         installDir: URL = ValkeyServer.rootDir.appendingPathComponent("Versions", isDirectory: true)) {
        self.registryURL = registryURL
        self.publicKey = publicKey
        self.installDir = installDir
        scanInstalled()
    }

    /// Installed and installable versions, newest first.
    var allVersions: [String] {
        Set(installed).union(available.map(\.version)).sorted(by: Self.isNewer)
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    /// Versions become path components, so only accept plain dotted numbers.
    nonisolated static func isValid(_ version: String) -> Bool {
        version.range(of: #"^[0-9]+(\.[0-9]+){1,3}$"#, options: .regularExpression) != nil
    }

    func binary(_ name: String, version: String) -> URL {
        installDir.appendingPathComponent("\(version)/bin/\(name)")
    }

    private func scanInstalled() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: installDir.path)) ?? []
        installed = names
            .filter { Self.isValid($0) && FileManager.default.isExecutableFile(atPath: binary("valkey-server", version: $0).path) }
            .sorted(by: Self.isNewer)
    }

    // MARK: Registry

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            available = try await fetchRegistry()
            registryError = nil
        } catch {
            available = []
            registryError = "Couldn't load available versions: \(error.localizedDescription)"
        }
    }

    private func fetchRegistry() async throws -> [Entry] {
        let data = try await fetch(registryURL)
        let signature = try await fetch(registryURL.appendingPathExtension("sig"))
        guard let sig = Data(base64Encoded: String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              let rawKey = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey),
              key.isValidSignature(sig, for: data) else {
            throw InstallError("the version list's signature is invalid, so it was ignored.")
        }
        let registry = try JSONDecoder().decode(Registry.self, from: data)
        guard registry.schemaVersion == 1 else { throw InstallError("this version list needs a newer Valkey.app.") }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return registry.versions.filter {
            Self.isValid($0.version) && !Self.isNewer($0.minimumMacOS, than: macOS) && URL(string: $0.url) != nil
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw InstallError("\(url.lastPathComponent) returned HTTP \(http.statusCode).")
        }
        return data
    }

    // MARK: Install / remove

    func install(_ entry: Entry) async throws {
        guard let url = URL(string: entry.url) else { throw InstallError("Valkey \(entry.version) has an invalid download URL.") }
        guard progress[entry.version] == nil else { throw InstallError("Valkey \(entry.version) is already being installed.") }
        progress[entry.version] = 0
        defer { progress[entry.version] = nil }
        let file = try await download(url, version: entry.version)
        defer { try? FileManager.default.removeItem(at: file) }
        let installDir = installDir
        try await Task.detached { try Self.verifyAndExtract(file, entry, into: installDir) }.value
        scanInstalled()
    }

    private func download(_ url: URL, version: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            var observation: NSKeyValueObservation?
            let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
                observation?.invalidate()
                if let error { return continuation.resume(throwing: error) }
                guard let tmp, (response as? HTTPURLResponse)?.statusCode ?? 200 == 200 else {
                    return continuation.resume(throwing: InstallError("Download of Valkey \(version) failed."))
                }
                // The temporary file is deleted when this handler returns, so move it first.
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("valkey-\(UUID().uuidString).tar.gz")
                do {
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    continuation.resume(returning: dest)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
                let fraction = p.fractionCompleted
                Task { @MainActor in
                    if self?.progress[version] != nil { self?.progress[version] = fraction }
                }
            }
            task.resume()
        }
    }

    nonisolated private static func verifyAndExtract(_ file: URL, _ entry: Entry, into installDir: URL) throws {
        let data = try Data(contentsOf: file)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == entry.size, hash == entry.sha256.lowercased() else {
            throw InstallError("The download of Valkey \(entry.version) didn't match its published checksum, so it was discarded.")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: installDir, withIntermediateDirectories: true)
        let staging = installDir.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", file.path, "-C", staging.path]
        try tar.run()
        tar.waitUntilExit()
        let bins = ["valkey-server", "valkey-cli"].map { staging.appendingPathComponent("bin/\($0)").path }
        guard tar.terminationStatus == 0, bins.allSatisfy(fm.isExecutableFile(atPath:)) else {
            throw InstallError("The download of Valkey \(entry.version) doesn't contain valkey-server and valkey-cli.")
        }

        let dest = installDir.appendingPathComponent(entry.version, isDirectory: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: staging, to: dest)
    }

    /// Deletes an installed version. Callers make sure no server uses it.
    func remove(_ version: String) {
        guard Self.isValid(version) else { return }
        try? FileManager.default.removeItem(at: installDir.appendingPathComponent(version, isDirectory: true))
        scanInstalled()
    }
}
