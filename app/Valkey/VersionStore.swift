import CryptoKit
import Foundation

/// Valkey builds and modules: those installed in Application Support, and those offered by the signed
/// registry.
///
/// The registry (registry.json + registry.json.sig) must carry a valid Ed25519 signature from
/// `releaseKey`'s private half, and each download must match the size and SHA-256 listed in it.
/// A module build is only offered for the Valkey minor lines it was tested with at publish time.
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

    /// One installable module build. Keep in sync with registry/scripts/registry.swift.
    struct ModuleEntry: Codable, Identifiable, Equatable {
        let id: String
        let name: String
        let version: String
        let title: String
        let summary: String
        let file: String
        /// Valkey minor lines ("9.1") this build was tested with.
        let valkey: [String]
        let architectures: [String]
        let url: String
        let sha256: String
        let size: Int
        let minimumMacOS: String
        let published: String
        let sourceCommit: String?
    }

    private struct Registry: Codable {
        let schemaVersion: Int
        let versions: [Entry]
        let modules: [ModuleEntry]?
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
    @Published private(set) var installedModules: [ModuleEntry] = []
    @Published private(set) var availableModules: [ModuleEntry] = []
    @Published private(set) var registryError: String?
    @Published private(set) var isRefreshing = false
    /// Download progress (0...1) of in-flight installs, by Valkey version or module id.
    @Published private(set) var progress: [String: Double] = [:]

    let installDir: URL
    let modulesDir: URL
    private let registryURL: URL
    private let publicKey: String

    init(registryURL: URL = defaultRegistryURL, publicKey: String = releaseKey,
         installDir: URL = ValkeyServer.rootDir.appendingPathComponent("Versions", isDirectory: true)) {
        self.registryURL = registryURL
        self.publicKey = publicKey
        self.installDir = installDir
        modulesDir = installDir.deletingLastPathComponent().appendingPathComponent("Modules", isDirectory: true)
        scanInstalled()
        scanInstalledModules()
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

    /// Module ids and file names also become paths, so only accept plain names.
    nonisolated static func isValid(_ module: ModuleEntry) -> Bool {
        func matches(_ value: String, _ pattern: String) -> Bool {
            value.range(of: pattern, options: .regularExpression) != nil
        }
        return matches(module.id, #"^[a-z0-9][a-z0-9.+-]*$"#) && matches(module.name, #"^[a-z][a-z0-9-]*$"#)
            && matches(module.file, #"^[A-Za-z0-9_.-]+\.(dylib|so)$"#) && isValid(module.version)
    }

    /// "9.1.2" → "9.1", the line module compatibility is declared for.
    nonisolated static func line(of version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }

    nonisolated static let architecture: String = {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }()

    private nonisolated static var macOSVersion: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
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

    // MARK: Modules

    func modulePath(_ module: ModuleEntry) -> URL {
        modulesDir.appendingPathComponent("\(module.id)/\(module.file)")
    }

    /// Each installed module keeps its registry entry in module.json, so compatibility is known offline.
    private func scanInstalledModules() {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: modulesDir.path)) ?? []
        installedModules = ids.compactMap { id in
            let manifest = modulesDir.appendingPathComponent("\(id)/module.json")
            guard let data = try? Data(contentsOf: manifest),
                  let module = try? JSONDecoder().decode(ModuleEntry.self, from: data),
                  module.id == id, Self.isValid(module),
                  FileManager.default.fileExists(atPath: modulePath(module).path) else { return nil }
            return module
        }
    }

    /// Newest build of a module in `entries` that supports this Valkey version's minor line.
    private func newest(_ name: String, for valkeyVersion: String, in entries: [ModuleEntry]) -> ModuleEntry? {
        entries.filter { $0.name == name && $0.valkey.contains(Self.line(of: valkeyVersion)) }
            .max { Self.isNewer($1.version, than: $0.version) }
    }

    /// The installed build a server on `valkeyVersion` loads for module `name`.
    func installedModule(_ name: String, for valkeyVersion: String) -> ModuleEntry? {
        newest(name, for: valkeyVersion, in: installedModules)
    }

    /// The registry build that would be installed for module `name` on `valkeyVersion`.
    func availableModule(_ name: String, for valkeyVersion: String) -> ModuleEntry? {
        newest(name, for: valkeyVersion, in: availableModules)
    }

    /// One entry per module name (newest), installed or offered, sorted by title.
    var knownModules: [ModuleEntry] {
        let all = installedModules + availableModules
        return Dictionary(grouping: all, by: \.name).values
            .compactMap { $0.max { Self.isNewer($1.version, than: $0.version) } }
            .sorted { $0.title < $1.title }
    }

    // MARK: Registry

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            (available, availableModules) = try await fetchRegistry()
            registryError = nil
        } catch {
            available = []
            availableModules = []
            registryError = "Couldn't load available versions: \(error.localizedDescription)"
        }
    }

    private func fetchRegistry() async throws -> ([Entry], [ModuleEntry]) {
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
        let macOS = Self.macOSVersion
        let versions = registry.versions.filter {
            Self.isValid($0.version) && !Self.isNewer($0.minimumMacOS, than: macOS) && URL(string: $0.url) != nil
        }
        let modules = (registry.modules ?? []).filter {
            Self.isValid($0) && $0.architectures.contains(Self.architecture)
                && !Self.isNewer($0.minimumMacOS, than: macOS) && URL(string: $0.url) != nil
        }
        return (versions, modules)
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
        try await install(key: entry.version, label: "Valkey \(entry.version)", url: entry.url, size: entry.size,
                          sha256: entry.sha256, requiredExecutables: ["bin/valkey-server", "bin/valkey-cli"],
                          destination: installDir.appendingPathComponent(entry.version, isDirectory: true), manifest: nil)
        scanInstalled()
    }

    func install(_ module: ModuleEntry) async throws {
        guard Self.isValid(module) else { throw InstallError("The \(module.title) module has an invalid registry entry.") }
        try await install(key: module.id, label: "the \(module.title) module", url: module.url, size: module.size,
                          sha256: module.sha256, requiredExecutables: [module.file],
                          destination: modulesDir.appendingPathComponent(module.id, isDirectory: true),
                          manifest: try JSONEncoder().encode(module))
        scanInstalledModules()
    }

    private func install(key: String, label: String, url: String, size: Int, sha256: String,
                         requiredExecutables: [String], destination: URL, manifest: Data?) async throws {
        guard let url = URL(string: url) else { throw InstallError("\(label) has an invalid download URL.") }
        guard progress[key] == nil else { throw InstallError("\(label) is already being installed.") }
        progress[key] = 0
        defer { progress[key] = nil }
        let file = try await download(url, key: key, label: label)
        defer { try? FileManager.default.removeItem(at: file) }
        try await Task.detached {
            try Self.verifyAndExtract(file, label: label, size: size, sha256: sha256,
                                      requiredExecutables: requiredExecutables, into: destination, manifest: manifest)
        }.value
    }

    private func download(_ url: URL, key: String, label: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            var observation: NSKeyValueObservation?
            let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
                observation?.invalidate()
                if let error { return continuation.resume(throwing: error) }
                guard let tmp, (response as? HTTPURLResponse)?.statusCode ?? 200 == 200 else {
                    return continuation.resume(throwing: InstallError("Download of \(label) failed."))
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
                    if self?.progress[key] != nil { self?.progress[key] = fraction }
                }
            }
            task.resume()
        }
    }

    nonisolated private static func verifyAndExtract(_ file: URL, label: String, size: Int, sha256: String,
                                                     requiredExecutables: [String], into dest: URL, manifest: Data?) throws {
        let data = try Data(contentsOf: file)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == size, hash == sha256.lowercased() else {
            throw InstallError("The download of \(label) didn't match its published checksum, so it was discarded.")
        }

        let fm = FileManager.default
        let parent = dest.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", file.path, "-C", staging.path]
        try tar.run()
        tar.waitUntilExit()
        let required = requiredExecutables.map { staging.appendingPathComponent($0).path }
        guard tar.terminationStatus == 0, required.allSatisfy(fm.isExecutableFile(atPath:)) else {
            throw InstallError("The download of \(label) is missing \(requiredExecutables.joined(separator: " and ")).")
        }
        if let manifest { try manifest.write(to: staging.appendingPathComponent("module.json")) }

        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: staging, to: dest)
    }

    /// Deletes an installed version. Callers make sure no server uses it.
    func remove(_ version: String) {
        guard Self.isValid(version) else { return }
        try? FileManager.default.removeItem(at: installDir.appendingPathComponent(version, isDirectory: true))
        scanInstalled()
    }

    /// Deletes an installed module build. Callers make sure no server loads it.
    func remove(_ module: ModuleEntry) {
        guard Self.isValid(module) else { return }
        try? FileManager.default.removeItem(at: modulesDir.appendingPathComponent(module.id, isDirectory: true))
        scanInstalledModules()
    }
}
