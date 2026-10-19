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
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: view))
        exportSheet = sheet
        window.beginSheet(sheet)
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
                    Task { await session.cancel() }
                }
                progress(1)
            } catch ExportError.cancelled {
                throw CancellationError()
            }
        }
    }
}
