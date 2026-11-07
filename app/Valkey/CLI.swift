import Foundation

/// `valkey-app`, the command-line interface. It is the app's own executable run under that name
/// (Homebrew links it as `valkey-app`), so it ships and updates with the app.
///
/// The CLI never touches servers itself: it sends each request to the running app over a local
/// CFMessagePort (see CLIServer.swift), launching the app in the background if needed, so the app
/// stays the only owner of the server list and the server processes.
/// This file is Foundation-only so Tests/CLITests.swift can compile it standalone.
enum CLI {
    static let portName = "app.valkey.Valkey.cli"
    static let name = "valkey-app"

    /// The process was started as `valkey-app` (via a symlink) or with a CLI command as its first argument.
    static func isInvocation(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        if (first as NSString).lastPathComponent == name { return true }
        return arguments.count > 1 && (commands[arguments[1]] != nil || ["help", "-h", "--help"].contains(arguments[1]))
    }

    // MARK: Messages between the CLI and the app

    struct Request: Codable, Equatable {
        var command: String
        var server: String?
        var name: String?
        var port: Int?
        var version: String?
        var user: String?
    }

    struct ServerInfo: Codable, Equatable {
        var id: String
        var name: String
        var version: String
        var port: Int
        var state: String       // running, stopping, stopped, failed
        var pid: Int32?
        var failure: String?
        var modules: [String]
        var startAutomatically: Bool
        var dataDirectory: String
        var logFile: String
    }

    struct Response: Codable {
        var error: String?
        var exitCode: Int32?
        var servers: [ServerInfo]?
        var url: String?
    }

    /// An error with the exit code to leave with.
    struct Failure: Error, Equatable {
        static let failed: Int32 = 1, usage: Int32 = 2, notFound: Int32 = 3, unreachable: Int32 = 4
        var message: String
        var code: Int32 = failed
    }

    // MARK: Arguments

    enum Target { case none, optional, required }
    static let commands: [String: (target: Target, options: Set<String>)] = [
        "list": (.none, []),
        "status": (.optional, []),
        "create": (.optional, ["--port", "--version"]),
        "start": (.required, []),
        "stop": (.required, []),
        "restart": (.required, []),
        "delete": (.required, ["--yes"]),
        "logs": (.required, ["--lines", "--follow"]),
        "url": (.required, ["--user"]),
    ]
    private static let valueOptions: Set<String> = ["--port", "--version", "--lines", "--user"]
    private static let aliases = ["-n": "--lines", "-f": "--follow", "-y": "--yes"]

    struct Invocation: Equatable {
        var command: String
        var target: String?
        var options: [String: String] = [:]
        var json = false
    }

    static let usage = """
    Usage: \(name) <command> [server] [options] [--json]

    Commands:
      list                          List servers
      status [server]               Show one server, or all
      create [name] [--port N] [--version V]
                                    Add a server (default: next free port, newest installed version)
      start <server>                Start and wait until it accepts connections
      stop <server>                 Stop and wait until it has exited
      restart <server>              Restart and wait until it accepts connections
      delete <server> [--yes]       Remove a server (stops it; its data directory is kept)
      logs <server> [-n N] [-f]     Print the last N log lines (default 50); -f follows
      url <server> [--user NAME]    Print the connection URL (includes the password, if set)

    <server> is a name, port or id. --json prints JSON (errors too, as {"error": …}).
    Exit codes: 0 ok, 1 failed, 2 usage, 3 server not found, 4 Valkey.app unreachable.
    Valkey.app is launched in the background if it isn't running.
    """

    static func parse(_ arguments: [String]) throws -> Invocation {
        var positional: [String] = [], options: [String: String] = [:], json = false
        var rest = arguments[...]
        while let arg = rest.popFirst() {
            if arg == "--json" { json = true; continue }
            if arg == "-h" || arg == "--help" { return Invocation(command: "help") }
            guard arg.hasPrefix("-"), arg.count > 1 else { positional.append(arg); continue }
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            let key = aliases[parts[0]] ?? parts[0]
            if valueOptions.contains(key) {
                guard let value = parts.count == 2 ? parts[1] : rest.popFirst() else {
                    throw Failure(message: "\(key) needs a value.", code: Failure.usage)
                }
                options[key] = value
            } else if parts.count == 1, aliases.values.contains(key) {
                options[key] = ""
            } else {
                throw Failure(message: "Unknown option \(arg).", code: Failure.usage)
            }
        }
        guard let command = positional.first else { throw Failure(message: usage, code: Failure.usage) }
        if command == "help" { return Invocation(command: "help") }
        guard let spec = commands[command] else {
            throw Failure(message: "Unknown command “\(command)”. Run `\(name) help`.", code: Failure.usage)
        }
        let targets = positional.dropFirst()
        if targets.count > 1 || (spec.target == .none && !targets.isEmpty) {
            throw Failure(message: "Too many arguments for \(command).", code: Failure.usage)
        }
        if spec.target == .required && targets.isEmpty {
            throw Failure(message: "\(command) needs a server (name, port or id).", code: Failure.usage)
        }
        if let bad = options.keys.sorted().first(where: { !spec.options.contains($0) }) {
            throw Failure(message: "\(command) doesn't take \(bad).", code: Failure.usage)
        }
        for key in ["--port", "--lines"] {
            if let v = options[key], Int(v).map({ $0 >= 0 }) != true {
                throw Failure(message: "\(key) must be a number.", code: Failure.usage)
            }
        }
        return Invocation(command: command, target: targets.first, options: options, json: json)
    }

    /// Finds a server by id, then port, then exact name, then case-insensitive name.
    static func resolve(_ query: String, in servers: [ServerInfo]) throws -> ServerInfo {
        let tries: [(ServerInfo) -> Bool] = [
            { $0.id.caseInsensitiveCompare(query) == .orderedSame },
            { Int(query) == $0.port },
            { $0.name == query },
            { $0.name.caseInsensitiveCompare(query) == .orderedSame },
        ]
        for matches in tries {
            let found = servers.filter(matches)
            if found.count == 1 { return found[0] }
            if found.count > 1 {
                throw Failure(message: "“\(query)” matches \(found.count) servers; use the port or id instead.",
                              code: Failure.notFound)
            }
        }
        throw Failure(message: "No server named “\(query)”. Run `\(name) list`.", code: Failure.notFound)
    }

    // MARK: Running a command

    static func run(_ arguments: [String]) -> Int32 {
        let json = arguments.contains("--json")
        do {
            let inv = try parse(arguments)
            if inv.command == "help" { print(usage); return 0 }
            try execute(inv)
            return 0
        } catch let failure as Failure {
            if json {
                printJSON(["error": failure.message])
            } else {
                FileHandle.standardError.write(Data("\(name): \(failure.message)\n".utf8))
            }
            return failure.code
        } catch {
            FileHandle.standardError.write(Data("\(name): \(error.localizedDescription)\n".utf8))
            return Failure.failed
        }
    }

    private static func execute(_ inv: Invocation) throws {
        func one(_ request: Request) throws -> ServerInfo {
            guard let server = try send(request).servers?.first else { throw Failure(message: "Valkey.app sent no server.") }
            return server
        }
        switch inv.command {
        case "list":
            output(inv, try send(Request(command: "list")).servers ?? [])
        case "status":
            if let target = inv.target {
                output(inv, try one(Request(command: "status", server: target)))
            } else {
                output(inv, try send(Request(command: "list")).servers ?? [])
            }
        case "create":
            let server = try one(Request(command: "create", name: inv.target, port: inv.options["--port"].flatMap { Int($0) },
                                         version: inv.options["--version"]))
            output(inv, server, "Created “\(server.name)” on port \(server.port) (Valkey \(server.version)).")
        case "start", "restart":
            let before = try one(Request(command: "status", server: inv.target))
            if before.state == "stopped" || before.state == "failed", portAcceptsConnections(before.port) {
                throw Failure(message: "Port \(before.port) is already in use by another process.")
            }
            if inv.command == "start", before.state == "running" {
                return output(inv, before, "“\(before.name)” is already running on port \(before.port).")
            }
            _ = try one(Request(command: inv.command, server: before.id))
            let server = try wait(for: before.id, timeout: 15, what: "start accepting connections") {
                if $0.state == "failed" { throw Failure(message: "“\($0.name)” failed to start: \($0.failure ?? "see its log").") }
                return $0.state == "running" && $0.pid != before.pid && portAcceptsConnections($0.port)
            }
            output(inv, server, "“\(server.name)” is running on port \(server.port).")
        case "stop":
            let stopping = try one(Request(command: "stop", server: inv.target))
            let server = try wait(for: stopping.id, timeout: 30, what: "stop") { $0.state == "stopped" || $0.state == "failed" }
            output(inv, server, "“\(server.name)” stopped.")
        case "delete":
            let server = try one(Request(command: "status", server: inv.target))
            if inv.options["--yes"] == nil {
                guard isatty(STDIN_FILENO) != 0 else {
                    throw Failure(message: "delete needs --yes when not run interactively.", code: Failure.usage)
                }
                print("Remove “\(server.name)” (port \(server.port))? Its data directory is kept. [y/N] ", terminator: "")
                guard readLine()?.lowercased().hasPrefix("y") == true else { throw Failure(message: "Cancelled.") }
            }
            _ = try one(Request(command: "delete", server: server.id))
            output(inv, server, "Removed “\(server.name)”. Its data directory is kept at \(server.dataDirectory).")
        case "url":
            let url = try send(Request(command: "url", server: inv.target, user: inv.options["--user"])).url ?? ""
            inv.json ? printJSON(["url": url]) : print(url)
        case "logs":
            let server = try one(Request(command: "status", server: inv.target))
            try logs(server, lines: Int(inv.options["--lines"] ?? "50") ?? 50, follow: inv.options["--follow"] != nil, json: inv.json)
        default:
            throw Failure(message: "Unknown command \(inv.command).", code: Failure.usage)
        }
    }

    /// Polls the server's status until `done` says so, or fails after `timeout` seconds.
    private static func wait(for server: String, timeout: TimeInterval, what: String,
                             until done: (ServerInfo) throws -> Bool) throws -> ServerInfo {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            guard let info = try send(Request(command: "status", server: server)).servers?.first else {
                throw Failure(message: "The server was removed.")
            }
            if try done(info) { return info }
            if Date() > deadline {
                throw Failure(message: "“\(info.name)” didn't \(what) within \(Int(timeout))s (state: \(info.state)). "
                              + "See `\(name) logs \(info.port)`.")
            }
            usleep(200_000)
        }
    }

    // MARK: Talking to the app

    private static func send(_ request: Request) throws -> Response {
        let port = try appPort()
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(port, 0, try JSONEncoder().encode(request) as CFData, 5, 30,
                                              CFRunLoopMode.defaultMode.rawValue, &reply)
        guard status == kCFMessagePortSuccess, let data = reply?.takeRetainedValue() as Data? else {
            throw Failure(message: "Valkey.app didn't answer (error \(status)).", code: Failure.unreachable)
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        if let error = response.error { throw Failure(message: error, code: response.exitCode ?? Failure.failed) }
        return response
    }

    private static var cachedPort: CFMessagePort?

    /// The app's message port, launching the app hidden in the background if it isn't running.
    private static func appPort() throws -> CFMessagePort {
        if let port = cachedPort ?? CFMessagePortCreateRemote(nil, portName as CFString) {
            cachedPort = port
            return port
        }
        // This executable is Valkey.app/Contents/MacOS/Valkey; open that copy of the app if we can.
        let exe = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-j"] + (app.pathExtension == "app" ? [app.path] : ["-b", "app.valkey.Valkey"])
        FileHandle.standardError.write(Data("Starting Valkey.app…\n".utf8))
        try? open.run()
        open.waitUntilExit()
        for _ in 0..<150 {
            if let port = CFMessagePortCreateRemote(nil, portName as CFString) {
                cachedPort = port
                return port
            }
            usleep(100_000)
        }
        throw Failure(message: "Couldn't reach Valkey.app. Open it once (it must be allowed to run on first launch), then retry.",
                      code: Failure.unreachable)
    }

    /// True if something listens on 127.0.0.1:port.
    static func portAcceptsConnections(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { _ = Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port)).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }

    // MARK: Logs

    private struct LogOutput: Encodable { var logFile: String; var lines: [String] }

    private static func logs(_ server: ServerInfo, lines: Int, follow: Bool, json: Bool) throws {
        guard let handle = FileHandle(forReadingAtPath: server.logFile) else {
            if follow { throw Failure(message: "No log yet at \(server.logFile).") }
            return json ? printJSON(LogOutput(logFile: server.logFile, lines: [])) : ()
        }
        let tail = lastLines(of: String(decoding: handle.readDataToEndOfFile(), as: UTF8.self), lines)
        if json && !follow {
            return printJSON(LogOutput(logFile: server.logFile, lines: tail))
        }
        func emit(_ line: String) { json ? printJSON(line) : print(line) }
        tail.forEach(emit)
        guard follow else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        var partial = ""
        while true {
            let data = handle.readDataToEndOfFile()
            if data.isEmpty { usleep(250_000); continue }
            var text = partial + String(decoding: data, as: UTF8.self)
            if let end = text.lastIndex(of: "\n") {
                partial = String(text[text.index(after: end)...])
                text = String(text[..<end])
                text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).forEach(emit)
            } else {
                partial = text
            }
        }
    }

    /// The last `n` lines of `text`, without the trailing newline's empty line.
    static func lastLines(of text: String, _ n: Int) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return Array(lines.suffix(n))
    }

    // MARK: Output

    private static func output(_ inv: Invocation, _ server: ServerInfo, _ message: String? = nil) {
        if inv.json { return printJSON(server) }
        if let message { return print(message) }
        let rows: [(String, String?)] = [
            ("Name", server.name), ("State", server.state + (server.pid.map { " (pid \($0))" } ?? "")),
            ("Port", "\(server.port)"), ("Version", server.version),
            ("Modules", server.modules.isEmpty ? nil : server.modules.joined(separator: ", ")),
            ("Auto-start", server.startAutomatically ? "yes" : "no"), ("Data", server.dataDirectory),
            ("Log", server.logFile), ("Failure", server.failure), ("ID", server.id),
        ]
        for case let (label, value?) in rows { print("\(label):".padding(toLength: 12, withPad: " ", startingAt: 0) + value) }
    }

    private static func output(_ inv: Invocation, _ servers: [ServerInfo]) {
        if inv.json { return printJSON(servers) }
        if servers.isEmpty { return print("No servers. Create one with `\(name) create`.") }
        print(table([["NAME", "STATE", "PORT", "VERSION", "ID"]]
                    + servers.map { [$0.name, $0.state, "\($0.port)", $0.version, $0.id] }))
    }

    static func table(_ rows: [[String]]) -> String {
        let widths = rows[0].indices.map { i in rows.map { $0[i].count }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { i, cell in i == row.count - 1 ? cell : cell.padding(toLength: widths[i] + 2, withPad: " ", startingAt: 0) }
                .joined()
        }.joined(separator: "\n")
    }

    private static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self))
    }

}
