// Standalone tests for the CLI's argument parsing and server lookup (no Xcode test target needed):
//   app/scripts/test-cli.sh
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) { print(ok ? "ok   \(name)" : "FAIL \(name)"); if !ok { failures += 1 } }
func code(_ body: () throws -> Any) -> Int32? {
    do { _ = try body(); return nil } catch let f as CLI.Failure { return f.code } catch { return -1 }
}

// Invocation
check("symlink name is CLI", CLI.isInvocation(["/opt/homebrew/bin/valkey-app"]))
check("command arg is CLI", CLI.isInvocation(["/Applications/Valkey.app/Contents/MacOS/Valkey", "list"]))
check("plain launch is app", !CLI.isInvocation(["/Applications/Valkey.app/Contents/MacOS/Valkey"]))
check("Xcode args are app", !CLI.isInvocation(["Valkey", "-NSDocumentRevisionsDebugMode", "YES"]))

// Parsing
check("list", try! CLI.parse(["list"]) == CLI.Invocation(command: "list"))
check("--json anywhere", try! CLI.parse(["--json", "status", "cache"]) == CLI.Invocation(command: "status", target: "cache", json: true))
check("create options", try! CLI.parse(["create", "cache", "--port", "6390", "--version=9.1.2"])
      == CLI.Invocation(command: "create", target: "cache", options: ["--port": "6390", "--version": "9.1.2"]))
check("logs short flags", try! CLI.parse(["logs", "6379", "-f", "-n", "5"])
      == CLI.Invocation(command: "logs", target: "6379", options: ["--follow": "", "--lines": "5"]))
check("delete -y", try! CLI.parse(["delete", "x", "-y"]).options["--yes"] != nil)
check("help", try! CLI.parse(["--help"]).command == "help" && CLI.parse(["help"]).command == "help")
check("no args is usage", code { try CLI.parse([]) } == CLI.Failure.usage)
check("unknown command", code { try CLI.parse(["frobnicate"]) } == CLI.Failure.usage)
check("missing server", code { try CLI.parse(["start"]) } == CLI.Failure.usage)
check("extra args", code { try CLI.parse(["start", "a", "b"]) } == CLI.Failure.usage)
check("list takes no server", code { try CLI.parse(["list", "a"]) } == CLI.Failure.usage)
check("unknown option", code { try CLI.parse(["list", "--nope"]) } == CLI.Failure.usage)
check("option on wrong command", code { try CLI.parse(["start", "a", "-f"]) } == CLI.Failure.usage)
check("missing value", code { try CLI.parse(["create", "--port"]) } == CLI.Failure.usage)
check("bad port", code { try CLI.parse(["create", "--port", "abc"]) } == CLI.Failure.usage)
check("negative lines", code { try CLI.parse(["logs", "a", "-n", "-3"]) } == CLI.Failure.usage)

// Resolving a server
func server(_ name: String, _ port: Int, _ id: String) -> CLI.ServerInfo {
    .init(id: id, name: name, version: "9.1.2", port: port, state: "stopped", pid: nil, failure: nil, modules: [],
          startAutomatically: false, dataDirectory: "/d", logFile: "/d/valkey.log")
}
let servers = [server("Cache", 6379, "AAAA-1"), server("Valkey 9.1.2", 6380, "BBBB-2"), server("Valkey 9.1.2", 6381, "CCCC-3"),
               server("6381", 7000, "DDDD-4")]
check("by id, any case", (try? CLI.resolve("bbbb-2", in: servers))?.port == 6380)
check("by port", (try? CLI.resolve("6379", in: servers))?.name == "Cache")
check("port wins over name", (try? CLI.resolve("6381", in: servers))?.id == "CCCC-3")
check("by name, any case", (try? CLI.resolve("cache", in: servers))?.port == 6379)
check("duplicate name is ambiguous", code { try CLI.resolve("Valkey 9.1.2", in: servers) } == CLI.Failure.notFound)
check("unknown is not found", code { try CLI.resolve("nope", in: servers) } == CLI.Failure.notFound)

// Output helpers
check("last lines", CLI.lastLines(of: "a\nb\nc\n", 2) == ["b", "c"])
check("last lines, no trailing newline", CLI.lastLines(of: "a\nb", 5) == ["a", "b"])
check("last lines, empty", CLI.lastLines(of: "", 5) == [])
check("table pads columns", CLI.table([["NAME", "PORT"], ["Cache", "6379"]]) == "NAME   PORT\nCache  6379")

// Request round-trips through JSON
let request = CLI.Request(command: "create", server: nil, name: "x", port: 6390, version: "9.1.2", user: nil)
check("request JSON", (try? JSONDecoder().decode(CLI.Request.self, from: JSONEncoder().encode(request))) == request)

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
