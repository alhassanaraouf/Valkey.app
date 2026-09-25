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
        NSWorkspace.shared.open([script], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

struct SettingsView: View {
    @AppStorage(SettingsKey.showMenuBarExtra) private var showMenuBarExtra = true
    @AppStorage(SettingsKey.terminalApp) private var terminalApp = TerminalApps.defaultID
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
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
