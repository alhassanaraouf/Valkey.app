// Standalone tests for ArchiveSafety (no Xcode test target needed):
//   app/scripts/test-archive-safety.sh
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) { print(ok ? "ok   \(name)" : "FAIL \(name)"); if !ok { failures += 1 } }
func throwsUnsafe(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return error is ArchiveSafety.Unsafe } }

check("normal entries pass", !throwsUnsafe { try ArchiveSafety.validate(entries: ["./", "bin/", "./bin/valkey-server", "lib/a.dylib"]) })
check("absolute path rejected", throwsUnsafe { try ArchiveSafety.validate(entries: ["/etc/passwd"]) })
check("home path rejected", throwsUnsafe { try ArchiveSafety.validate(entries: ["~/x"]) })
check("parent dir rejected", throwsUnsafe { try ArchiveSafety.validate(entries: ["bin/../../evil"]) })
check("leading .. rejected", throwsUnsafe { try ArchiveSafety.validate(entries: ["../evil"]) })
check("dots in names allowed", !throwsUnsafe { try ArchiveSafety.validate(entries: ["bin/valkey..cfg", "a/.hidden"]) })

let fm = FileManager.default
func tree(_ setup: (URL) throws -> Void) throws -> URL {
    let root = fm.temporaryDirectory.appendingPathComponent("as-\(UUID().uuidString)")
    try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: root.appendingPathComponent("bin/valkey-server"))
    try setup(root)
    return root
}
let good = try tree { r in try fm.createSymbolicLink(atPath: r.appendingPathComponent("bin/valkey-cli").path, withDestinationPath: "valkey-server") }
check("inside symlink passes", !throwsUnsafe { try ArchiveSafety.validateTree(at: good) })
let badAbs = try tree { r in try fm.createSymbolicLink(atPath: r.appendingPathComponent("bin/x").path, withDestinationPath: "/etc") }
check("absolute symlink rejected", throwsUnsafe { try ArchiveSafety.validateTree(at: badAbs) })
let badRel = try tree { r in try fm.createSymbolicLink(atPath: r.appendingPathComponent("bin/x").path, withDestinationPath: "../../outside") }
check("escaping relative symlink rejected", throwsUnsafe { try ArchiveSafety.validateTree(at: badRel) })
let fifo = try tree { r in
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/mkfifo"); p.arguments = [r.appendingPathComponent("bin/pipe").path]
    try p.run(); p.waitUntilExit()
}
check("fifo rejected", throwsUnsafe { try ArchiveSafety.validateTree(at: fifo) })
for r in [good, badAbs, badRel, fifo] { try? fm.removeItem(at: r) }

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
