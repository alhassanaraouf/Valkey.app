// Standalone tests for the CLI's parsing, server lookup, output and the shared setting rules
// (no Xcode test target needed):  app/scripts/test-cli.sh
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) { print(ok ? "ok   \(name)" : "FAIL \(name)"); if !ok { failures += 1 } }
func code(_ body: () throws -> Any) -> Int32? {
    do { _ = try body(); return nil } catch let f as CLI.Failure { return f.code } catch { return -1 }
}
func parsed(_ args: [String]) -> CLI.Invocation? { try? CLI.parse(args) }

// Invocation
check("symlink name is CLI", CLI.isInvocation(["/opt/homebrew/bin/valkey-app"]))
check("command arg is CLI", CLI.isInvocation(["/Applications/Valkey.app/Contents/MacOS/Valkey", "list"]))
check("group arg is CLI", CLI.isInvocation(["Valkey", "versions"]) && CLI.isInvocation(["Valkey", "user"]))
check("plain launch is app", !CLI.isInvocation(["/Applications/Valkey.app/Contents/MacOS/Valkey"]))
check("Xcode args are app", !CLI.isInvocation(["Valkey", "-NSDocumentRevisionsDebugMode", "YES"]))

// Parsing
check("list", parsed(["list"]) == CLI.Invocation(command: "list"))
check("--json anywhere", parsed(["--json", "status", "cache"]) == CLI.Invocation(command: "status", args: ["cache"], json: true))
check("create name becomes --name", parsed(["create", "cache", "--port", "6390", "--version=9.1.2"])
      == CLI.Invocation(command: "create", options: ["--name": "cache", "--port": "6390", "--version": "9.1.2"]))
check("create name twice", code { try CLI.parse(["create", "a", "--name", "b"]) } == CLI.Failure.usage)
check("set settings", parsed(["set", "cache", "--max-memory", "256mb", "--auto-start", "on", "--password", ""])?.options
      == ["--max-memory": "256mb", "--auto-start": "on", "--password": ""])
check("bad bool", code { try CLI.parse(["set", "cache", "--persistence", "maybe"]) } == CLI.Failure.usage)
check("logs short flags", parsed(["logs", "6379", "-f", "-n", "5", "--filter", "ready"])
      == CLI.Invocation(command: "logs", args: ["6379"], options: ["--follow": "", "--lines": "5", "--filter": "ready"]))
check("delete -y", parsed(["delete", "x", "-y"])?.options["--yes"] != nil)
check("subcommand", parsed(["versions", "install", "9.1.2"]) == CLI.Invocation(command: "versions install", args: ["9.1.2"]))
check("group alone is a list", parsed(["modules", "--valkey", "9.1"]) == CLI.Invocation(command: "modules", options: ["--valkey": "9.1"]))
check("user add", parsed(["user", "add", "cache", "app", "--password", "-", "--read-only", "on"])
      == CLI.Invocation(command: "user add", args: ["cache", "app"], options: ["--password": "-", "--read-only": "on"]))
check("user alone is unknown", code { try CLI.parse(["user"]) } == CLI.Failure.usage)
check("app set", parsed(["app", "set", "--menu-bar", "off"]) == CLI.Invocation(command: "app set", options: ["--menu-bar": "off"]))
check("cli passes args through", parsed(["--json", "cli", "cache", "SET", "k", "--json", "-n", "1"])
      == CLI.Invocation(command: "cli", args: ["cache", "SET", "k", "--json", "-n", "1"], json: true))
check("show secrets flag", parsed(["show", "cache", "--show-secrets"])?.options["--show-secrets"] != nil)
check("help", parsed(["--help"]) == CLI.Invocation(command: "help") && parsed(["help"]) == CLI.Invocation(command: "help"))
check("no args shows help", parsed([]) == CLI.Invocation(command: "help"))
check("unknown command", code { try CLI.parse(["frobnicate"]) } == CLI.Failure.usage)
check("missing server", code { try CLI.parse(["start"]) } == CLI.Failure.usage)
check("extra args", code { try CLI.parse(["start", "a", "b"]) } == CLI.Failure.usage)
check("list takes no server", code { try CLI.parse(["list", "a"]) } == CLI.Failure.usage)
check("unknown option", code { try CLI.parse(["list", "--nope"]) } == CLI.Failure.usage)
check("option on wrong command", code { try CLI.parse(["start", "a", "-f"]) } == CLI.Failure.usage)
check("missing value", code { try CLI.parse(["create", "--port"]) } == CLI.Failure.usage)
check("bad port", code { try CLI.parse(["create", "--port", "abc"]) } == CLI.Failure.usage)
check("negative lines", code { try CLI.parse(["logs", "a", "-n", "-3"]) } == CLI.Failure.usage)

// Help
check("help create", parsed(["help", "create"]) == CLI.Invocation(command: "help", args: ["create"]))
check("create --help", parsed(["create", "cache", "--port", "1", "--help"]) == CLI.Invocation(command: "help", args: ["create"]))
check("subcommand -h", parsed(["user", "add", "-h"]) == CLI.Invocation(command: "help", args: ["user add"]))
check("cli --help is ours", parsed(["cli", "--help"]) == CLI.Invocation(command: "help", args: ["cli"]))
check("cli <server> --help is valkey-cli's", parsed(["cli", "cache", "--help"]) == CLI.Invocation(command: "cli", args: ["cache", "--help"]))
check("help --json", parsed(["help", "--json"]) == CLI.Invocation(command: "help", json: true))
check("help for unknown command", code { try CLI.parse(["help", "nope"]) } == CLI.Failure.usage)
check("did you mean a command", CLI.suggestion(for: "craete", in: CLI.specs.map(\.name)) == "create")
func message(_ args: [String]) -> String {
    do { _ = try CLI.parse(args); return "" } catch let f as CLI.Failure { return f.message } catch { return "" }
}
check("did you mean an option", message(["set", "a", "--prot", "1"]).contains("Did you mean --port?"))
check("usage errors show the command's usage", message(["start"]).contains("Usage: valkey-app start <server>"))
check("group alone lists subcommands", message(["user"]).contains("add, set, remove"))

/// Minimal shell-word splitting for the examples: spaces, '…' and "…".
func words(_ line: String) -> [String] {
    var out: [String] = [], current = "", quote: Character?, started = false
    for c in line {
        if let q = quote { if c == q { quote = nil } else { current.append(c) }; continue }
        if c == "'" || c == "\"" { quote = c; started = true; continue }
        if c == " " { if started || !current.isEmpty { out.append(current) }; current = ""; started = false; continue }
        current.append(c)
    }
    if started || !current.isEmpty { out.append(current) }
    return out
}
for s in CLI.specs {
    check("\(s.name): documented", !s.summary.isEmpty && !s.examples.isEmpty && s.args.allSatisfy { !$0.help.isEmpty }
          && s.options.allSatisfy { !$0.help.isEmpty })
    check("\(s.name): help shows every option", s.options.allSatisfy { CLI.help(for: s).contains($0.name) })
    check("\(s.name): in the overview", CLI.overview.contains("  " + s.usage.dropFirst("valkey-app ".count).replacingOccurrences(of: " [options]", with: "")))
    for e in s.examples where !e.command.contains("<") {
        let argv = Array(words(e.command).dropFirst())
        check("example parses: \(e.command)", (try? CLI.parse(argv))?.command == s.name)
    }
}
check("help lines fit 100 columns", CLI.specs.allSatisfy { CLI.help(for: $0).split(separator: "\n").allSatisfy { $0.count <= 100 || !$0.contains(" ") } })

// Resolving a server
func server(_ name: String, _ port: Int, _ id: String) -> CLI.ServerInfo {
    .init(id: id, name: name, version: "9.1.2", port: port, state: "stopped", pid: nil, failure: nil, startAutomatically: false,
          autoRestart: true, persistence: true, maxMemory: nil, evictionPolicy: "noeviction", hasPassword: false, password: nil,
          users: [], modules: [], dataDirectory: "/d", configFile: "/d/valkey.conf", logFile: "/d/valkey.log")
}
let servers = [server("Cache", 6379, "AAAA-1"), server("Valkey 9.1.2", 6380, "BBBB-2"), server("Valkey 9.1.2", 6381, "CCCC-3"),
               server("6381", 7000, "DDDD-4")]
check("by id, any case", (try? CLI.resolve("bbbb-2", in: servers))?.port == 6380)
check("by port", (try? CLI.resolve("6379", in: servers))?.name == "Cache")
check("port wins over name", (try? CLI.resolve("6381", in: servers))?.id == "CCCC-3")
check("by name, any case", (try? CLI.resolve("cache", in: servers))?.port == 6379)
check("duplicate name is ambiguous", code { try CLI.resolve("Valkey 9.1.2", in: servers) } == CLI.Failure.notFound)
check("unknown is not found", code { try CLI.resolve("nope", in: servers) } == CLI.Failure.notFound)

// The JSON schema round-trips (the app encodes, the CLI decodes)
let encoded = try! JSONEncoder().encode(servers[0])
check("server JSON round-trips", (try? JSONDecoder().decode(CLI.ServerInfo.self, from: encoded)) == servers[0])
check("no password key without secrets", !String(decoding: encoded, as: UTF8.self).contains("\"password\""))

// Output helpers
check("last lines", CLI.lastLines(of: "a\nb\nc\n", 2) == ["b", "c"])
check("last lines, no trailing newline", CLI.lastLines(of: "a\nb", 5) == ["a", "b"])
check("last lines, empty", CLI.lastLines(of: "", 5) == [])
check("table pads columns", CLI.table([["NAME", "PORT"], ["Cache", "6379"]]) == "NAME   PORT\nCache  6379")
let json = try! JSONSerialization.jsonObject(with: Data(#"{"b":true,"a":1,"l":["x","y"],"u":[{"name":"n","readOnly":false}],"z":null}"#.utf8))
check("render", CLI.render(json) == ["a: 1", "b: yes", "l: x, y", "u:", "  - name: n", "    readOnly: no", "z: -"])

// Real file tails: match the old semantics across chunk/UTF-8 boundaries and leave EOF for follow.
let logURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: logURL) }
for text in ["", "\n", "a\n\n", "a\nb", "first\nÉRROR 🐱\nlast\n", String(repeating: "x", count: 200) + "\nend"] {
    try! Data(text.utf8).write(to: logURL)
    let handle = try! FileHandle(forReadingFrom: logURL)
    for count in [0, 1, 2, 10] {
        for filter in ["", "error", "érror", "missing", "x"] {
            let expected = Array(CLI.lastLines(of: text, .max).filter {
                filter.isEmpty || $0.localizedCaseInsensitiveContains(filter)
            }.suffix(count))
            check("chunked tail \(text.utf8.count) bytes, \(count), \(filter)",
                  CLI.readLogTail(handle, lines: count, filter: filter, chunkSize: 3) == expected)
            check("tail leaves EOF for follow", handle.offsetInFile == UInt64(text.utf8.count))
        }
    }
    try! handle.close()
}
// A sparse large log must only need its small suffix for an ordinary tail.
try! Data().write(to: logURL)
let growingLog = try! FileHandle(forUpdating: logURL)
growingLog.seek(toFileOffset: 1_000_000_000)
growingLog.write(Data("\nready\nlast\n".utf8))
check("large sparse log tail", CLI.readLogTail(growingLog, lines: 2) == ["ready", "last"])
let writer = try! FileHandle(forWritingTo: logURL)
writer.seekToEndOfFile()
writer.write(Data("appended\n".utf8))
try! writer.close()
check("follow starts at captured EOF", String(decoding: growingLog.readDataToEndOfFile(), as: UTF8.self) == "appended\n")
try! growingLog.close()

// The actual default prompt destination must not contaminate JSON on stdout.
let capturedOut = Pipe(), capturedError = Pipe()
fflush(stdout)
let savedOut = dup(STDOUT_FILENO), savedError = dup(STDERR_FILENO)
dup2(capturedOut.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
dup2(capturedError.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
CLI.writePrompt("Remove cache? [y/N] ")
dup2(savedOut, STDOUT_FILENO)
dup2(savedError, STDERR_FILENO)
close(savedOut)
close(savedError)
try! capturedOut.fileHandleForWriting.close()
try! capturedError.fileHandleForWriting.close()
check("prompt keeps stdout clean", capturedOut.fileHandleForReading.readDataToEndOfFile().isEmpty)
check("prompt goes to stderr", String(decoding: capturedError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "Remove cache? [y/N] ")

// Shared setting rules
check("memory sizes", ConfigRules.maxMemoryProblem("256mb") == nil && ConfigRules.maxMemoryProblem("2GB") == nil
      && ConfigRules.maxMemoryProblem("100") == nil && ConfigRules.maxMemoryProblem(nil) == nil)
check("bad memory size", ConfigRules.maxMemoryProblem("lots") != nil)
check("users ok", ConfigRules.usersProblem([("app", "pw"), ("ro", "pw")]) == nil)
check("user named default", ConfigRules.usersProblem([("default", "pw")]) != nil)
check("duplicate user", ConfigRules.usersProblem([("a", "pw"), ("a", "pw")]) != nil)
check("user without password", ConfigRules.usersProblem([("a", "")]) != nil)
check("user with space", ConfigRules.usersProblem([("a b", "pw")]) != nil)
check("bools", ConfigRules.bool("on") == true && ConfigRules.bool("NO") == false && ConfigRules.bool("x") == nil)

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
