import AppKit
import AudioEngine
import Exporter
import MediaEngine
import PlayerKit
import RenderEngine
import SwiftUI

/// One queued export: the settings and the project snapshot it renders.
struct ExportJobSpec {
    var settings: ExportSettings
    var scene: SceneModel
    var audio: AudioScene
}

extension EditorWindowController {
    /// File extension of an export format's output.
    static func fileExtension(_ f: ExportFormat) -> String {
        switch f {
        case .mp4: "mp4"
        case .mov: "mov"
        case .gif: "gif"
        case .audio(let c): c.lowercased() == "aac" ? "m4a" : c.lowercased()
        }
    }

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
            var s = p.settings
            s.range = range
            if !r.includeAudio { s.includeAudio = false }
            let out = ExportNaming.uniqueURL(directory: r.folder, base: base, ext: Self.fileExtension(s.format), reserved: reserved)
            reserved.insert(out.standardizedFileURL)
            let id = exportQueue.add(name: p.name, output: out)
            exportSpecs[id] = ExportJobSpec(settings: s, scene: model.scene, audio: model.audioScene)
        }
    }

    /// The queue's runner: one `ExportSession` per job on a pool separate from playback.
    static func makeExportQueue(specs: @escaping @MainActor (Int) -> ExportJobSpec?,
                                pool: @escaping @MainActor () -> MediaPool) -> ExportQueue {
        ExportQueue { id, output, progress in
            guard let spec = specs(id) else { throw ExportError.failed("job \(id) has no settings") }
            let session = ExportSession(scene: spec.scene, audio: spec.audio, pool: pool(), settings: spec.settings,
                                        output: output)
            let poll = Task {
                while !Task.isCancelled {
                    progress(await session.progress)
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            defer { poll.cancel() }
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
