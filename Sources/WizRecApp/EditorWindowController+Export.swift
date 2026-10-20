import AppKit
import AudioEngine
import Exporter
import MediaEngine
import PlayerKit
import RenderEngine
import SwiftUI
import TSCProjKit

/// One queued export: the settings and the project snapshot it renders.
struct ExportJobSpec {
    var settings: ExportSettings
    var scene: SceneModel
    var audio: AudioScene
}

extension EditorWindowController {
    /// File ▸ Export… (⌘E).
    @objc func showExport(_ sender: Any?) {
        guard let window else { return }
        if let s = exportSheet { window.beginSheet(s); return }
        if exportState.baseName.isEmpty {
            exportState.baseName = (model.bundle.directory.lastPathComponent as NSString).deletingPathExtension
        }
        let view = ExportSheet(presets: ExportSession.presets, state: exportState, queue: exportQueue,
                               hasSelection: ExportRange.selection(in: model.project, clipIDs: timelineModel.selection) != nil,
                               export: { [weak self] r in self?.queueExports(r) },
                               close: { [weak self] in
                                   guard let self, let s = self.exportSheet else { return }
                                   self.window?.endSheet(s)
                                   self.exportSheet = nil
                               })
        let sheet = ExportSheetWindow(contentViewController: NSHostingController(rootView: view))
        sheet.onPerformClose = { [weak self] in self?.closeFromExportSheet() }
        exportSheet = sheet
        window.beginSheet(sheet)
    }

    /// ⌘W while the export sheet is up: the sheet is the key window, so File ▸ Close reaches it,
    /// not the project window. Dismiss the sheet (exports keep running) and take the project
    /// window's own close path, as its close button does: confirm and cancel running exports,
    /// then NSDocument's unsaved-changes review.
    func closeFromExportSheet() {
        guard let window else { return }
        if let s = exportSheet { window.endSheet(s); exportSheet = nil }
        window.performClose(nil)
    }

    /// Queues one job per preset, rendering the project as it is now.
    func queueExports(_ r: ExportRequest) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: r.folder, withIntermediateDirectories: true)
        } catch {
            ui.show(String(localized: "Cannot write to \(r.folder.path): \(Self.describe(error))"))
            return
        }
        guard fm.isWritableFile(atPath: r.folder.path) else {
            ui.show(String(localized: "Cannot write to \(r.folder.path)."))
            return
        }
        let range = r.scope == .selection ? ExportRange.selection(in: model.project, clipIDs: timelineModel.selection) : nil
        let base = r.baseName.isEmpty ? (model.bundle.directory.lastPathComponent as NSString).deletingPathExtension : r.baseName
        var reserved = exportQueue.pendingOutputs
        for p in r.presets {
            let s = Self.apply(r, to: p.settings, range: range, canvas: model.scene.canvasSize)
            let out = ExportNaming.uniqueURL(directory: r.folder, base: base, ext: s.format.fileExtension, reserved: reserved)
            reserved.insert(out.standardizedFileURL)
            let id = exportQueue.add(name: p.name, output: out)
            exportSpecs[id] = ExportJobSpec(settings: s, scene: model.scene, audio: model.audioScene)
        }
    }

    /// A preset's settings with the sheet's overrides: range, audio, resolution (longest side,
    /// canvas aspect), frame rate and GIF options. Audio-only formats ignore picture overrides.
    static func apply(_ r: ExportRequest, to preset: ExportSettings, range: Range<Int64>?, canvas: CGSize) -> ExportSettings {
        var s = preset
        s.range = range
        if !r.includeAudio { s.includeAudio = false }
        if case .audio = s.format { return s }
        if r.maxSide > 0, canvas.width > 0, canvas.height > 0 {
            let k = Double(r.maxSide) / Double(max(canvas.width, canvas.height))
            s.size = CGSize(width: (canvas.width * k).rounded(), height: (canvas.height * k).rounded())
        }
        if r.fps > 0 {
            if case .gif = s.format { s.format = .gif(fps: min(r.fps, 50)) } else { s.frameRate = Rational(Int64(r.fps)) }
        }
        s.gif.dither = r.gifDither
        s.gif.loopCount = r.gifLoop ? 0 : 1
        return s
    }

    /// `--export`: one preset writes exactly `file`; several write `file`'s folder and name with
    /// each preset's extension (made unique).
    func queueScriptedExports(_ presets: [ExportPreset], to file: URL) {
        let dir = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = file.deletingPathExtension().lastPathComponent
        var reserved = exportQueue.pendingOutputs
        for p in presets {
            let out = presets.count == 1 ? file
                : ExportNaming.uniqueURL(directory: dir, base: base, ext: p.settings.format.fileExtension, reserved: reserved)
            reserved.insert(out.standardizedFileURL)
            let id = exportQueue.add(name: p.name, output: out)
            exportSpecs[id] = ExportJobSpec(settings: p.settings, scene: model.scene, audio: model.audioScene)
        }
    }

    /// The queue's runner: one `ExportSession` per job on a pool separate from playback.
    static func makeExportQueue(specs: @escaping @MainActor (Int) -> ExportJobSpec?,
                                pool: @escaping @MainActor () -> MediaPool) -> ExportQueue {
        ExportQueue { id, output, progress in
            guard let spec = specs(id) else { throw ExportError.failed("job \(id) has no settings") }
            let session = ExportSession(scene: spec.scene, audio: spec.audio, pool: pool(), settings: spec.settings,
                                        output: output)
            // Push-based progress: polling the session actor from here starved the export.
            await session.setProgressHandler(progress)
            do {
                try await withTaskCancellationHandler {
                    try await session.run()
                } onCancel: {
                    // run() throws once the partial output is removed; ExportQueue.cancelAllAndWait
                    // awaits that, so closing the window never leaves an unfinished file behind.
                    Task { await session.cancelAndWait() }
                }
                progress(1)
            } catch ExportError.cancelled {
                throw CancellationError()
            }
        }
    }
}

// MARK: Closing while exporting

/// The export sheet's window: File ▸ Close (⌘W) closes the project window behind it
/// (`EditorWindowController.closeFromExportSheet`) instead of doing nothing.
final class ExportSheetWindow: NSWindow {
    var onPerformClose: (@MainActor () -> Void)?

    override func performClose(_ sender: Any?) {
        if let onPerformClose { onPerformClose() } else { super.performClose(sender) }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performClose(_:)), onPerformClose != nil { return true }
        return super.validateUserInterfaceItem(item)
    }
}

extension EditorWindowController {
    /// Exports a close or quit would cancel; 0 when none or when the user already agreed.
    var exportsBlockingClose: Int {
        if case .ask(let n) = exportCloseGuard.decide(activeJobs: exportQueue.activeJobCount,
                                                       scripted: options.isScripted) { return n }
        return 0
    }

    /// Asks whether to cancel the running exports (sheet on this window), then cancels them and
    /// waits until their partial files are removed. `done(true)` = go ahead and close.
    func confirmCancellingExports(_ done: @escaping @MainActor (Bool) -> Void) {
        let n = exportsBlockingClose
        guard n > 0 else { done(true); return }
        guard !exportCloseGuard.isAsking else { done(false); return }
        exportCloseGuard.beginAsking()
        let alert = Self.cancelExportsAlert(jobs: n, quitting: false)
        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard let self else { return }
            let cancel = r == .alertFirstButtonReturn
            self.exportCloseGuard.answer(cancelExports: cancel)
            guard cancel else { done(false); return }
            Task { @MainActor in
                await self.exportQueue.cancelAllAndWait()
                done(true)
            }
        }
        if let window, window.isVisible {
            if let s = exportSheet { window.endSheet(s); exportSheet = nil }
            alert.beginSheetModal(for: window) { r in MainActor.assumeIsolated { finish(r) } }
        } else {
            finish(alert.runModal())
        }
    }

    /// Cancels this window's exports after the app-wide quit confirmation. No further asking.
    func cancelExportsForQuit() async {
        exportCloseGuard.answer(cancelExports: true)
        await exportQueue.cancelAllAndWait()
    }

    /// "Cancel export?" alert. First button cancels the exports, second keeps them running.
    static func cancelExportsAlert(jobs: Int, quitting: Bool) -> NSAlert {
        let a = NSAlert()
        a.alertStyle = .warning
        if quitting {
            a.messageText = jobs == 1 ? String(localized: "An export is still running. Quit anyway?")
                : String(localized: "\(jobs) exports are still running. Quit anyway?")
            a.informativeText = String(localized: "Quitting cancels the export and deletes its unfinished file.")
            a.addButton(withTitle: String(localized: "Cancel Export and Quit"))
        } else {
            a.messageText = jobs == 1 ? String(localized: "An export is still running. Close anyway?")
                : String(localized: "\(jobs) exports are still running. Close anyway?")
            a.informativeText = String(localized: "Closing the project cancels the export and deletes its unfinished file.")
            a.addButton(withTitle: String(localized: "Cancel Export and Close"))
        }
        a.addButton(withTitle: String(localized: "Keep Exporting"))
        a.buttons.last?.keyEquivalent = "\u{1b}"
        return a
    }
}
