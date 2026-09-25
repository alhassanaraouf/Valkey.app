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

struct SettingsView: View {
    @AppStorage(SettingsKey.showMenuBarExtra) private var showMenuBarExtra = true
    @AppStorage(SettingsKey.terminalApp) private var terminalApp = TerminalApps.defaultID
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
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
        let service = SMAppService.mainApp
        do {
            if enabled { try service.register() } else { try service.unregister() }
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        openAtLogin = service.status == .enabled
    }
}
