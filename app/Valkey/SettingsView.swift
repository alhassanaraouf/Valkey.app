import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

enum SettingsKey {
    static let showMenuBarExtra = "showMenuBarExtra"
    static let terminalApp = "terminalApp"
}

/// Terminal apps are whatever the system knows can *run* .command scripts (document role "Shell"),
/// so iTerm2, Ghostty, Warp etc. show up without a hardcoded list and text editors don't.
enum TerminalApps {
    static let defaultID = "com.apple.Terminal"

    static var installed: [URL] {
        guard let type = UTType(filenameExtension: "command") else { return [] }
        return NSWorkspace.shared.urlsForApplications(toOpen: type).filter { app in
            let types = Bundle(url: app)?.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
            return types.contains { $0["CFBundleTypeRole"] as? String == "Shell" }
        }
    }

    /// The chosen terminal, falling back to Terminal if it was uninstalled.
    static var selected: URL? {
        let id = UserDefaults.standard.string(forKey: SettingsKey.terminalApp) ?? defaultID
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: defaultID)
    }

    static func open(_ script: URL) {
        guard let app = selected else { NSWorkspace.shared.open(script); return }
        let openScript = {
            NSWorkspace.shared.open([script], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
        guard Bundle(url: app)?.bundleIdentifier == "com.mitchellh.ghostty" else { return openScript() }

        // Ghostty asks for confirmation every time it's handed a script, with no "always allow".
        // Its AppleScript interface (Ghostty 1.3+) doesn't; macOS asks once for Automation permission.
        // If that fails (older Ghostty, permission denied, macos-applescript = false), open the script.
        let shellQuoted = "'" + script.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let literal = shellQuoted.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
            tell application id "com.mitchellh.ghostty"
                activate
                set cfg to new surface configuration
                set command of cfg to "\(literal)"
                new window with configuration cfg
            end tell
            """
        // osascript rather than NSAppleScript, which must run on the main thread and would freeze the
        // UI during a cold Ghostty launch or the first permission prompt.
        let osascript = Process()
        osascript.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osascript.arguments = ["-e", source]
        osascript.standardOutput = FileHandle.nullDevice
        osascript.standardError = FileHandle.nullDevice
        osascript.terminationHandler = { p in
            if p.terminationStatus != 0 { DispatchQueue.main.async(execute: openScript) }
        }
        do { try osascript.run() } catch { openScript() }
    }
}

/// `valkey-cli` and `valkey-app` in /usr/local/bin, which every shell has on PATH (/etc/paths), plus
/// tab completion. Everything installed outside Application Support is a symlink into it:
/// /usr/local/bin/valkey-cli → Valkey/bin/valkey-cli → the newest installed version, and each shell's
/// completion file → Valkey/completions/…, so relinking after an upgrade needs no admin password.
@MainActor enum CLITools {
    static let dir = ValkeyServer.rootDir.appendingPathComponent("bin", isDirectory: true)
    static let binDir = "/usr/local/bin"
    private static let completions = ValkeyServer.rootDir.appendingPathComponent("completions", isDirectory: true)
    private static var versionLink: URL { dir.appendingPathComponent("valkey-cli") }
    /// Links that need /usr/local (maybe an admin password) and what each points at. macOS's zsh
    /// already has /usr/local/share/zsh/site-functions on its fpath.
    private static var links: [(path: String, target: String)] {
        [("\(binDir)/valkey-cli", versionLink.path),
         ("\(binDir)/valkey-app", Bundle.main.executablePath ?? "/Applications/Valkey.app/Contents/MacOS/Valkey"),
         ("/usr/local/share/zsh/site-functions/_valkey-app", completions.appendingPathComponent("_valkey-app").path)]
    }
    /// Per-user completion links, made only for shells that would load them.
    private static var userLinks: [(path: String, target: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path, fm = FileManager.default
        var result: [(String, String)] = []
        if ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "\(home)/.config/fish"].contains(where: fm.fileExists) {
            result.append(("\(home)/.config/fish/completions/valkey-app.fish", completions.appendingPathComponent("valkey-app.fish").path))
        }
        if ["/opt/homebrew/etc/profile.d/bash_completion.sh", "/usr/local/etc/profile.d/bash_completion.sh"].contains(where: fm.fileExists) {
            result.append(("\(home)/.local/share/bash-completion/completions/valkey-app", completions.appendingPathComponent("valkey-app.bash").path))
        }
        return result
    }

    /// A symlink Valkey.app made (from any copy of the app), safe to replace.
    private static func isOurs(_ path: String) -> Bool {
        guard let points = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return false }
        return points.hasPrefix(ValkeyServer.rootDir.path) || points.hasSuffix(".app/Contents/MacOS/Valkey")
    }

    static var status: String {
        let fm = FileManager.default
        guard let target = try? fm.destinationOfSymbolicLink(atPath: versionLink.path),
              links.allSatisfy({ (try? fm.destinationOfSymbolicLink(atPath: $0.path)) == $0.target }) else { return "Not installed" }
        guard fm.isExecutableFile(atPath: target) else { return "Out of date: that version was removed" }
        return "Installed (Valkey " + URL(fileURLWithPath: target).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent + ")"
    }

    static var isInstalled: Bool { status != "Not installed" }

    /// Points valkey-cli at `version`, puts valkey-cli and valkey-app on PATH and sets up tab completion,
    /// asking for an admin password if /usr/local isn't writable. Refuses to replace files it didn't create.
    static func install(version: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.removeItem(at: versionLink)
        try fm.createSymbolicLink(at: versionLink, withDestinationURL: VersionStore.shared.binary("valkey-cli", version: version))
        // Rewritten on every install so they match this version of the app.
        try fm.createDirectory(at: completions, withIntermediateDirectories: true)
        for (shell, file) in [("zsh", "_valkey-app"), ("bash", "valkey-app.bash"), ("fish", "valkey-app.fish")] {
            try (CLI.completionScript(for: shell)! + "\n").write(to: completions.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }

        // Anything already there that we didn't make (e.g. Homebrew's valkey-cli) is left alone.
        func exists(_ path: String) -> Bool { fm.fileExists(atPath: path) || (try? fm.destinationOfSymbolicLink(atPath: path)) != nil }
        let missing = links.filter { (try? fm.destinationOfSymbolicLink(atPath: $0.path)) != $0.target }
        for link in missing + userLinks where exists(link.path) && !isOurs(link.path) {
            throw CLI.Failure(message: "\(link.path) already exists and wasn't made by Valkey.app. Remove it, then try again.")
        }
        for link in userLinks {
            try fm.createDirectory(atPath: (link.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? fm.removeItem(atPath: link.path)
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: link.target)
        }
        guard !missing.isEmpty else { return }
        func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let dirs = Set(missing.map { ($0.path as NSString).deletingLastPathComponent }).sorted()
        let script = (dirs.map { "mkdir -p \(quoted($0))" } + missing.map { "ln -sfn \(quoted($0.target)) \(quoted($0.path))" })
            .joined(separator: " && ")
        if run("/bin/sh", ["-c", script]) == 0 { return }
        // Not writable (or missing): the same commands, through the system's admin password prompt.
        let apple = "do shell script \"\(script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        guard run("/usr/bin/osascript", ["-e", apple]) == 0 else {
            throw CLI.Failure(message: "Couldn't add valkey-cli and valkey-app to \(binDir) (cancelled or not allowed).")
        }
    }

    private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

struct SettingsView: View {
    @AppStorage(SettingsKey.showMenuBarExtra) private var showMenuBarExtra = true
    @AppStorage(SettingsKey.terminalApp) private var terminalApp = TerminalApps.defaultID
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var cliStatus = CLITools.status
    @State private var cliError: String?
    @ObservedObject private var updater = Updater.shared
    private let terminals = TerminalApps.installed

    var body: some View {
        Form {
            Toggle("Show in menu bar", isOn: $showMenuBarExtra)
            Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin))
            if let loginError {
                Text(loginError).font(.callout).foregroundColor(.red)
            }
            Picker("Terminal", selection: $terminalApp) {
                ForEach(terminals, id: \.self) { url in
                    let id = Bundle(url: url)?.bundleIdentifier ?? url.path
                    Label {
                        Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    }
                    .tag(id)
                }
            }
            Text("Used by Connect… to open valkey-cli.").font(.caption).foregroundColor(.secondary)

            Section("Command Line") {
                HStack {
                    Text(cliStatus).foregroundColor(.secondary)
                    Spacer()
                    Button(CLITools.isInstalled ? "Relink to Newest" : "Install CLI") {
                        do {
                            try CLITools.install(version: VersionStore.shared.installed.first ?? "")
                            cliError = nil
                        } catch { cliError = error.localizedDescription }
                        cliStatus = CLITools.status
                    }
                    .disabled(VersionStore.shared.installed.isEmpty)
                }
                if let cliError { Text(cliError).font(.callout).foregroundColor(.red) }
                Text("Adds valkey-cli and valkey-app to \(CLITools.binDir), so they work in any terminal, with tab completion for zsh, bash and fish.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }))
                HStack {
                    Text("Valkey.app \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .foregroundColor(.secondary)
                    Spacer()
                    CheckForUpdatesButton()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        openAtLogin = LoginItem.isEnabled
    }
}

/// Open at login, shared by Settings and `valkey-app app set --open-at-login`.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled { try service.register() } else { try service.unregister() }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}
