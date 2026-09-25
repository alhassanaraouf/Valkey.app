#!/usr/bin/env swift
// Adds a release to the Sparkle update feed (website/appcast.xml), newest first.
//
//   VALKEY_REGISTRY_PRIVATE_KEY=<base64> swift app/scripts/appcast.swift \
//       <appcast.xml> <version> <build> <archive-url> <archive.zip> <release-notes.md> [minimumMacOS]
//
// The archive is signed with the same Ed25519 key as the Valkey registry; the app checks it
// against SUPublicEDKey. An existing entry with the same build number is replaced.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 6 || args.count == 7 else {
    fail("usage: appcast.swift <appcast.xml> <version> <build> <archive-url> <archive.zip> <notes.md> [minimumMacOS]")
}
let (feedPath, version, build, url, archivePath, notesPath) = (args[0], args[1], args[2], args[3], args[4], args[5])
let minimumMacOS = args.count == 7 ? args[6] : "13.0"

guard let keyText = ProcessInfo.processInfo.environment["VALKEY_REGISTRY_PRIVATE_KEY"],
      let raw = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("set VALKEY_REGISTRY_PRIVATE_KEY") }
guard let archive = FileManager.default.contents(atPath: archivePath) else { fail("can't read \(archivePath)") }
guard let notes = try? String(contentsOfFile: notesPath, encoding: .utf8) else { fail("can't read \(notesPath)") }
let signature = try! key.signature(for: archive).base64EncodedString()

let sparkleNS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
let empty = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="\(sparkleNS)">
      <channel>
        <title>Valkey.app</title>
        <link>https://valkey.app/appcast.xml</link>
        <description>Valkey.app updates</description>
      </channel>
    </rss>
    """
let existing = FileManager.default.contents(atPath: feedPath) ?? Data(empty.utf8)
guard let doc = try? XMLDocument(data: existing, options: [.nodePreserveWhitespace]),
      let channel = try? doc.nodes(forXPath: "/rss/channel").first as? XMLElement else { fail("can't parse \(feedPath)") }

// Replace an entry for the same build.
for item in channel.elements(forName: "item")
where item.elements(forName: "sparkle:version").first?.stringValue == build {
    item.detach()
}

func element(_ name: String, _ value: String) -> XMLElement {
    XMLElement(name: name, stringValue: value)
}
let date = DateFormatter()
date.locale = Locale(identifier: "en_US_POSIX")
date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

let item = XMLElement(name: "item")
item.addChild(element("title", "Version \(version)"))
item.addChild(element("pubDate", date.string(from: Date())))
item.addChild(element("sparkle:version", build))
item.addChild(element("sparkle:shortVersionString", version))
item.addChild(element("sparkle:minimumSystemVersion", minimumMacOS))
let description = XMLElement(name: "description")
description.addAttribute(XMLNode.attribute(withName: "sparkle:format", stringValue: "markdown") as! XMLNode)
let cdata = XMLNode(kind: .text, options: .nodeIsCDATA)
cdata.stringValue = notes
description.addChild(cdata)
item.addChild(description)
let enclosure = XMLElement(name: "enclosure")
for (name, value) in [("url", url), ("length", String(archive.count)),
                      ("type", "application/octet-stream"), ("sparkle:edSignature", signature)] {
    enclosure.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
}
item.addChild(enclosure)

// Newest first: insert before the first existing item.
let firstItemIndex = channel.children?.firstIndex { $0.name == "item" } ?? channel.childCount
channel.insertChild(item, at: firstItemIndex)

let output = doc.xmlData(options: [.nodePrettyPrint, .nodeCompactEmptyElement])
try! output.write(to: URL(fileURLWithPath: feedPath))
print("added \(version) (build \(build)) to \(feedPath)")
