import AppKit
import Captions
import PlayerKit

/// Process-wide settings from the command line.
@MainActor
enum AppEnvironment {
    static var options = LaunchOptions()
    /// Preferences as loaded at launch (the Settings window edits UserDefaults directly).
    static var preferences = AppPreferences()
    /// The welcome window was shown at this launch (no open panel then).
    static var welcomeShown = false
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = AppEnvironment.options
        // Scripted runs (--quit-after) never start the updater.
        if options.quitAfter == nil { AppUpdater.shared.start() }
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
                // A document sheet (e.g. Relink Missing Media shown at open) blocks closing the
                // document and with it the scripted quit; dismiss sheets first.
                for w in NSApp.windows { if let s = w.attachedSheet { w.endSheet(s) } }
                // Unsaved edits would make the quit ask; a timed run never waits for the user.
                ProjectDocument.discardUnsavedEditsBeforeQuit(options: options)
                NSApp.terminate(nil)
            }
        }
        if AppPreferences.load(from: .standard).showsWelcome(for: options) {
            AppEnvironment.welcomeShown = true
            WelcomeWindowController.shared.present()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        AppEnvironment.options.paths.isEmpty && !AppEnvironment.welcomeShown
            && !AppPreferences.load(from: .standard).showsWelcome(for: AppEnvironment.options)
    }

    /// No untitled documents in a player: offer the open panel instead.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSDocumentController.shared.openDocument(nil)
        return true
    }

    /// Quit while exporting: one confirmation for every window, then cancel and wait until
    /// the unfinished files are removed. Windows closed afterwards do not ask again.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let editors = NSDocumentController.shared.documents
            .flatMap(\.windowControllers).compactMap { $0 as? EditorWindowController }
            .filter { $0.exportsBlockingClose > 0 }
        guard !editors.isEmpty else { return .terminateNow }
        let jobs = editors.map(\.exportsBlockingClose).reduce(0, +)
        let alert = EditorWindowController.cancelExportsAlert(jobs: jobs, quitting: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task { @MainActor in
            for e in editors { await e.cancelExportsForQuit() }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.present() }
    @objc func showWelcome(_ sender: Any?) { WelcomeWindowController.shared.present() }

    /// Captions ▸ Speech Engine ▸ <engine>: stores the choice (`WhisperSettings.backendKey`).
    /// whisper.cpp without its executable or a model opens Settings ▸ Captions to set it up.
    @objc func chooseSpeechEngine(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: WhisperSettings.backendKey)
        if id == WhisperCppRecognizer().id, !WhisperCppRecognizer.fromDefaults().isAvailable {
            SettingsWindowController.shared.present()
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(chooseSpeechEngine(_:)) {
            let current = TranscriptionBackends.preferred().id
            item.state = (item.representedObject as? String) == current ? .on : .off
        }
        return true
    }

    @objc func showCrashReports(_ sender: Any?) {
        let dir = CrashLog.defaultDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: "Free, open-source screen recorder & editor by Devs Wizard.\nOpens your Camtasia projects.\n\nGPL-3.0-or-later.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "WizRec", .credits: credits])
    }
}
