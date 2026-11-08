import Foundation

/// `valkey-app`, the command-line interface. It is the app's own executable run under that name
/// (Homebrew links it as `valkey-app`), so it ships and updates with the app.
///
/// The CLI never touches servers or settings itself: it sends each parsed command to the running app
/// over a local CFMessagePort (see CLIServer.swift), launching the app in the background if needed,
/// so the app stays the only owner of the server list, settings and server processes.
/// Keep it at parity with the UI (see AGENTS.md and app/CLI.md).
/// This file is Foundation-only so Tests/CLITests.swift can compile it standalone.
enum CLI {
    static let portName = "app.valkey.Valkey.cli"
    static let name = "valkey-app"

    /// The process was started as `valkey-app` (via a symlink) or with a CLI command as its first argument.
    static func isInvocation(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        if (first as NSString).lastPathComponent == name { return true }
        guard arguments.count > 1 else { return false }
        return (specs.map(\.name) + aliases.keys).contains { $0.split(separator: " ")[0] == arguments[1] }
            || ["-h", "--help", "--version"].contains(arguments[1])
    }

    // MARK: Shapes shared with the app (the --json schema; see app/CLI.md)

    struct ServerInfo: Codable, Equatable {
        struct User: Codable, Equatable { var name: String; var readOnly: Bool; var password: String? }
        struct Module: Codable, Equatable {
            var name: String
            var title: String
            var status: String      // installed, will-download, unavailable
            var version: String?
        }
        var id: String
        var name: String
        var version: String
        var port: Int
        var state: String           // running, stopping, stopped, failed
        var pid: Int32?
        var failure: String?
        var startAutomatically: Bool
        var autoRestart: Bool
        var persistence: Bool
        var maxMemory: String?
        var evictionPolicy: String
        var hasPassword: Bool
        var password: String?       // only with --show-secrets
        var users: [User]
        var modules: [Module]
        var dataDirectory: String
        var configFile: String
        var logFile: String
    }

    /// An error with the exit code to leave with.
    struct Failure: Error, Equatable {
        static let failed: Int32 = 1, usage: Int32 = 2, notFound: Int32 = 3, unreachable: Int32 = 4
        var message: String
        var code: Int32 = failed
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
        var json = arguments.prefix { $0 != "cli" }.contains("--json")
        do {
            if arguments == ["--version"] || arguments == ["-V"] {
                let plist = appBundle.flatMap { NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist")) }
                print("\(name) \(plist?["CFBundleShortVersionString"] as? String ?? "(not in an app bundle)")")
                return 0
            }
            if arguments.first == "__complete" {   // hidden: called by the completion scripts on Tab
                for (word, help) in completions(for: Array(arguments.dropFirst()), servers: savedServers()) {
                    print(help.isEmpty ? word : "\(word)\t\(help)")
                }
                return 0
            }
            var inv = try parse(arguments)
            json = inv.json
            if inv.command == "help" {
                if json { printJSON(inv.args.isEmpty ? specs : specs.filter { $0.name == inv.args[0] }) }
                else { print(inv.args.isEmpty ? overview : help(for: spec(inv.args[0])!)) }
                return 0
            }
            if inv.command == "completion" {
                guard let script = completionScript(for: inv.args[0]) else {
                    throw Failure(message: "Unknown shell “\(inv.args[0])”; use bash, zsh or fish.", code: Failure.usage)
                }
                print(script)
                return 0
            }
            try prepare(&inv)
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

    /// Resolves what only the CLI knows: passwords from stdin and paths relative to its directory.
    private static func prepare(_ inv: inout Invocation) throws {
        if inv.options["--password"] == "-" {
            var text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
            inv.options["--password"] = text
        }
        if let dir = inv.options["--data-dir"] {
            let path = (dir as NSString).expandingTildeInPath
            inv.options["--data-dir"] = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
                .standardizedFileURL.path
        }
    }

    private static func execute(_ inv: Invocation) throws {
        switch inv.command {
        case "start", "restart":
            let before = try server(inv.args[0])
            if before.state == "stopped" || before.state == "failed", portAcceptsConnections(before.port) {
                throw Failure(message: "Port \(before.port) is already in use by another process.")
            }
            if inv.command == "start", before.state == "running" {
                return output(inv, ["result": encodeJSON(before), "message": "“\(before.name)” is already running on port \(before.port)."])
            }
            _ = try request(Invocation(command: inv.command, args: [before.id]))
            let after = try wait(for: before.id, timeout: 15, what: "start accepting connections") {
                if $0.state == "failed" { throw Failure(message: "“\($0.name)” failed to start: \($0.failure ?? "see its log").") }
                return $0.state == "running" && $0.pid != before.pid && portAcceptsConnections($0.port)
            }
            output(inv, ["result": encodeJSON(after), "message": "“\(after.name)” is running on port \(after.port)."])
        case "stop":
            let target = try server(inv.args[0])
            _ = try request(Invocation(command: "stop", args: [target.id]))
            let after = try wait(for: target.id, timeout: 30, what: "stop") { $0.state == "stopped" || $0.state == "failed" }
            output(inv, ["result": encodeJSON(after), "message": "“\(after.name)” stopped."])
        case "delete":
            let target = try server(inv.args[0])
            if inv.options["--yes"] == nil {
                guard isatty(STDIN_FILENO) != 0 else {
                    throw Failure(message: "delete needs --yes when not run interactively.", code: Failure.usage)
                }
                writePrompt("Remove “\(target.name)” (port \(target.port))? Its data directory is kept. [y/N] ")
                guard readLine()?.lowercased().hasPrefix("y") == true else { throw Failure(message: "Cancelled.") }
            }
            output(inv, try request(Invocation(command: "delete", args: [target.id])))
        case "logs":
            try logs(try server(inv.args[0]), lines: Int(inv.options["--lines"] ?? "50") ?? 50,
                     follow: inv.options["--follow"] != nil, filter: inv.options["--filter"] ?? "", json: inv.json)
        case "cli":
            let info = try request(Invocation(command: "cli-info", args: [inv.args[0]]))["result"] as? [String: Any] ?? [:]
            guard let path = info["path"] as? String, let port = info["port"] as? Int else { throw Failure(message: "Valkey.app sent no valkey-cli.") }
            if let password = info["password"] as? String { setenv("REDISCLI_AUTH", password, 1) }
            let argv = [path, "-p", "\(port)"] + inv.args.dropFirst()
            var cargs = argv.map { strdup($0) } + [nil]
            execv(path, &cargs)
            throw Failure(message: "Couldn't run \(path): \(String(cString: strerror(errno))).")
        case "app" where remotePort() == nil:
            // Report without launching the app, so agents can check whether it's running.
            let plist = NSDictionary(contentsOf: appBundle?.appendingPathComponent("Contents/Info.plist") ?? URL(fileURLWithPath: "/"))
            let info: [String: Any] = ["running": false, "appPath": appBundle?.path as Any? ?? NSNull(),
                                       "version": plist?["CFBundleShortVersionString"] ?? NSNull(),
                                       "build": plist?["CFBundleVersion"] ?? NSNull()]
            output(inv, ["result": info])
        case "app open":
            try runOpen(hidden: false)
            output(inv, ["result": ["ok": true], "message": "Opened Valkey.app."])
        case "app quit":
            guard remotePort() != nil else { return output(inv, ["result": ["ok": true], "message": "Valkey.app isn't running."]) }
            let reply = try request(inv)
            cachedPort = nil
            for _ in 0..<600 where remotePort() != nil { usleep(100_000) }   // servers stop gracefully first
            output(inv, reply)
        default:
            var reply = try request(inv)
            // A settings change restarts a running server (`set`, `user …`); wait as `restart` does.
            if let result = reply["result"] as? [String: Any],
               result["state"] as? String == "stopping", let id = result["id"] as? String {
                let pid = (result["pid"] as? Int).map(Int32.init)
                let after = try wait(for: id, timeout: 30, what: "restart") {
                    if $0.state == "failed" { throw Failure(message: "“\($0.name)” failed to restart: \($0.failure ?? "see its log").") }
                    return $0.state == "stopped" || ($0.state == "running" && $0.pid != pid && portAcceptsConnections($0.port))
                }
                reply["result"] = encodeJSON(after)
            }
            output(inv, reply)
        }
    }

    private static func server(_ query: String) throws -> ServerInfo {
        let result = try request(Invocation(command: "status", args: [query]))["result"] ?? [:]
        return try JSONDecoder().decode(ServerInfo.self, from: JSONSerialization.data(withJSONObject: result))
    }

    /// Polls the server's status until `done` says so, or fails after `timeout` seconds.
    private static func wait(for id: String, timeout: TimeInterval, what: String,
                             until done: (ServerInfo) throws -> Bool) throws -> ServerInfo {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let info = try server(id)
            if try done(info) { return info }
            if Date() > deadline {
                throw Failure(message: "“\(info.name)” didn't \(what) within \(Int(timeout))s (state: \(info.state)). "
                              + "See `\(name) logs \(info.port)`.")
            }
            usleep(200_000)
        }
    }

    // MARK: Talking to the app

    /// Sends a command and returns the app's reply ({"result", "message", "note"}), waiting for jobs
    /// (downloads, stats) the app runs in the background.
    private static func request(_ inv: Invocation) throws -> [String: Any] {
        var reply = try send(inv)
        var announced = false
        while let job = reply["job"] as? String {
            if !announced, isatty(STDERR_FILENO) != 0 {
                FileHandle.standardError.write(Data("Working…\n".utf8))
                announced = true
            }
            usleep(250_000)
            reply = try send(Invocation(command: "job", args: [job]))
        }
        return reply
    }

    private static func send(_ inv: Invocation) throws -> [String: Any] {
        let port = try appPort()
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(port, 0, try JSONEncoder().encode(inv) as CFData, 5, 30,
                                              CFRunLoopMode.defaultMode.rawValue, &reply)
        guard status == kCFMessagePortSuccess, let data = reply?.takeRetainedValue() as Data?,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "Valkey.app didn't answer (error \(status)).", code: Failure.unreachable)
        }
        if let error = object["error"] as? String {
            throw Failure(message: error, code: (object["exitCode"] as? NSNumber)?.int32Value ?? Failure.failed)
        }
        return object
    }

    private static var cachedPort: CFMessagePort?

    private static func remotePort() -> CFMessagePort? {
        CFMessagePortCreateRemote(nil, portName as CFString)
    }

    /// This executable is Valkey.app/Contents/MacOS/Valkey (maybe via a symlink); nil if it isn't in a bundle.
    private static var appBundle: URL? {
        let exe = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }

    /// Opens the app and waits (up to 15 s) until it accepts commands, which it does once it has
    /// finished launching; the first launch of a new copy can take seconds while macOS checks it.
    @discardableResult
    private static func runOpen(hidden: Bool) throws -> CFMessagePort {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = (hidden ? ["-g", "-j"] : []) + (appBundle.map { [$0.path] } ?? ["-b", "app.valkey.Valkey"])
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else {
            throw Failure(message: "Couldn't open Valkey.app (is it installed?).", code: Failure.unreachable)
        }
        for _ in 0..<150 {
            if let port = remotePort() {
                cachedPort = port
                return port
            }
            usleep(100_000)
        }
        throw Failure(message: "Couldn't reach Valkey.app. Open it once (it must be allowed to run on first launch), then retry.",
                      code: Failure.unreachable)
    }

    /// The app's message port, launching the app hidden in the background if it isn't running.
    private static func appPort() throws -> CFMessagePort {
        if let port = cachedPort ?? remotePort() {
            cachedPort = port
            return port
        }
        FileHandle.standardError.write(Data("Starting Valkey.app…\n".utf8))
        return try runOpen(hidden: true)
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

    private static func logs(_ server: ServerInfo, lines: Int, follow: Bool, filter: String, json: Bool) throws {
        func keep(_ line: String) -> Bool { filter.isEmpty || line.localizedCaseInsensitiveContains(filter) }
        guard let handle = FileHandle(forReadingAtPath: server.logFile) else {
            if follow { throw Failure(message: "No log yet at \(server.logFile).") }
            return json ? printJSON(LogOutput(logFile: server.logFile, lines: [])) : ()
        }
        defer { try? handle.close() }
        let tail = readLogTail(handle, lines: lines, filter: filter)
        if json && !follow {
            return printJSON(LogOutput(logFile: server.logFile, lines: tail))
        }
        func emit(_ line: String) { guard keep(line) else { return }; json ? printJSON(line) : print(line) }
        tail.forEach(emit)
        guard follow else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        var partial = Data()
        while true {
            let data = try handle.read(upToCount: 65_536) ?? Data()
            if data.isEmpty { usleep(250_000); continue }
            partial.append(data)
            if let end = partial.lastIndex(of: 10) {
                // Decode only complete lines, preserving UTF-8 split across reads.
                let text = String(decoding: partial[..<end], as: UTF8.self)
                text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).forEach(emit)
                partial = Data(partial[partial.index(after: end)...])
            }
        }
    }

    /// Prompts belong on stderr so redirected stdout remains machine-readable.
    static func writePrompt(_ text: String, to handle: FileHandle = .standardError) {
        handle.write(Data(text.utf8))
    }

    /// Scan backwards until enough matching lines have been found. Memory is bounded by the
    /// requested output, a chunk and one line, even when the log has grown for months.
    /// Leave the handle at the captured EOF so following doesn't lose subsequent writes.
    static func readLogTail(_ handle: FileHandle, lines: Int, filter: String = "", chunkSize: Int = 65_536) -> [String] {
        let end = handle.seekToEndOfFile()
        defer { handle.seek(toFileOffset: end) }
        guard lines > 0 else { return [] }
        precondition(chunkSize > 0)
        var offset = end
        var reversedLine: [UInt8] = []
        var result: [String] = []
        var atEnd = true
        func appendLine() {
            let line = String(decoding: reversedLine.reversed(), as: UTF8.self)
            if filter.isEmpty || line.localizedCaseInsensitiveContains(filter) { result.append(line) }
            reversedLine.removeAll(keepingCapacity: true)
        }
        while offset > 0 {
            let count = Int(min(offset, UInt64(chunkSize)))
            offset -= UInt64(count)
            handle.seek(toFileOffset: offset)
            let data = handle.readData(ofLength: count)
            for byte in data.reversed() {
                if byte == 10 {
                    if !atEnd { appendLine() }
                    if result.count == lines { return result.reversed() }
                } else {
                    reversedLine.append(byte)
                }
                atEnd = false
            }
        }
        if end > 0, result.count < lines { appendLine() }
        return result.reversed()
    }

    /// The last `n` lines of `text`, without the trailing newline's empty line.
    static func lastLines(of text: String, _ n: Int) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return Array(lines.suffix(n))
    }

    // MARK: Output

    /// Columns for commands that list things; other results print as indented `key: value` lines.
    static let columns: [String: [String]] = [
        "list": ["name", "state", "port", "version", "id"],
        "status": ["name", "state", "port", "version", "id"],
        "versions": ["version", "installed", "available", "usedBy"],
        "versions refresh": ["version", "installed", "available", "usedBy"],
        "modules": ["id", "title", "version", "valkey", "installed", "usedBy"],
    ]

    /// Prints a reply: its result as JSON, or else its message (or the rendered result) for people.
    private static func output(_ inv: Invocation, _ reply: [String: Any]) {
        let result = reply["result"]
        if inv.json { return printJSON(any: result ?? [String: Any]()) }
        if let note = reply["note"] as? String { FileHandle.standardError.write(Data("\(note)\n".utf8)) }
        if let message = reply["message"] as? String { return print(message) }
        if let rows = result as? [[String: Any]], let columns = columns[inv.command] {
            return print(rows.isEmpty ? "None." : table([columns.map { $0.uppercased() }] + rows.map { row in columns.map { text(row[$0]) } }))
        }
        render(result ?? NSNull()).forEach { print($0) }
    }

    static func text(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return "-"
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): return n.boolValue ? "yes" : "no"
        case let a as [Any]: return a.isEmpty ? "-" : a.map { text($0) }.joined(separator: ", ")
        case let s as String: return s
        default: return "\(value!)"
        }
    }

    /// Indented `key: value` lines; arrays of objects become `-` items.
    static func render(_ value: Any, indent: String = "") -> [String] {
        if let dict = value as? [String: Any] {
            return dict.keys.sorted().flatMap { key -> [String] in
                switch dict[key] {
                case let nested as [String: Any]:
                    return ["\(indent)\(key):"] + render(nested, indent: indent + "  ")
                case let items as [[String: Any]] where !items.isEmpty:
                    return ["\(indent)\(key):"] + items.flatMap { item -> [String] in
                        var lines = render(item, indent: indent + "    ")
                        if !lines.isEmpty { lines[0] = indent + "  - " + String(lines[0].dropFirst(indent.count + 4)) }
                        return lines
                    }
                default:
                    return ["\(indent)\(key): \(text(dict[key]))"]
                }
            }
        }
        if let items = value as? [[String: Any]] {
            return render(["items": items], indent: indent)
        }
        return [indent + text(value)]
    }

    static func table(_ rows: [[String]]) -> String {
        let widths = rows[0].indices.map { i in rows.map { $0[i].count }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { i, cell in i == row.count - 1 ? cell : cell.padding(toLength: widths[i] + 2, withPad: " ", startingAt: 0) }
                .joined()
        }.joined(separator: "\n")
    }

    private static func encodeJSON<T: Encodable>(_ value: T) -> Any {
        (try? JSONEncoder().encode(value)).flatMap { try? JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) } ?? NSNull()
    }

    private static func printJSON<T: Encodable>(_ value: T) {
        printJSON(any: encodeJSON(value))
    }

    private static func printJSON(any value: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])) ?? Data()
        print(String(decoding: data, as: UTF8.self))
    }
}
