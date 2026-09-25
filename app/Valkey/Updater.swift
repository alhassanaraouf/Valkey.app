import AppKit
import Combine
import Sparkle

/// App self-updates via Sparkle. The feed (SUFeedURL, https://valkey.app/appcast.xml) lists releases;
/// each archive must carry an Ed25519 signature matching SUPublicEDKey. Sparkle's window shows the
/// release notes and asks before downloading (SUAllowsAutomaticUpdates is off), then replaces the
/// app in place and relaunches it.
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    /// Running servers are restarted after an update relaunch.
    private static let resumeKey = "resumeServersAfterUpdate"

    @Published private(set) var canCheckForUpdates = false
    private var controller: SPUStandardUpdaterController!

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func checkForUpdates() {
        // A menu-bar app may be in the background; bring Sparkle's window to the front.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// Server IDs that were running when the last update relaunched the app (cleared on read).
    @MainActor
    static func takeServersToResume() -> [UUID] {
        let ids = UserDefaults.standard.stringArray(forKey: resumeKey) ?? []
        UserDefaults.standard.removeObject(forKey: resumeKey)
        return ids.compactMap(UUID.init(uuidString:))
    }
}

extension Updater: SPUUpdaterDelegate {
    /// Override with `defaults write app.valkey.Valkey updateFeedURL <url>` to test a local feed.
    func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "updateFeedURL")
    }

    /// Sparkle quits the app to install. That quit must be real (⌘Q only closes to the menu bar),
    /// and servers running now are remembered so the relaunched version starts them again.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated {
            let running = ServerStore.shared.servers.filter(\.isRunning).map(\.id.uuidString)
            UserDefaults.standard.set(running, forKey: Self.resumeKey)
            AppDelegate.prepareToQuitCompletely()
        }
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    /// Opting in to "gentle" reminders lets Sparkle show scheduled update alerts for a menu-bar app.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        true
    }

    /// Only a check the user asked for takes focus. A background check must never steal the keyboard:
    /// a stray Return typed into another app would hit "Install Update". It bounces the Dock icon instead.
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if state.userInitiated {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }
}
