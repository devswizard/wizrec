import AppKit
import PlayerKit

/// Process-wide settings from the command line.
@MainActor
enum AppEnvironment {
    static var options = LaunchOptions()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = AppEnvironment.options
        for path in options.paths {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error {
                    FileHandle.standardError.write(Data("WizRec: cannot open \(url.path): \(error.localizedDescription)\n".utf8))
                    NSApp.presentError(error)
                }
            }
        }
        if let q = options.quitAfter {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, q) * 1e9))
                NSApp.terminate(nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        AppEnvironment.options.paths.isEmpty
    }

    /// No untitled documents in a player: offer the open panel instead.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSDocumentController.shared.openDocument(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: "Free, open-source screen recorder & editor by Devs Wizard.\nOpens your Camtasia projects.\n\nGPL-3.0-or-later.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "WizRec", .credits: credits])
    }
}
