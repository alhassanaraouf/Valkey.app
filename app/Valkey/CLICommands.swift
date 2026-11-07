import Foundation

/// Every `valkey-app` command, its arguments, options and examples. Parsing and all help output
/// (`help`, `help <command>`, `<command> --help`, `help --json`) come from this one list, so a new
/// command or option is documented by adding it here. Foundation-only for Tests/CLITests.swift.
extension CLI {
    struct Arg: Encodable {
        var name: String
        var required = true
        var variadic = false
        var help: String
    }

    struct Option: Encodable {
        enum Kind: String, Encodable { case flag, text, number, toggle }
        var name: String
        var short: String?
        var kind: Kind
        var value: String?          // placeholder shown in help, e.g. "N"; nil for flags
        var help: String

        init(_ name: String, short: String? = nil, _ kind: Kind, _ value: String? = nil, _ help: String) {
            self.name = name; self.short = short; self.kind = kind; self.help = help
            self.value = value ?? (kind == .toggle ? "on|off" : kind == .number ? "N" : nil)
        }
    }

    struct Example: Encodable { var command: String; var description: String }

    struct Spec: Encodable {
        var name: String
        var group: String
        var args: [Arg] = []
        var options: [Option] = []
        var summary: String
        var details: String?
        var examples: [Example]

        var usage: String {
            let args = args.map { a in (a.required ? "<\(a.name)>" : "[\(a.name)]") + (a.variadic ? "…" : "") }
            return ([CLI.name, name] + args + (options.isEmpty ? [] : ["[options]"])).joined(separator: " ")
        }
        var argCount: ClosedRange<Int> {
            args.filter(\.required).count...(args.last?.variadic == true ? Int.max : args.count)
        }
        enum CodingKeys: String, CodingKey { case name, group, usage, args, options, summary, details, examples }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name); try c.encode(group, forKey: .group); try c.encode(usage, forKey: .usage)
            try c.encode(args, forKey: .args); try c.encode(options, forKey: .options); try c.encode(summary, forKey: .summary)
            try c.encodeIfPresent(details, forKey: .details); try c.encode(examples, forKey: .examples)
        }
    }

    private static func ex(_ command: String, _ description: String) -> Example { Example(command: "\(name) \(command)", description: description) }

    // MARK: Arguments and options shared by several commands

    private static let serverArg = Arg(name: "server", help: "The server's name, port or id (see `list`). Use the port or id if two servers share a name.")
    private static let userArg = Arg(name: "user", help: "ACL user name: no spaces, and not “default” (the default user's password is set with `set --password`).")

    private static let showSecrets = Option("--show-secrets", .flag, "Include passwords in the output. They are hidden otherwise.")
    private static let settings: [Option] = [
        Option("--name", .text, "NAME", "Display name."),
        Option("--port", .number, "TCP port on 127.0.0.1 (1–65535); no two servers can share one."),
        Option("--version", .text, "V", "Valkey version, e.g. 9.1.2 (see `versions`). On create, any listed version works and is downloaded if needed. On set, only an installed version that isn't older; an upgrade can't be undone."),
        Option("--auto-start", .toggle, "Start this server when Valkey.app opens (default off)."),
        Option("--auto-restart", .toggle, "Restart it if it crashes (default on). It is left stopped after 3 crashes within a minute."),
        Option("--persistence", .toggle, "Save data to disk so it survives restarts (default on). off keeps data in memory only."),
        Option("--max-memory", .text, "SIZE|none", "Memory limit such as 256mb or 2gb; none removes the limit (default)."),
        Option("--eviction-policy", .text, "POLICY", "What happens when max memory is reached: noeviction (default; writes fail), allkeys-lru, allkeys-lfu, allkeys-random, volatile-lru, volatile-lfu, volatile-random or volatile-ttl."),
        Option("--password", .text, "PW|-", "Password for the default user. - reads it from stdin, which keeps it out of shell history; \"\" removes it."),
        Option("--modules", .text, "LIST|none", "Replace the enabled modules with this comma-separated list of names from `modules`; none turns them all off."),
        Option("--enable-module", .text, "NAME", "Turn one module on, e.g. json. It is downloaded if needed."),
        Option("--disable-module", .text, "NAME", "Turn one module off. Data saved while it was on may need it to load."),
    ]
    private static let restartNote = "A running server restarts when its port, version, modules, memory settings, persistence or passwords change."

    // MARK: Commands

    static let specs: [Spec] = [
        // Servers
        Spec(name: "list", group: "Servers", options: [showSecrets],
             summary: "List all servers with their state.",
             details: "The table shows name, state, port, version and id. --json returns every field of every server; see `show`.",
             examples: [ex("list", "Table of servers."), ex("list --json", "Every server with all of its settings, as JSON.")]),
        Spec(name: "show", group: "Servers", args: [serverArg], options: [showSecrets],
             summary: "Show one server: state, every setting, users, modules and file paths.",
             details: "state is running, stopping, stopped or failed; failure holds the error. Each module's status is installed, will-download or unavailable.",
             examples: [ex("show cache", "Everything about the server named cache."), ex("show 6379 --json", "The same as JSON, by port.")]),
        Spec(name: "status", group: "Servers", args: [Arg(name: "server", required: false, help: serverArg.help)], options: [showSecrets],
             summary: "Same as `list` without a server, and as `show` with one.",
             examples: [ex("status", "All servers."), ex("status cache", "One server.")]),
        Spec(name: "create", group: "Servers", args: [Arg(name: "name", required: false, help: "Display name; the same as --name. Default: “Valkey <version>”.")],
             options: settings + [Option("--data-dir", .text, "PATH", "Where its data, valkey.conf and valkey.log live. Default: ~/Library/Application Support/Valkey/var-<port>.")],
             summary: "Add a server. It isn't started; run `start` next.",
             details: "Defaults: the next free port from 6379 and the newest Valkey version. The version and any modules are downloaded first if they aren't installed yet.",
             examples: [ex("create", "A server on the next free port with the newest version."),
                        ex("create cache --port 6390", "A server named cache on port 6390."),
                        ex("create sessions --version 9.1.2 --max-memory 256mb --eviction-policy allkeys-lru", "A size-capped cache that evicts least-recently-used keys."),
                        ex("create docs --enable-module json", "A server with the JSON module."),
                        ex("create secure --password -", "Read the password from stdin, e.g. `echo \"$PW\" | valkey-app create secure --password -`.")]),
        Spec(name: "set", group: "Servers", args: [serverArg], options: settings,
             summary: "Change a server's settings; only the options you pass change.",
             details: restartNote,
             examples: [ex("set cache --max-memory 512mb", "Raise the memory limit."),
                        ex("set cache --auto-start on --auto-restart on", "Start it with the app and restart it after a crash."),
                        ex("set cache --name hot-cache --port 6391", "Rename it and move it to another port."),
                        ex("set cache --password \"\"", "Remove the default user's password."),
                        ex("set cache --enable-module bloom", "Turn the bloom module on.")]),
        Spec(name: "start", group: "Servers", args: [serverArg],
             summary: "Start a server and wait until it accepts connections (up to 15 seconds).",
             details: "Fails early if another process already holds the port, and reports the server's error if it can't start.",
             examples: [ex("start cache", "Start the server named cache."), ex("start 6379 --json", "Start by port; prints the server as JSON.")]),
        Spec(name: "stop", group: "Servers", args: [serverArg],
             summary: "Stop a server gracefully and wait until it has exited (up to 30 seconds).",
             details: "Valkey saves its data to disk first if persistence is on.",
             examples: [ex("stop cache", "Stop the server named cache.")]),
        Spec(name: "restart", group: "Servers", args: [serverArg],
             summary: "Restart a server (or start it if it's stopped) and wait until it accepts connections.",
             details: "Use it after editing valkey.conf (`open <server> config`).",
             examples: [ex("restart cache", "Restart the server named cache.")]),
        Spec(name: "delete", group: "Servers", args: [serverArg], options: [Option("--yes", short: "-y", .flag, "Don't ask for confirmation. Required when not run in a terminal (scripts, agents).")],
             summary: "Remove a server from Valkey.app. Its data directory stays on disk.",
             details: "The server is stopped first. Its passwords are deleted from the Keychain.",
             examples: [ex("delete cache", "Asks before removing."), ex("delete cache --yes", "Removes without asking.")]),
        Spec(name: "logs", group: "Servers", args: [serverArg],
             options: [Option("--lines", short: "-n", .number, "Number of lines to print (default 50)."),
                       Option("--follow", short: "-f", .flag, "Keep printing new lines until you press Ctrl-C."),
                       Option("--filter", .text, "TEXT", "Only lines that contain TEXT (case-insensitive).")],
             summary: "Print a server's log (valkey.log).",
             details: "With --json the result is {logFile, lines}; with -f --json each new line prints as a JSON string.",
             examples: [ex("logs cache", "The last 50 lines."), ex("logs cache -n 200 --filter error", "Errors among the last 200 matching lines."),
                        ex("logs cache -f", "Follow the log live.")]),
        Spec(name: "stats", group: "Servers", args: [serverArg],
             summary: "Live numbers from INFO: memory, ops/s, clients, keys and hit rate. The server must be running.",
             examples: [ex("stats cache", "Current numbers."), ex("stats cache --json", "As JSON: memory, memoryBytes, ops, clients, keys, hitRate.")]),
        Spec(name: "url", group: "Servers", args: [serverArg],
             options: [Option("--user", .text, "NAME", "The URL for this ACL user instead of the default user."), showSecrets],
             summary: "Print the connection URL, e.g. valkey://127.0.0.1:6379.",
             details: "If a password is set it shows as **** unless you add --show-secrets.",
             examples: [ex("url cache", "URL for the default user."), ex("url cache --user app --show-secrets", "URL with user app's real password.")]),
        Spec(name: "cli", group: "Servers", args: [serverArg, Arg(name: "valkey-cli args", required: false, variadic: true, help: "Arguments for valkey-cli, passed through unchanged. Without any, valkey-cli is interactive.")],
             summary: "Run the server's own valkey-cli, connected and authenticated.",
             details: "The password goes to valkey-cli in REDISCLI_AUTH, never on the command line. Options after <server> belong to valkey-cli.",
             examples: [ex("cli cache", "Interactive valkey-cli."), ex("cli cache SET greeting hello", "Run one command."),
                        ex("cli cache --scan --pattern 'user:*'", "Use any valkey-cli option.")]),
        Spec(name: "connect", group: "Servers", args: [serverArg],
             summary: "Open valkey-cli for a running server in your terminal app (Settings › Terminal).",
             examples: [ex("connect cache", "Opens a new terminal window.")]),
        Spec(name: "open", group: "Servers", args: [serverArg, Arg(name: "what", required: false, help: "config opens valkey.conf in your text editor, data opens the data directory in Finder (default), and log opens valkey.log.")],
             summary: "Open a server's valkey.conf, data directory or log.",
             details: "Changes to valkey.conf apply the next time the server restarts. `show` lists the paths if you'd rather edit the files yourself.",
             examples: [ex("open cache config", "Edit valkey.conf."), ex("open cache", "Show the data directory in Finder.")]),

        // ACL users
        Spec(name: "user add", group: "Users", args: [serverArg, userArg],
             options: [Option("--password", .text, "PW|-", "The user's password (required). - reads it from stdin."),
                       Option("--read-only", .toggle, "Read-only access: reads, connection and INFO commands only (default off: full access).")],
             summary: "Add an ACL user to a server.", details: restartNote,
             examples: [ex("user add cache app --password s3cret", "A user with full access."),
                        ex("user add cache reporter --password - --read-only on", "A read-only user; the password comes from stdin.")]),
        Spec(name: "user set", group: "Users", args: [serverArg, userArg],
             options: [Option("--password", .text, "PW|-", "New password. - reads it from stdin."),
                       Option("--read-only", .toggle, "Read-only access (on) or full access (off)."),
                       Option("--rename", .text, "NAME", "New user name.")],
             summary: "Change an ACL user; only the options you pass change.", details: restartNote,
             examples: [ex("user set cache app --read-only on", "Make app read-only."), ex("user set cache app --rename api", "Rename app to api.")]),
        Spec(name: "user remove", group: "Users", args: [serverArg, userArg],
             summary: "Remove an ACL user from a server.", details: restartNote,
             examples: [ex("user remove cache app", "Remove user app.")]),

        // Versions and modules
        Spec(name: "versions", group: "Versions and modules",
             summary: "List Valkey versions: installed ones and those available to download.",
             details: "Shows which servers use each version. installing is the download progress (0–1) while a download runs.",
             examples: [ex("versions", "Table of versions."), ex("versions --json", "With release date, size and progress.")]),
        Spec(name: "versions refresh", group: "Versions and modules",
             summary: "Reload the list of available versions and modules from valkey.app.",
             examples: [ex("versions refresh", "Check for new versions.")]),
        Spec(name: "versions install", group: "Versions and modules", args: [Arg(name: "version", help: "A version from `versions`, e.g. 9.1.2.")],
             summary: "Download and install a Valkey version (checksum-verified).",
             examples: [ex("versions install 9.1.2", "Install Valkey 9.1.2.")]),
        Spec(name: "versions remove", group: "Versions and modules", args: [Arg(name: "version", help: "An installed version that no server uses.")],
             summary: "Delete an installed Valkey version. Refused while a server uses it.",
             examples: [ex("versions remove 8.1.4", "Delete Valkey 8.1.4.")]),
        Spec(name: "modules", group: "Versions and modules",
             options: [Option("--valkey", .text, "V", "Only builds that work with this Valkey version, e.g. 9.1 or 9.1.2.")],
             summary: "List module builds (JSON, Bloom, Search, …), installed and available.",
             details: "Enable a module on a server with `set <server> --enable-module <name>`; it's downloaded automatically. Use the id column for `modules install` and `modules remove`.",
             examples: [ex("modules", "Every module build."), ex("modules --valkey 9.1.2", "Builds that work with Valkey 9.1.2.")]),
        Spec(name: "modules install", group: "Versions and modules", args: [Arg(name: "id", help: "A build id from the id column of `modules`.")],
             summary: "Download and install a module build ahead of time.",
             examples: [ex("modules install <id>", "Install that build.")]),
        Spec(name: "modules remove", group: "Versions and modules", args: [Arg(name: "id", help: "An installed build id from `modules`.")],
             summary: "Delete an installed module build. Refused while a server loads it.",
             examples: [ex("modules remove <id>", "Delete that build.")]),

        // App
        Spec(name: "app", group: "App",
             summary: "Show Valkey.app's version, whether it's running, and its settings.",
             details: "Unlike other commands, this doesn't launch the app; it reports running: false instead.",
             examples: [ex("app", "Version and settings."), ex("app --json", "As JSON, including the installed terminal apps.")]),
        Spec(name: "app set", group: "App",
             options: [Option("--menu-bar", .toggle, "Show the icon in the menu bar."),
                       Option("--open-at-login", .toggle, "Open Valkey.app when you log in. macOS may ask you to approve it in System Settings."),
                       Option("--terminal", .text, "BUNDLE-ID", "Terminal app used by `connect`, e.g. com.apple.Terminal; `app --json` lists the installed choices under terminals."),
                       Option("--auto-update", .toggle, "Check for Valkey.app updates automatically.")],
             summary: "Change Valkey.app's settings; only the options you pass change.",
             examples: [ex("app set --open-at-login on", "Start Valkey.app at login."), ex("app set --terminal com.mitchellh.ghostty", "Use Ghostty for `connect`.")]),
        Spec(name: "app link-cli", group: "App",
             summary: "Link valkey-cli in ~/Library/Application Support/Valkey/bin to the newest installed version.",
             details: "Add that folder to your PATH; `app` shows the exact line for your shell profile.",
             examples: [ex("app link-cli", "Create or update the link.")]),
        Spec(name: "app check-updates", group: "App",
             summary: "Check for a new Valkey.app. The result appears in the app's update window.",
             examples: [ex("app check-updates", "Check now.")]),
        Spec(name: "app open", group: "App",
             summary: "Open Valkey.app's main window.",
             examples: [ex("app open", "Bring up the window.")]),
        Spec(name: "app quit", group: "App",
             summary: "Quit Valkey.app. All servers stop gracefully first.",
             details: "Any other command launches the app again.",
             examples: [ex("app quit", "Stop every server and quit.")]),

        Spec(name: "help", group: "Help", args: [Arg(name: "command", required: false, variadic: true, help: "A command, e.g. create or user add.")],
             summary: "Show help for all commands or for one; --json prints this reference as JSON.",
             examples: [ex("help create", "Options and examples for create; the same as `create --help`."), ex("help --json", "Every command, argument and option as JSON.")]),
    ]

    static let globalOptions = [
        Option("--json", .flag, "Print the result as JSON on stdout. Errors print as {\"error\": \"…\"} with a non-zero exit code."),
        Option("--help", short: "-h", .flag, "Show help for the command."),
    ]

    static func spec(_ name: String) -> Spec? { specs.first { $0.name == name } }

    // MARK: Help text

    static var overview: String {
        var lines = ["\(name): control Valkey.app and its Valkey servers from the command line.", "",
                     "Usage: \(name) <command> [arguments] [options]"]
        var group = ""
        for s in specs {
            if s.group != group { group = s.group; lines += ["", "\(group):"] }
            let left = s.usage.dropFirst(name.count + 1).replacingOccurrences(of: " [options]", with: "")
            lines += wrap(s.summary, indent: 32, first: "  " + left.padding(toLength: max(left.count, 29), withPad: " ", startingAt: 0) + " ")
        }
        lines += ["",
                  "<server> is a server's name, port or id. Add --json to any command for JSON output.",
                  "Valkey.app is launched in the background if it isn't running.",
                  "Exit codes: 0 ok, 1 failed, 2 usage error, 3 not found, 4 Valkey.app unreachable.",
                  "",
                  "Run `\(name) help <command>` (or `\(name) <command> --help`) for options and examples."]
        return lines.joined(separator: "\n")
    }

    static func help(for s: Spec) -> String {
        var lines = ["\(name) \(s.name): \(s.summary)", "", "Usage: \(s.usage)"]
        if let details = s.details { lines += [""] + wrap(details, indent: 0) }
        func rows(_ title: String, _ items: [(String, String)]) {
            guard !items.isEmpty else { return }
            let width = min(max(items.map(\.0.count).max()!, 10), 28)
            lines += ["", "\(title):"]
            for (left, text) in items {
                lines += wrap(text, indent: width + 4, first: "  " + left.padding(toLength: max(left.count, width), withPad: " ", startingAt: 0) + "  ")
            }
        }
        rows("Arguments", s.args.map { ($0.name, $0.help) })
        rows("Options", (s.options + globalOptions).map { o in
            ([o.short, o.name].compactMap { $0 }.joined(separator: ", ") + (o.value.map { " \($0)" } ?? ""), o.help)
        })
        lines += ["", "Examples:"]
        for e in s.examples { lines += ["  \(e.command)"] + wrap(e.description, indent: 6) }
        return lines.joined(separator: "\n")
    }

    /// Word-wraps `text` to 100 columns; the first line starts with `first` (or the indent).
    static func wrap(_ text: String, indent: Int, first: String? = nil) -> [String] {
        var lines: [String] = [], line = first ?? String(repeating: " ", count: indent), empty = true
        for word in text.split(separator: " ") {
            if !empty && line.count + 1 + word.count > 100 {
                lines.append(line)
                line = String(repeating: " ", count: indent)
                empty = true
            }
            line += (empty ? "" : " ") + word
            empty = false
        }
        return lines + [line]
    }

    // MARK: Parsing

    /// A parsed command line; also the request sent to the app.
    struct Invocation: Codable, Equatable {
        var command: String
        var args: [String] = []
        var options: [String: String] = [:]
        var json = false
    }

    private static func usageError(_ message: String, _ s: Spec? = nil) -> Failure {
        let hint = s.map { "\nUsage: \($0.usage)\nRun `\(name) help \($0.name)` for details." } ?? "\nRun `\(name) help` for the list of commands."
        return Failure(message: message + hint, code: Failure.usage)
    }

    /// The command named by the first one or two words, and the words after it.
    private static func command(in words: [String]) -> (Spec, [String])? {
        if words.count >= 2, let s = spec("\(words[0]) \(words[1])") { return (s, Array(words.dropFirst(2))) }
        if let first = words.first, let s = spec(first) { return (s, Array(words.dropFirst())) }
        return nil
    }

    /// The closest name within two edits, for "did you mean".
    static func suggestion(for word: String, in names: [String]) -> String? {
        func distance(_ a: [Character], _ b: [Character]) -> Int {
            guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
            var row = Array(0...b.count)
            for i in 1...a.count {
                var prev = row[0]
                row[0] = i
                for j in 1...b.count {
                    let old = row[j]
                    row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                    prev = old
                }
            }
            return row[b.count]
        }
        return names.map { ($0, distance(Array(word), Array($0))) }.filter { $0.1 <= 2 }.min { $0.1 < $1.1 }?.0
    }

    static func parse(_ arguments: [String]) throws -> Invocation {
        if arguments.isEmpty { return Invocation(command: "help") }
        let allOptions = specs.flatMap(\.options)
        func option(_ key: String) -> Option? { allOptions.first { $0.name == key || $0.short == key } }

        // -h / --help anywhere shows help for the command named, except among valkey-cli's own
        // arguments (everything after `cli <server>`).
        var scope = arguments[...]
        if let i = arguments.firstIndex(of: "cli"),
           let server = arguments[(i + 1)...].firstIndex(where: { !$0.hasPrefix("-") }) { scope = arguments[..<server] }
        let isHelp = { (a: String) in a == "-h" || a == "--help" }
        let words = scope.prefix { !isHelp($0) }.filter { !$0.hasPrefix("-") }
        if scope.contains(where: isHelp) || words.first == "help" {
            let named = words.first == "help" ? Array(words.dropFirst()) : words
            let json = arguments.contains("--json")
            guard !named.isEmpty else { return Invocation(command: "help", json: json) }
            guard let (s, _) = command(in: named) else {
                throw usageError("No command “\(named.prefix(2).joined(separator: " "))”.")
            }
            return Invocation(command: "help", args: [s.name], json: json)
        }

        var positional: [String] = [], options: [String: String] = [:], json = false
        var rest = arguments[...]
        while let arg = rest.popFirst() {
            // Everything after `cli <server>` goes to valkey-cli untouched.
            if positional.first == "cli" && positional.count >= 2 { positional.append(arg); continue }
            if arg == "--json" { json = true; continue }
            guard arg.hasPrefix("-"), arg.count > 1 else { positional.append(arg); continue }
            let parts = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let opt = option(parts[0]) else {
                let hint = suggestion(for: parts[0], in: allOptions.map(\.name)).map { " Did you mean \($0)?" } ?? ""
                throw usageError("Unknown option \(parts[0]).\(hint)", command(in: positional)?.0)
            }
            if opt.kind == .flag {
                guard parts.count == 1 else { throw usageError("\(opt.name) doesn't take a value.", command(in: positional)?.0) }
                options[opt.name] = ""
                continue
            }
            guard let value = parts.count == 2 ? parts[1] : rest.popFirst() else {
                throw usageError("\(opt.name) needs a value (\(opt.value ?? "")).", command(in: positional)?.0)
            }
            options[opt.name] = value
        }
        guard !positional.isEmpty else { throw usageError("No command given.") }
        guard let (s, found) = command(in: positional), s.name != "help" else {
            let groups = Set(specs.compactMap { $0.name.contains(" ") ? String($0.name.split(separator: " ")[0]) : nil })
            if groups.contains(positional[0]) {
                let subs = specs.filter { $0.name.hasPrefix(positional[0] + " ") }.map { String($0.name.split(separator: " ")[1]) }
                throw usageError("\(positional[0]) needs one of: \(subs.joined(separator: ", ")).")
            }
            let hint = suggestion(for: positional[0], in: specs.map(\.name)).map { " Did you mean `\($0)`?" } ?? ""
            throw usageError("Unknown command “\(positional[0])”.\(hint)")
        }
        var args = found
        guard s.argCount.contains(args.count) else {
            let missing = s.args.filter(\.required).dropFirst(args.count).map { "<\($0.name)>" }
            throw usageError(args.count < s.argCount.lowerBound ? "\(s.name) needs \(missing.joined(separator: " "))."
                             : "Too many arguments for \(s.name).", s)
        }
        for (key, value) in options.sorted(by: { $0.key < $1.key }) {
            guard let opt = s.options.first(where: { $0.name == key }) else { throw usageError("\(s.name) doesn't take \(key).", s) }
            if opt.kind == .number, Int(value).map({ $0 >= 0 }) != true { throw usageError("\(key) must be a number.", s) }
            if opt.kind == .toggle, ConfigRules.bool(value) == nil { throw usageError("\(key) must be on or off.", s) }
        }
        if s.name == "create", let name = args.first {
            if options["--name"] != nil { throw usageError("Give the name once: as an argument or with --name.", s) }
            options["--name"] = name
            args = []
        }
        return Invocation(command: s.name, args: args, options: options, json: json)
    }
}
