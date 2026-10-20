import AppKit
import PlayerKit
import Sparkle

/// WizRec ▸ Check for Updates… through Sparkle 2. The updater exists only when the bundle's
/// Info.plist has a valid `SUFeedURL` and `SUPublicEDKey` (`UpdaterConfiguration`); otherwise
/// nothing is started, nothing touches the network, and the menu item stays disabled.
@MainActor
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    let configuration: UpdaterConfiguration
    private var controller: SPUStandardUpdaterController?

    private override init() {
        configuration = UpdaterConfiguration(bundle: .main)
        super.init()
    }

    /// Starts Sparkle when configured (call once, after launch). Sparkle asks the user on a
    /// later launch whether to check automatically; nothing is checked before that.
    func start() {
        guard controller == nil else { return }
        guard configuration.isEnabled else {
            if case .disabled(let reason) = configuration.state, reason != .notAnAppBundle {
                FileHandle.standardError.write(Data("WizRec: updates off: \(reason)\n".utf8))
            }
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }
}

extension AppUpdater: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdates(_:)) {
            item.toolTip = configuration.isEnabled ? nil : String(localized: "Updates are not configured in this build.")
            return canCheckForUpdates
        }
        return true
    }
}
