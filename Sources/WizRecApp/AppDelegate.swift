import AppKit
import Captions
import PlayerKit

/// Process-wide settings from the command line.
@MainActor
enum AppEnvironment {
    static var options = LaunchOptions()
    /// Preferences as loaded at launch (the Settings window edits UserDefaults directly).
    static var preferences = AppPreferences()
    /// The app is quitting: closing windows must not bring the start screen back.
    static var terminating = false
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = AppEnvironment.options
        // `-WizRec.PrintLibrary YES` (UI checks): list every library tile, "<tab> <identifier>".
        if UserDefaults.standard.bool(forKey: "WizRec.PrintLibrary") {
            for tile in SidebarView.libraryManifest() { print("library-tile \(tile.tab) \(tile.identifier)") }
            fflush(stdout)
        }
        WindowSnapshots.scheduleIfRequested()
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
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A launch that opened no project (no paths, no Finder open): AppKit asks for an untitled
    /// document; WizRec shows its launch window instead (`AppPreferences.launchWindow`).
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        AppPreferences.load(from: .standard).launchWindow(for: AppEnvironment.options) != .none
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        switch AppPreferences.load(from: .standard).launchWindow(for: AppEnvironment.options) {
        case .none: return false
        case .onboarding: WelcomeWindowController.shared.present()
        case .startScreen: StartWindowController.shared.present()
        case .openPanel: NSDocumentController.shared.openDocument(nil)
        }
        return true
    }

    /// Dock icon clicked with no window open: the start screen. With projects open (minimized,
    /// say) AppKit's usual handling brings them back instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let o = AppEnvironment.options
        guard !flag, NSDocumentController.shared.documents.isEmpty else { return true }
        if o.startScreen || !o.isScripted { StartWindowController.shared.present() }
        return false
    }

    /// After a project closed: the start screen when that was the last one (`StartScreenPolicy`).
    /// Checked a moment later, so a close that is part of quitting or of replacing the window
    /// (a sheet, the next document opening) does not flash it.
    static func documentDidClose() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            let open = NSDocumentController.shared.documents.count
            if StartScreenPolicy.showsAfterDocumentClosed(openDocuments: open, terminating: AppEnvironment.terminating,
                                                          modalShown: NSApp.modalWindow != nil,
                                                          options: AppEnvironment.options) {
                StartWindowController.shared.present()
            }
        }
    }

    /// Quit while exporting: one confirmation for every window, then cancel and wait until
    /// the unfinished files are removed. Windows closed afterwards do not ask again.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let editors = NSDocumentController.shared.documents
            .flatMap(\.windowControllers).compactMap { $0 as? EditorWindowController }
            .filter { $0.exportsBlockingClose > 0 }
        guard !editors.isEmpty else {
            AppEnvironment.terminating = true
            return .terminateNow
        }
        let jobs = editors.map(\.exportsBlockingClose).reduce(0, +)
        let alert = EditorWindowController.cancelExportsAlert(jobs: jobs, quitting: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task { @MainActor in
            for e in editors { await e.cancelExportsForQuit() }
            AppEnvironment.terminating = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.present() }
    @objc func showWelcome(_ sender: Any?) { WelcomeWindowController.shared.present() }
    /// Window ▸ Start Screen (⇧⌘1).
    @objc func showStartScreen(_ sender: Any?) { StartWindowController.shared.present() }

    // With no project window in the responder chain, these File menu items act here: each
    // starts a new project (EditorWindowController handles them when a project is frontmost).
    @objc func newRecording(_ sender: Any?) { StartActions.newRecording() }
    @objc func importMedia(_ sender: Any?) { StartActions.importMedia() }

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

/// `-WizRec.WindowSnapshots <dir>` (argument domain; UI checks and screenshots): this many
/// seconds after launch (`-WizRec.WindowSnapshotDelay`, default 5) every visible window, title
/// bar and toolbar included, is written to `<dir>/window-<n>-<title>.png`. The Metal canvas
/// draws through a layer `cacheDisplay` does not capture (use `--snapshot-dir` for it).
@MainActor
enum WindowSnapshots {
    static func scheduleIfRequested(defaults: UserDefaults = .standard) {
        guard let dir = defaults.string(forKey: "WizRec.WindowSnapshots"), !dir.isEmpty else { return }
        let delay = defaults.object(forKey: "WizRec.WindowSnapshotDelay") != nil
            ? defaults.double(forKey: "WizRec.WindowSnapshotDelay") : 5
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1e9))
            let out = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for (n, w) in NSApp.orderedWindows.filter(\.isVisible).enumerated() {
                let title = w.title.isEmpty ? "untitled" : w.title.replacingOccurrences(of: "/", with: "-")
                write(w, to: out.appendingPathComponent("window-\(n)-\(title).png"))
            }
        }
    }

    private static func write(_ window: NSWindow, to url: URL) {
        guard let frame = window.contentView?.superview,
              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: url)
            print("window snapshot \(url.path)")
        } catch {
            print("window snapshot failed \(url.path): \(error)")
        }
        fflush(stdout)
    }
}
