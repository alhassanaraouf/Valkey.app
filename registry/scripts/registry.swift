#!/usr/bin/env swift
// Maintains the signed registry of Valkey builds that Valkey.app can install (registry/registry.json).
//
//   swift registry/scripts/registry.swift keygen <private-key-file>        prints the public key for VersionStore.swift
//   swift registry/scripts/registry.swift add <registry.json> <version> <url> <tarball> [minimumMacOS]
//   swift registry/scripts/registry.swift add-module <registry.json> <module-meta.json> <url> <tarball>
//         (module-meta.json is written by package-module.sh: id, name, version, title, summary, file,
//          valkey, architectures, minimumMacOS)
//   VALKEY_REGISTRY_PRIVATE_KEY=<base64> swift registry/scripts/registry.swift sign <registry.json>
//   swift registry/scripts/registry.swift verify <registry.json> <public-key>
//
// `sign` writes <registry.json>.sig: a base64 Ed25519 signature over the exact bytes of registry.json.
// Keep the JSON shapes in sync with VersionStore.Entry and VersionStore.ModuleEntry.
import CryptoKit
import Foundation

struct Entry: Codable {
    var version: String
    var url: String
    var sha256: String
    var size: Int
    var minimumMacOS: String
    var published: String
}

/// A module build, installable only on the Valkey minor lines in `valkey` (each tested at publish time).
struct ModuleEntry: Codable {
    var id: String
    var name: String
    var version: String
    var title: String
    var summary: String
    var file: String
    var valkey: [String]
    var architectures: [String]
    var url: String
    var sha256: String
    var size: Int
    var minimumMacOS: String
    var published: String
    var sourceCommit: String?
}

struct Registry: Codable {
    var schemaVersion = 1
    var versions: [Entry] = []
    var modules: [ModuleEntry]?
}

func load(_ path: String) -> Registry {
    FileManager.default.contents(atPath: path)
        .map { data in (try? JSONDecoder().decode(Registry.self, from: data)) ?? { fail("can't parse \(path)") }() }
        ?? Registry()
}

func save(_ registry: Registry, to path: String) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try! (encoder.encode(registry) + Data("\n".utf8)).write(to: URL(fileURLWithPath: path))
}

func matches(_ value: String, _ pattern: String) -> Bool {
    value.range(of: pattern, options: .regularExpression) != nil
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

let today = ISO8601DateFormatter.string(from: Date(), timeZone: .init(identifier: "UTC")!, formatOptions: .withFullDate)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments.dropFirst().map { $0 }
guard let command = args.first else { fail("usage: registry.swift keygen|add|add-module|sign|verify …") }

switch (command, args.count) {
case ("keygen", 2):
    let path = args[1]
    guard !FileManager.default.fileExists(atPath: path) else { fail("\(path) already exists; not overwriting a key") }
    let key = Curve25519.Signing.PrivateKey()
    guard FileManager.default.createFile(atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                         attributes: [.posixPermissions: 0o600]) else { fail("can't write \(path)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())

case ("add", 5), ("add", 6):
    let (registryPath, version, url, tarball) = (args[1], args[2], args[3], args[4])
    guard matches(version, #"^[0-9]+(\.[0-9]+){1,3}$"#) else { fail("bad version \(version)") }
    guard let data = FileManager.default.contents(atPath: tarball) else { fail("can't read \(tarball)") }
    var registry = load(registryPath)
    let entry = Entry(version: version, url: url, sha256: sha256(data), size: data.count,
                      minimumMacOS: args.count == 6 ? args[5] : "13.0", published: today)
    registry.versions.removeAll { $0.version == version }
    registry.versions.append(entry)
    registry.versions.sort { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    save(registry, to: registryPath)
    print("added \(version) (\(entry.sha256))")

case ("add-module", 5):
    struct Meta: Codable {
        var id, name, version, title, summary, file, minimumMacOS: String
        var valkey, architectures: [String]
        var sourceCommit: String?
    }
    let (registryPath, metaPath, url, tarball) = (args[1], args[2], args[3], args[4])
    guard let metaData = FileManager.default.contents(atPath: metaPath),
          let m = try? JSONDecoder().decode(Meta.self, from: metaData) else { fail("can't read \(metaPath)") }
    // The app turns id and file into paths, so keep them to plain names.
    guard matches(m.id, #"^[a-z0-9][a-z0-9.+-]*$"#) else { fail("bad id \(m.id)") }
    guard matches(m.name, #"^[a-z][a-z0-9-]*$"#) else { fail("bad name \(m.name)") }
    guard matches(m.version, #"^[0-9]+(\.[0-9]+){1,3}$"#) else { fail("bad version \(m.version)") }
    guard matches(m.file, #"^[A-Za-z0-9_.-]+\.(dylib|so)$"#) else { fail("bad file \(m.file)") }
    guard !m.valkey.isEmpty, m.valkey.allSatisfy({ matches($0, #"^[0-9]+\.[0-9]+$"#) }) else { fail("bad valkey lines \(m.valkey)") }
    guard !m.architectures.isEmpty, m.architectures.allSatisfy(["arm64", "x86_64"].contains) else { fail("bad architectures") }
    guard let data = FileManager.default.contents(atPath: tarball) else { fail("can't read \(tarball)") }
    var registry = load(registryPath)
    let entry = ModuleEntry(id: m.id, name: m.name, version: m.version, title: m.title, summary: m.summary, file: m.file,
                            valkey: m.valkey, architectures: m.architectures, url: url, sha256: sha256(data),
                            size: data.count, minimumMacOS: m.minimumMacOS, published: today,
                            sourceCommit: m.sourceCommit)
    var modules = registry.modules ?? []
    modules.removeAll { $0.id == m.id }
    modules.append(entry)
    // By name, then newest version first.
    modules.sort { $0.name != $1.name ? $0.name < $1.name : $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    registry.modules = modules
    save(registry, to: registryPath)
    print("added module \(m.id) for Valkey \(m.valkey.joined(separator: ", ")) on \(m.architectures.joined(separator: "+")) (\(entry.sha256))")

case ("sign", 2):
    guard let keyText = ProcessInfo.processInfo.environment["VALKEY_REGISTRY_PRIVATE_KEY"],
          let raw = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("set VALKEY_REGISTRY_PRIVATE_KEY") }
    guard let data = FileManager.default.contents(atPath: args[1]) else { fail("can't read \(args[1])") }
    let signature = try! key.signature(for: data).base64EncodedString()
    try! Data((signature + "\n").utf8).write(to: URL(fileURLWithPath: args[1] + ".sig"))
    print("signed \(args[1])")

case ("verify", 3):
    guard let data = FileManager.default.contents(atPath: args[1]),
          let sigText = try? String(contentsOfFile: args[1] + ".sig", encoding: .utf8),
          let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let raw = Data(base64Encoded: args[2]),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
          key.isValidSignature(sig, for: data) else { fail("signature is NOT valid") }
    print("signature OK")

default:
    fail("usage: registry.swift keygen|add|add-module|sign|verify …")
}
