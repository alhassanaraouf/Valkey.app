import AppKit

/// One Valkey server: its saved configuration plus the running process and its log.
@MainActor
final class ValkeyServer: ObservableObject, Identifiable {
    struct Config: Codable, Equatable {
        var id = UUID()
        var name: String
        var version: String          // an installed version, see VersionStore
        var port: Int
        var dataDirectory: String
        var startAutomatically = false
        /// Names of modules to load ("json", "bloom", …). Optional so configs saved before modules decode.
        var modules: [String]?
        /// Optional so configs saved before these settings decode; nil = Valkey's default.
        var maxMemory: String?          // "256mb"; nil = no limit
        var evictionPolicy: String?     // nil = noeviction
        var persistence: Bool?          // nil = on
        /// Password of the default user. Kept in the Keychain (see Secrets.swift), never in the saved JSON.
        var password: String?
        /// Extra ACL users; optional for old configs. Their passwords are in the Keychain too.
        var users: [User]?

        struct User: Codable, Equatable, Identifiable {
            var id = UUID()
            var name = ""
            var readOnly = false
            var password = ""
            private enum CodingKeys: String, CodingKey { case id, name, readOnly }
        }
        private enum CodingKeys: String, CodingKey {
            case id, name, version, port, dataDirectory, startAutomatically, modules, maxMemory, evictionPolicy, persistence, users
        }

        var accounts: [User] {
            get { users ?? [] }
            set { users = newValue.isEmpty ? nil : newValue }
        }

        var enabledModules: [String] {
            get { modules ?? [] }
            set { modules = newValue.isEmpty ? nil : newValue }
        }
    }

    nonisolated static let rootDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Valkey", isDirectory: true)
    @Published var config: Config {
        didSet {
            for gone in oldValue.accounts where !config.accounts.contains(where: { $0.id == gone.id }) {
                Keychain.set(config.userAccount(gone), nil)
            }
            onConfigChange?()
            if isRunning && (config.port != oldValue.port || config.version != oldValue.version
                             || config.enabledModules != oldValue.enabledModules
                             || config.maxMemory != oldValue.maxMemory
                             || config.evictionPolicy != oldValue.evictionPolicy
                             || config.persistence != oldValue.persistence
                             || config.password != oldValue.password
                             || config.users != oldValue.users) { restart() }
        }
    }
    /// True while the process is alive (including while it shuts down).
    @Published private(set) var isRunning = false
    @Published private(set) var isStopping = false
    @Published private(set) var failure: String?
    @Published private(set) var log = ""
    var onConfigChange: (() -> Void)?

    private var process: Process?
    private var restartPending = false
    private var onStopped: [() -> Void] = []

    nonisolated let id: UUID
    var dataDir: URL { URL(fileURLWithPath: config.dataDirectory, isDirectory: true) }
    var logURL: URL { dataDir.appendingPathComponent("valkey.log") }
    private var confURL: URL { dataDir.appendingPathComponent("valkey.conf") }
    private var pidURL: URL { dataDir.appendingPathComponent("valkey.pid") }
    private func binary(_ name: String) -> URL {
        VersionStore.shared.binary(name, version: config.version)
    }

    init(config: Config) {
        id = config.id
        self.config = config
        loadLogTail()
        stopOrphanedServer()
    }

    /// Creates the data directory, default config and log; sets `failure` and returns false if it can't.
    private func ensureDataDir() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: confURL.path),
               let def = Bundle.main.url(forResource: "valkey.conf.default", withExtension: nil) {
                try fm.copyItem(at: def, to: confURL)
            }
        } catch {
            failure = "Couldn't prepare the data directory \(dataDir.path): \(error.localizedDescription)"
            return false
        }
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        return true
    }

    private func loadLogTail() {
        guard let h = try? FileHandle(forReadingFrom: logURL) else { return }
        let size = h.seekToEndOfFile()
        h.seek(toFileOffset: size > 32_768 ? size - 32_768 : 0)
        appendLog(String(decoding: h.readDataToEndOfFile(), as: UTF8.self))
        try? h.close()
    }

    /// A server left behind by a crashed app still holds the port; shut it down gracefully.
    // ponytail: blocks launch up to 10s per orphan, crash recovery only; adopt the process instead if that matters.
    private func stopOrphanedServer() {
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              String(cString: path).hasSuffix("/valkey-server") else { return }
        kill(pid, SIGTERM)
        var waited = 0
        while kill(pid, 0) == 0 && waited < 100 { usleep(100_000); waited += 1 }
    }

    func start() {
        guard process == nil else { return }
        failure = nil
        let server = binary("valkey-server")
        guard FileManager.default.isExecutableFile(atPath: server.path) else {
            failure = "Valkey \(config.version) isn't installed. Install it from Versions…, or choose another version in Server Settings."
            return
        }
        // Refuse to start without an enabled module: data saved with it won't load without it.
        var moduleArgs: [String] = []
        for name in config.enabledModules {
            guard let module = VersionStore.shared.installedModule(name, for: config.version) else {
                failure = "The \(name) module isn't installed for Valkey \(VersionStore.line(of: config.version)). "
                    + "Open Server Settings to install it, or turn it off."
                return
            }
            moduleArgs += ["--loadmodule", VersionStore.shared.modulePath(module).path]
        }
        guard ensureDataDir() else { return }
        let p = Process()
        p.executableURL = server
        // Credentials go in on stdin, not the command line, where other users could read them with ps.
        let needsStdin = config.password != nil || !config.accounts.isEmpty
        // logfile "" = stdout, so startup errors (bad config, port in use) reach the log too.
        p.arguments = [needsStdin ? "-" : confURL.path, "--port", "\(config.port)", "--dir", dataDir.path,
                       "--pidfile", pidURL.path, "--logfile", "", "--daemonize", "no"] + moduleArgs
        if let m = config.maxMemory { p.arguments! += ["--maxmemory", m] }
        if let e = config.evictionPolicy { p.arguments! += ["--maxmemory-policy", e] }
        if config.persistence == false { p.arguments! += ["--appendonly", "no", "--save", ""] }
        let stdin = Pipe()
        if needsStdin { p.standardInput = stdin }

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let logFile = try? FileHandle(forWritingTo: logURL)
        logFile?.seekToEndOfFile()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                try? logFile?.close()
                return
            }
            logFile?.write(data)
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.appendLog(text) }
        }
        p.terminationHandler = { [weak self] p in
            DispatchQueue.main.async { self?.didExit(status: p.terminationStatus) }
        }

        do {
            try p.run()
            if needsStdin {
                var conf = "include \(confQuote(confURL.path))\n"
                if let pw = config.password { conf += "requirepass \(confQuote(pw))\n" }
                for u in config.accounts {
                    conf += "user \(confQuote(u.name)) on \(confQuote(">" + u.password)) ~* &* "
                        + (u.readOnly ? "+@read +@connection +info\n" : "+@all\n")
                }
                stdin.fileHandleForWriting.write(Data(conf.utf8))
                try? stdin.fileHandleForWriting.close()
            }
            process = p
            isRunning = true
        } catch {
            failure = "Failed to launch valkey-server: \(error.localizedDescription)"
        }
    }

    /// Sends SIGTERM (valkey saves and exits cleanly); `then` runs once the process has exited.
    func stop(then: (() -> Void)? = nil) {
        guard let p = process else { then?(); return }
        if let then { onStopped.append(then) }
        guard !isStopping else { return }
        isStopping = true
        p.terminate()
    }

    func restart() {
        guard process != nil else { return start() }
        restartPending = true
        stop()
    }

    private func didExit(status: Int32) {
        if !isStopping { failure = "Exited unexpectedly (status \(status)). See the log for details." }
        process = nil
        isRunning = false
        isStopping = false
        let callbacks = onStopped
        onStopped = []
        callbacks.forEach { $0() }
        if restartPending {
            restartPending = false
            start()
        }
    }

    private func appendLog(_ text: String) {
        log = (log + text)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(500)
            .joined(separator: "\n")
    }

    func openCLI() {
        // A .command file runs in any terminal app without needing Apple Events permission.
        let script = dataDir.appendingPathComponent("valkey-cli.command")
        func sq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        // The script holds the password, so it deletes itself as soon as it runs.
        let auth = config.password.map { "export REDISCLI_AUTH=\(sq($0))\nrm -f \"$0\"\n" } ?? ""
        do {
            try "#!/bin/sh\n\(auth)exec \(sq(binary("valkey-cli").path)) -p \(config.port)\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: config.password == nil ? 0o755 : 0o700], ofItemAtPath: script.path)
        } catch {
            failure = "Couldn't open the CLI: \(error.localizedDescription)"
            return
        }
        TerminalApps.open(script)
    }

    func showDataDir() {
        guard ensureDataDir() else { return }
        NSWorkspace.shared.open(dataDir)
    }

    /// valkey://[user:password@]127.0.0.1:port, for the default user or one of the ACL users.
    func connectionURL(for user: Config.User? = nil) -> String {
        let name = user?.name ?? "", password = user?.password ?? config.password
        let allowed = CharacterSet.urlUserAllowed.subtracting(CharacterSet(charactersIn: ":@/"))
        let auth = password.map {
            "\(name.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""):"
                + "\($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")@"
        } ?? ""
        return "valkey://\(auth)127.0.0.1:\(config.port)"
    }

    func copyConnectionURL(for user: Config.User? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(connectionURL(for: user), forType: .string)
    }

    struct Stats {
        var memoryBytes = 0, clients = 0, ops = 0, keys = 0
        var memory = ""
        var hitRate: Int?   // percent; nil until there's been a lookup
    }

    /// Numbers from INFO; nil if the server doesn't answer.
    func fetchStats() async -> Stats? {
        let cli = binary("valkey-cli"), port = config.port, password = config.password
        return await Task.detached {
            let p = Process()
            p.executableURL = cli
            p.arguments = ["-p", "\(port)", "INFO"]
            if let password { p.environment = ["REDISCLI_AUTH": password] }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            var info: [String: String] = [:]
            var keys = 0
            for line in out.split(whereSeparator: \.isNewline) {
                let kv = line.split(separator: ":", maxSplits: 1)
                guard kv.count == 2 else { continue }
                info[String(kv[0])] = String(kv[1])
                if kv[0].hasPrefix("db"), let n = kv[1].split(separator: ",").first?.split(separator: "=").last { keys += Int(n) ?? 0 }
            }
            guard let mem = info["used_memory_human"] else { return nil }
            let hits = Int(info["keyspace_hits"] ?? "") ?? 0, misses = Int(info["keyspace_misses"] ?? "") ?? 0
            return Stats(memoryBytes: Int(info["used_memory"] ?? "") ?? 0, clients: Int(info["connected_clients"] ?? "") ?? 0,
                         ops: Int(info["instantaneous_ops_per_sec"] ?? "") ?? 0, keys: keys, memory: mem,
                         hitRate: hits + misses > 0 ? hits * 100 / (hits + misses) : nil)
        }.value
    }
}
