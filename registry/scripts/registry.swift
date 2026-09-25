#!/usr/bin/env swift
// Maintains the signed registry of Valkey builds that Valkey.app can install (registry/registry.json).
//
//   swift registry/scripts/registry.swift keygen <private-key-file>        prints the public key for VersionStore.swift
//   swift registry/scripts/registry.swift add <registry.json> <version> <url> <tarball> [minimumMacOS]
//   VALKEY_REGISTRY_PRIVATE_KEY=<base64> swift registry/scripts/registry.swift sign <registry.json>
//   swift registry/scripts/registry.swift verify <registry.json> <public-key>
//
// `sign` writes <registry.json>.sig: a base64 Ed25519 signature over the exact bytes of registry.json.
// Keep the JSON shape in sync with VersionStore.Entry.
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

struct Registry: Codable {
    var schemaVersion = 1
    var versions: [Entry] = []
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments.dropFirst().map { $0 }
guard let command = args.first else { fail("usage: registry.swift keygen|add|sign|verify …") }

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
    guard version.range(of: #"^[0-9]+(\.[0-9]+){1,3}$"#, options: .regularExpression) != nil else { fail("bad version \(version)") }
    guard let data = FileManager.default.contents(atPath: tarball) else { fail("can't read \(tarball)") }
    var registry = FileManager.default.contents(atPath: registryPath)
        .map { data in (try? JSONDecoder().decode(Registry.self, from: data)) ?? { fail("can't parse \(registryPath)") }() }
        ?? Registry()
    let entry = Entry(version: version, url: url,
                      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                      size: data.count, minimumMacOS: args.count == 6 ? args[5] : "13.0",
                      published: ISO8601DateFormatter.string(from: Date(), timeZone: .init(identifier: "UTC")!, formatOptions: .withFullDate))
    registry.versions.removeAll { $0.version == version }
    registry.versions.append(entry)
    registry.versions.sort { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try! (encoder.encode(registry) + Data("\n".utf8)).write(to: URL(fileURLWithPath: registryPath))
    print("added \(version) (\(entry.sha256))")

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
    fail("usage: registry.swift keygen|add|sign|verify …")
}
