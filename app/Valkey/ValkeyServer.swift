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
    }

    nonisolated static let rootDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Valkey", isDirectory: true)
    @Published var config: Config {
        didSet {
            onConfigChange?()
            if isRunning && (config.port != oldValue.port || config.version != oldValue.version) { restart() }
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

    private func ensureDataDir() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: confURL.path),
           let def = Bundle.main.url(forResource: "valkey.conf.default", withExtension: nil) {
            try? fm.copyItem(at: def, to: confURL)
        }
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
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
        ensureDataDir()
        let p = Process()
        p.executableURL = server
        // logfile "" = stdout, so startup errors (bad config, port in use) reach the log too.
        p.arguments = [confURL.path, "--port", "\(config.port)", "--dir", dataDir.path,
                       "--pidfile", pidURL.path, "--logfile", "", "--daemonize", "no"]

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
        let quoted = "'" + binary("valkey-cli").path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try? "#!/bin/sh\nexec \(quoted) -p \(config.port)\n".write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        TerminalApps.open(script)
    }

    func showDataDir() {
        ensureDataDir()
        NSWorkspace.shared.open(dataDir)
    }
}
