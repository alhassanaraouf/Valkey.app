import Foundation

/// Checks that keep a downloaded archive inside its install folder. Signed registry entries are trusted,
/// but a malformed or compromised build must still never write outside the staging directory.
enum ArchiveSafety {
    struct Unsafe: Error, CustomStringConvertible { let description: String }

    /// Rejects member names that are absolute or climb out with `..` (checked before extracting).
    static func validate(entries: [String]) throws {
        for raw in entries {
            let name = raw.hasPrefix("./") ? String(raw.dropFirst(2)) : raw
            if name.isEmpty || name == "." { continue }
            if name.hasPrefix("/") || name.hasPrefix("~") { throw Unsafe(description: "absolute path \(raw)") }
            if name.split(separator: "/", omittingEmptySubsequences: false).contains("..") {
                throw Unsafe(description: "parent-directory path \(raw)")
            }
        }
    }

    /// After extracting: every item must be a regular file, directory or a symlink whose target
    /// resolves inside `root`. Anything else (devices, FIFOs, sockets, escaping links) is rejected.
    static func validateTree(at root: URL) throws {
        let fm = FileManager.default
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        func inside(_ path: String) -> Bool { path == base || path.hasPrefix(base + "/") }
        guard let walker = fm.enumerator(atPath: root.path) else { throw Unsafe(description: "unreadable staging folder") }
        while let rel = walker.nextObject() as? String {
            let path = root.appendingPathComponent(rel).path
            let type = (try fm.attributesOfItem(atPath: path)[.type] as? FileAttributeType) ?? .typeUnknown
            switch type {
            case .typeRegular, .typeDirectory:
                continue
            case .typeSymbolicLink:
                let target = try fm.destinationOfSymbolicLink(atPath: path)
                let absolute = target.hasPrefix("/") ? target
                    : URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(target).path
                let resolved = URL(fileURLWithPath: absolute).standardizedFileURL.resolvingSymlinksInPath().path
                guard inside(resolved) else { throw Unsafe(description: "symlink \(rel) points outside the install folder") }
            default:
                throw Unsafe(description: "unsupported file type at \(rel)")
            }
        }
    }
}
