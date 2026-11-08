import AppKit

/// The app's side of `valkey-app` (see CLI.swift): answers each command on a local CFMessagePort by
/// doing what the matching UI control does, through the same store methods and checks. Only processes
/// in this user's login session can reach it. Replies are JSON: {"result", "message", "note"},
/// {"error", "exitCode"}, or {"job"} for work that takes a while (downloads, stats), which the CLI
/// polls with the internal "job" command.
@MainActor
enum CLIServer {
    private static var port: CFMessagePort?
    private static var running: Set<String> = []
    private static var finished: [String: Data] = [:]

    static func listen() {
        var context = CFMessagePortContext()
        // Runs on the main run loop, so it's safe to touch the stores here.
        port = CFMessagePortCreateLocal(nil, CLI.portName as CFString, { _, _, data, _ in
            let reply = MainActor.assumeIsolated { CLIServer.reply(to: data as Data?) }
            return Unmanaged.passRetained(reply as CFData)
        }, &context, nil)
        guard let port, let source = CFMessagePortCreateRunLoopSource(nil, port, 0) else {
            return NSLog("Valkey: couldn't open the command-line port \(CLI.portName)")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private static func reply(to data: Data?) -> Data {
        do {
            guard let data else { throw CLI.Failure(message: "Empty request.", code: CLI.Failure.usage) }
            return try handle(try JSONDecoder().decode(CLI.Invocation.self, from: data))
        } catch {
            return errorReply(error)
        }
    }

    // MARK: Replies

    private static func errorReply(_ error: Error) -> Data {
        let failure = error as? CLI.Failure ?? CLI.Failure(message: error.localizedDescription)
        return (try? JSONSerialization.data(withJSONObject: ["error": failure.message, "exitCode": failure.code])) ?? Data()
    }

    private static func ok<T: Encodable>(_ value: T, _ message: String? = nil, note: String? = nil) -> Data {
        var object: [String: Any] = [:]
        if let data = try? JSONEncoder().encode(value),
           let result = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
            object["result"] = result
        }
        if let message { object["message"] = message }
        if let note { object["note"] = note }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// Runs `work` in the background and answers with a job id the CLI polls.
    private static func job(_ work: @escaping @MainActor () async throws -> Data) -> Data {
        let id = UUID().uuidString
        running.insert(id)
        Task { @MainActor in
            let data: Data
            do { data = try await work() } catch { data = errorReply(error) }
            running.remove(id)
            finished[id] = data
        }
        return (try? JSONSerialization.data(withJSONObject: ["job": id])) ?? Data()
    }

    // MARK: Commands

    private static func handle(_ inv: CLI.Invocation) throws -> Data {
        let store = ServerStore.shared, versions = VersionStore.shared, o = inv.options
        let secrets = o["--show-secrets"] != nil
        func found(_ query: String) throws -> ValkeyServer {
            let match = try CLI.resolve(query, in: store.servers.map { info($0) })
            return store.servers.first { $0.id.uuidString == match.id }!
        }
        func arg(_ i: Int) -> String { inv.args.indices.contains(i) ? inv.args[i] : "" }
        func save(_ config: ValkeyServer.Config, to server: ValkeyServer, _ message: String) -> Data {
            let original = server.config
            return job {
                try await loadRegistry()
                return try await commit(config, original: original, message, secrets: secrets)
            }
        }

        switch inv.command {
        case "job":
            if running.contains(arg(0)) { return try JSONSerialization.data(withJSONObject: ["job": arg(0)]) }
            guard let data = finished.removeValue(forKey: arg(0)) else { throw CLI.Failure(message: "Unknown job.") }
            return data

        // Servers
        case "list":
            return ok(store.servers.map { info($0, secrets: secrets) })
        case "status" where inv.args.isEmpty:
            return ok(store.servers.map { info($0, secrets: secrets) })
        case "status", "show":
            return ok(info(try found(arg(0)), secrets: secrets))
        case "create":
            return job {
                try await loadRegistry()   // so the default version is the newest available, as in the UI
                var config = store.newConfig()
                try apply(o, to: &config)
                if o["--name"] == nil { config.name = "Valkey \(config.version)" }
                config.dataDirectory = o["--data-dir"] ?? store.defaultDataDirectory(port: config.port)
                return try await commit(config, original: nil, "Created “\(config.name)” on port \(config.port) (Valkey \(config.version)).",
                                        secrets: secrets)
            }
        case "set":
            let server = try found(arg(0))
            var config = server.config
            try apply(o, to: &config)
            guard config != server.config else { return ok(info(server, secrets: secrets), "No changes.") }
            return save(config, to: server, "Updated “\(config.name)”.")
        case "start":
            let server = try found(arg(0))
            server.isStopping ? server.restart() : server.start()
            return try started(server)
        case "restart":
            let server = try found(arg(0))
            server.restart()
            return try started(server)
        case "stop":
            let server = try found(arg(0))
            server.stop()
            return ok(info(server))
        case "delete":
            let server = try found(arg(0))
            let removed = info(server)
            store.remove(server)
            return ok(removed, "Removed “\(removed.name)”. Its data directory is kept at \(removed.dataDirectory).")
        case "url":
            let server = try found(arg(0))
            var user: ValkeyServer.Config.User?
            if let name = o["--user"] {
                user = server.config.accounts.first { $0.name == name }
                if user == nil { throw CLI.Failure(message: "“\(server.config.name)” has no user named “\(name)”.", code: CLI.Failure.notFound) }
            }
            let hasPassword = user != nil || server.config.password != nil
            if secrets || !hasPassword { let url = server.connectionURL(for: user); return ok(["url": url], url) }
            let url = server.connectionURL(for: .init(name: user?.name ?? "", password: "****"))
            return ok(["url": url], url, note: "The password is hidden; add --show-secrets to include it.")
        case "stats":
            let server = try found(arg(0))
            guard server.isRunning else { throw CLI.Failure(message: "“\(server.config.name)” isn't running.") }
            return job {
                guard let stats = await server.fetchStats() else { throw CLI.Failure(message: "“\(server.config.name)” didn't answer INFO.") }
                return ok(stats)
            }
        case "cli-info":
            let server = try found(arg(0))
            let path = versions.binary("valkey-cli", version: server.config.version).path
            var result: [String: Any] = ["path": path, "port": server.config.port]
            if let password = server.config.password { result["password"] = password }   // for the CLI process only, never printed
            return try JSONSerialization.data(withJSONObject: ["result": result])
        case "connect":
            let server = try found(arg(0))
            guard server.isRunning, !server.isStopping else { throw CLI.Failure(message: "“\(server.config.name)” isn't running.") }
            server.openCLI()
            return ok(["ok": true], "Opened valkey-cli for “\(server.config.name)” in your terminal app.")
        case "open":
            let server = try found(arg(0))
            switch inv.args.count > 1 ? arg(1) : "data" {
            case "config": server.openConfig()
            case "data": server.showDataDir()
            case "log":
                guard FileManager.default.fileExists(atPath: server.logURL.path) else { throw CLI.Failure(message: "There's no log file yet.") }
                NSWorkspace.shared.open(server.logURL)
            default: throw CLI.Failure(message: "open takes config, data or log.", code: CLI.Failure.usage)
            }
            if let failure = server.failure { throw CLI.Failure(message: failure) }
            return ok(info(server), "Opened.")

        // ACL users
        case "user add", "user set", "user remove":
            let server = try found(arg(0))
            var config = server.config
            let index = config.accounts.firstIndex { $0.name == arg(1) }
            if inv.command == "user add" {
                guard index == nil else { throw CLI.Failure(message: "“\(arg(1))” already exists.") }
                config.accounts.append(.init(name: arg(1), readOnly: o["--read-only"].flatMap(ConfigRules.bool) ?? false,
                                             password: o["--password"] ?? ""))
            } else {
                guard let index else {
                    throw CLI.Failure(message: "“\(server.config.name)” has no user named “\(arg(1))”.", code: CLI.Failure.notFound)
                }
                if inv.command == "user remove" {
                    config.accounts.remove(at: index)
                } else {
                    if let name = o["--rename"] { config.accounts[index].name = name }
                    if let password = o["--password"] { config.accounts[index].password = password }
                    if let readOnly = o["--read-only"].flatMap(ConfigRules.bool) { config.accounts[index].readOnly = readOnly }
                }
            }
            return save(config, to: server, "Updated users of “\(config.name)”.")

        // Versions and modules (Versions…)
        case "versions":
            return job { try await loadRegistry(); return ok(versionList()) }
        case "versions refresh":
            return job {
                await versions.refresh()
                if let error = versions.registryError { throw CLI.Failure(message: error) }
                return ok(versionList())
            }
        case "versions install":
            return job {
                try await loadRegistry()
                if versions.installed.contains(arg(0)) { return ok(versionList(), "Valkey \(arg(0)) is already installed.") }
                guard let entry = versions.available.first(where: { $0.version == arg(0) }) else {
                    throw CLI.Failure(message: "Valkey \(arg(0)) isn't available. Run `\(CLI.name) versions`.", code: CLI.Failure.notFound)
                }
                try await versions.install(entry)
                return ok(versionList(), "Installed Valkey \(arg(0)).")
            }
        case "versions remove":
            guard versions.installed.contains(arg(0)) else {
                throw CLI.Failure(message: "Valkey \(arg(0)) isn't installed.", code: CLI.Failure.notFound)
            }
            let users = store.servers.filter { $0.config.version == arg(0) }.map(\.config.name)
            guard users.isEmpty else { throw CLI.Failure(message: "Valkey \(arg(0)) is in use by \(users.joined(separator: ", ")).") }
            versions.remove(arg(0))
            return ok(versionList(), "Removed Valkey \(arg(0)).")
        case "modules":
            return job {
                try await loadRegistry()
                let line = o["--valkey"].map(VersionStore.line(of:))
                return ok(moduleList().filter { line == nil || $0.valkey.contains(line!) })
            }
        case "modules install":
            return job {
                try await loadRegistry()
                if versions.installedModules.contains(where: { $0.id == arg(0) }) { return ok(moduleList(), "\(arg(0)) is already installed.") }
                guard let module = versions.availableModules.first(where: { $0.id == arg(0) }) else {
                    throw CLI.Failure(message: "No module build \(arg(0)). Run `\(CLI.name) modules`.", code: CLI.Failure.notFound)
                }
                try await versions.install(module)
                return ok(moduleList(), "Installed \(module.title) \(module.version).")
            }
        case "modules remove":
            guard let module = versions.installedModules.first(where: { $0.id == arg(0) }) else {
                throw CLI.Failure(message: "Module build \(arg(0)) isn't installed.", code: CLI.Failure.notFound)
            }
            let users = moduleUsers(module)
            guard users.isEmpty else { throw CLI.Failure(message: "\(module.title) \(module.version) is in use by \(users.joined(separator: ", ")).") }
            versions.remove(module)
            return ok(moduleList(), "Removed \(module.title) \(module.version).")

        // App (Settings and the menu-bar menu)
        case "app":
            return ok(appInfo())
        case "app set":
            if let v = o["--menu-bar"].flatMap(ConfigRules.bool) { UserDefaults.standard.set(v, forKey: SettingsKey.showMenuBarExtra) }
            if let id = o["--terminal"] {
                let ids = TerminalApps.installed.compactMap { Bundle(url: $0)?.bundleIdentifier }
                guard ids.contains(id) else { throw CLI.Failure(message: "\(id) isn't an installed terminal app. Choices: \(ids.joined(separator: ", ")).") }
                UserDefaults.standard.set(id, forKey: SettingsKey.terminalApp)
            }
            if let v = o["--auto-update"].flatMap(ConfigRules.bool) { Updater.shared.automaticallyChecksForUpdates = v }
            if let v = o["--open-at-login"].flatMap(ConfigRules.bool) { try LoginItem.set(v) }
            return ok(appInfo(), "Updated app settings.")
        case "app link-cli":
            guard let newest = versions.installed.first else { throw CLI.Failure(message: "No Valkey version is installed.") }
            try CLITools.install(version: newest)
            return ok(appInfo(), "\(CLITools.status). Add this to your shell profile: \(CLITools.pathLine)")
        case "app check-updates":
            Updater.shared.checkForUpdates()
            return ok(appInfo(), "Opened the update check in Valkey.app; it continues in its window.")
        case "app quit":
            // Reply first; quitting stops every server gracefully, then exits. Not DispatchQueue.main:
            // .terminateLater would spin inside that block, and servers' exit handlers (queued on main) never run.
            RunLoop.main.perform { AppDelegate.quitCompletely() }
            return ok(["ok": true], "Valkey.app is quitting; its servers are stopping.")
        default:
            throw CLI.Failure(message: "Unknown command \(inv.command). Update Valkey.app?", code: CLI.Failure.usage)
        }
    }

    /// Saves a config the way Server Settings does: check it, download what it needs, then apply it.
    private static func commit(_ config: ValkeyServer.Config, original: ValkeyServer.Config?, _ message: String,
                               secrets: Bool) async throws -> Data {
        let server = try await ServerStore.shared.commit(config, original: original)
        return ok(info(server, secrets: secrets), message)
    }

    /// start() reports problems it finds up front (not installed, missing module) in `failure`.
    private static func started(_ server: ValkeyServer) throws -> Data {
        if !server.isRunning, let failure = server.failure { throw CLI.Failure(message: failure) }
        return ok(info(server))
    }

    /// The registry loads when the app launches; wait for it so a fresh launch sees what's available.
    private static func loadRegistry() async throws {
        let versions = VersionStore.shared
        if versions.available.isEmpty && !versions.isRefreshing { await versions.refresh() }
        while versions.isRefreshing { try await Task.sleep(nanoseconds: 100_000_000) }
    }

    /// The setting options shared by create and set (validated by ServerStore.problem(with:) on save).
    private static func apply(_ o: [String: String], to c: inout ValkeyServer.Config) throws {
        if let v = o["--name"] { c.name = v }
        if let v = o["--port"] { c.port = Int(v) ?? 0 }
        if let v = o["--version"] { c.version = v }
        if let v = o["--auto-start"].flatMap(ConfigRules.bool) { c.startAutomatically = v }
        if let v = o["--auto-restart"].flatMap(ConfigRules.bool) { c.autoRestart = v ? nil : false }
        if let v = o["--persistence"].flatMap(ConfigRules.bool) { c.persistence = v ? nil : false }
        if let v = o["--max-memory"] { c.maxMemory = v.isEmpty || v == "none" ? nil : v }
        if let v = o["--eviction-policy"] { c.evictionPolicy = v.isEmpty || v == "noeviction" ? nil : v }
        if let v = o["--password"] { c.password = v.isEmpty ? nil : v }
        if let v = o["--modules"] {
            c.enabledModules = v == "none" ? [] : Set(v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }).sorted()
        }
        if let v = o["--enable-module"], !c.enabledModules.contains(v) { c.enabledModules = (c.enabledModules + [v]).sorted() }
        if let v = o["--disable-module"] {
            guard c.enabledModules.contains(v) else { throw CLI.Failure(message: "The \(v) module isn't on for this server.") }
            c.enabledModules.removeAll { $0 == v }
        }
    }

    // MARK: Query shapes (documented in app/CLI.md)

    private static func info(_ server: ValkeyServer, secrets: Bool = false) -> CLI.ServerInfo {
        let c = server.config, versions = VersionStore.shared
        let state = server.isStopping ? "stopping" : server.isRunning ? "running" : server.failure != nil ? "failed" : "stopped"
        let modules = c.enabledModules.map { name -> CLI.ServerInfo.Module in
            let title = versions.knownModules.first { $0.name == name }?.title ?? name
            if let m = versions.installedModule(name, for: c.version) { return .init(name: name, title: title, status: "installed", version: m.version) }
            if let m = versions.availableModule(name, for: c.version) { return .init(name: name, title: title, status: "will-download", version: m.version) }
            return .init(name: name, title: title, status: "unavailable", version: nil)
        }
        return CLI.ServerInfo(
            id: c.id.uuidString, name: c.name, version: c.version, port: c.port, state: state, pid: server.pid,
            failure: server.failure, startAutomatically: c.startAutomatically, autoRestart: c.autoRestart != false,
            persistence: c.persistence != false, maxMemory: c.maxMemory, evictionPolicy: c.evictionPolicy ?? "noeviction",
            hasPassword: c.password != nil, password: secrets ? c.password : nil,
            users: c.accounts.map { .init(name: $0.name, readOnly: $0.readOnly, password: secrets ? $0.password : nil) },
            modules: modules, dataDirectory: c.dataDirectory,
            configFile: server.dataDir.appendingPathComponent("valkey.conf").path, logFile: server.logURL.path)
    }

    private struct VersionInfo: Encodable {
        var version: String
        var installed: Bool
        var available: Bool
        var published: String?
        var size: Int?
        var usedBy: [String]
        var installing: Double?
    }

    private static func versionList() -> [VersionInfo] {
        let versions = VersionStore.shared
        return versions.allVersions.map { v in
            let entry = versions.available.first { $0.version == v }
            return VersionInfo(version: v, installed: versions.installed.contains(v), available: entry != nil,
                               published: entry?.published, size: entry?.size,
                               usedBy: ServerStore.shared.servers.filter { $0.config.version == v }.map(\.config.name),
                               installing: versions.progress[v])
        }
    }

    private struct ModuleInfo: Encodable {
        var id, name, title, summary, version: String
        var valkey: [String]
        var installed: Bool
        var size: Int
        var usedBy: [String]
        var installing: Double?
    }

    /// Servers that would load exactly this module build.
    private static func moduleUsers(_ module: VersionStore.ModuleEntry) -> [String] {
        ServerStore.shared.servers.filter {
            $0.config.enabledModules.contains(module.name)
                && VersionStore.shared.installedModule(module.name, for: $0.config.version)?.id == module.id
        }.map(\.config.name)
    }

    private static func moduleList() -> [ModuleInfo] {
        let versions = VersionStore.shared
        var seen = Set<String>()
        return (versions.installedModules + versions.availableModules)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.title != $1.title ? $0.title < $1.title : VersionStore.isNewer($0.version, than: $1.version) }
            .map { m in
                ModuleInfo(id: m.id, name: m.name, title: m.title, summary: m.summary, version: m.version, valkey: m.valkey,
                           installed: versions.installedModules.contains { $0.id == m.id }, size: m.size,
                           usedBy: moduleUsers(m), installing: versions.progress[m.id])
            }
    }

    private struct AppInfo: Encodable {
        struct Terminal: Encodable { var id, name: String }
        var running = true
        var version, build, appPath, dataRoot: String
        var pid: Int32
        var menuBar, openAtLogin, autoUpdate, canCheckForUpdates: Bool
        var terminal: String
        var terminals: [Terminal]
        var registryURL: String
        var registryError: String?
        var valkeyCLILink: String
        var valkeyCLIPathLine: String
    }

    private static func appInfo() -> AppInfo {
        let info = Bundle.main.infoDictionary
        let defaults = UserDefaults.standard
        return AppInfo(
            version: info?["CFBundleShortVersionString"] as? String ?? "", build: info?["CFBundleVersion"] as? String ?? "",
            appPath: Bundle.main.bundlePath, dataRoot: ValkeyServer.rootDir.path,
            pid: ProcessInfo.processInfo.processIdentifier,
            menuBar: defaults.object(forKey: SettingsKey.showMenuBarExtra) as? Bool ?? true,
            openAtLogin: LoginItem.isEnabled, autoUpdate: Updater.shared.automaticallyChecksForUpdates,
            canCheckForUpdates: Updater.shared.canCheckForUpdates,
            terminal: defaults.string(forKey: SettingsKey.terminalApp) ?? TerminalApps.defaultID,
            terminals: TerminalApps.installed.map {
                .init(id: Bundle(url: $0)?.bundleIdentifier ?? $0.path,
                      name: FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: ""))
            },
            registryURL: VersionStore.defaultRegistryURL.absoluteString, registryError: VersionStore.shared.registryError,
            valkeyCLILink: CLITools.status, valkeyCLIPathLine: CLITools.pathLine)
    }
}
