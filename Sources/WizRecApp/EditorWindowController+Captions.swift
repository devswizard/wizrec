import AppKit
import Captions
import PlayerKit
import SwiftUI
import TSCProjKit
import UniformTypeIdentifiers

/// Captions menu: transcribe selected audio (local speech recognition), dynamic captions,
/// SRT/VTT import and export, delete captions. Every project change is one undo step.
extension EditorWindowController {
    private var captionTargets: [CaptionTarget] {
        CaptionTarget.find(in: model.project, selection: timelineModel.selection)
    }

    /// Captions ▸ Transcribe Selected Audio: words go onto each selected audio clip's source track.
    @objc func transcribeSelection(_ sender: Any?) {
        let targets = captionTargets
        guard !targets.isEmpty else {
            ui.show(String(localized: "Select an audio clip, or a clip with audio, on the timeline."))
            return
        }
        transcription = Task { [weak self] in await self?.transcribe(targets) }
    }

    @objc func cancelTranscription(_ sender: Any?) {
        transcription?.cancel()
    }

    private func transcribe(_ targets: [CaptionTarget]) async {
        defer { transcription = nil; ui.activity = nil }
        let backend = TranscriptionBackends.preferred()
        var status = await backend.status(language: nil)
        if status == .needsPermission, backend.id == AppleSpeechRecognizer().id {
            // Without the usage string the system kills the process on request (bare `swift run`).
            guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
                ui.show(String(localized: "Transcription needs the WizRec app bundle (scripts/make-app.sh)."), seconds: 10)
                return
            }
            status = await backend.requestAccess()
        }
        guard status == .ready else {
            ui.show(Self.describe(status, backend: backend.id), seconds: 12)
            return
        }
        let transcriber = Transcriber(backend: backend)
        var done = 0
        for (i, t) in targets.enumerated() {
            guard !Task.isCancelled, let source = model.project.source(id: t.sourceID) else { break }
            let url = model.url(of: source)
            let name = url.lastPathComponent
            let prefix = targets.count > 1 ? "(\(i + 1)/\(targets.count)) " : ""
            ui.activity = String(localized: "Transcribing \(prefix)\(name)…")
            do {
                let media = try await model.thumbnailPool.source(for: url)
                let words = try await transcriber.transcribe(media, stream: t.track, language: nil) { [weak self] p in
                    Task { @MainActor in
                        guard self?.transcription != nil else { return }
                        self?.ui.activity = String(localized: "Transcribing \(prefix)\(name)… \(Int(p * 100))%")
                    }
                }
                try Task.checkCancellation()
                run(String(localized: "Transcribe")) {
                    try model.perform(ApplyTranscription(sourceID: t.sourceID, track: t.track, words: words))
                    done += 1
                }
            } catch is CancellationError {
                break
            } catch {
                ui.show(String(localized: "Cannot transcribe \(name): \(Self.describe(error))"), seconds: 12)
            }
        }
        if Task.isCancelled {
            ui.show(String(localized: "Transcription cancelled."))
        } else if done > 0 {
            ui.show(String(localized: "Transcribed. Captions ▸ Add Dynamic Captions shows the words on the canvas."), seconds: 8)
        }
    }

    /// The status as a message; whisper.cpp's own texts already say what is missing.
    static func describe(_ status: BackendStatus, backend: String) -> String {
        guard backend == WhisperCppRecognizer().id else { return describe(status) }
        switch status {
        case .ready: return String(localized: "whisper.cpp is ready.")
        case .modelMissing(let m):
            return String(localized: "whisper.cpp needs a model: \(m). Settings ▸ Captions shows the models folder.")
        case .languageUnsupported(let l):
            return String(localized: "The selected whisper.cpp model is English-only and cannot transcribe \(l).")
        case .unavailable(let m): return String(localized: "whisper.cpp is unavailable: \(m)")
        case .needsPermission, .permissionDenied: return describe(status)
        }
    }

    static func describe(_ status: BackendStatus) -> String {
        switch status {
        case .ready: String(localized: "Speech recognition is ready.")
        case .needsPermission, .permissionDenied:
            String(localized: "WizRec may not use speech recognition. Allow it in System Settings ▸ Privacy & Security ▸ Speech Recognition.")
        case .modelMissing(let m): String(localized: "Speech recognition needs a download: \(m)")
        case .languageUnsupported(let l): String(localized: "Speech recognition does not support \(l).")
        case .unavailable(let m): String(localized: "Speech recognition is unavailable: \(m)")
        }
    }

    /// Captions ▸ Add Dynamic Captions: a caption callout over each selected, transcribed audio clip.
    @objc func addDynamicCaptions(_ sender: Any?) {
        let targets = captionTargets
        guard !targets.isEmpty else {
            ui.show(String(localized: "Select a transcribed audio clip on the timeline."))
            return
        }
        for t in targets {
            guard !Transcript.words(in: model.project, sourceID: t.sourceID, track: t.track).isEmpty else {
                ui.show(String(localized: "Transcribe the clip first (Captions ▸ Transcribe Selected Audio)."))
                continue
            }
            let c = AddDynamicCaption(audioClipID: t.clipID)
            run(String(localized: "Add Dynamic Captions")) { try model.perform(c) }
            if let id = c.calloutID { select([id]) }
        }
    }

    /// The selected dynamic-caption callout (top level) and its style.
    var selectedDynamicCaption: (id: Int64, style: DynamicCaptionStyle)? {
        guard timelineModel.selection.count == 1, let id = timelineModel.selection.first,
              let clip = model.project.tracks.flatMap(\.clips).first(where: { $0.id == id }), clip.kind == .callout,
              let def = clip.object["def"]?.object, DynamicCaptionStyle.isDynamicCaption(def) else { return nil }
        return (id, DynamicCaptionStyle(def: def))
    }

    /// Inspector ▸ Dynamic Caption ▸ Apply: the selected caption's new style, one undo step.
    func setSelectedCaptionStyle(_ new: DynamicCaptionStyle) {
        guard let (id, old) = selectedDynamicCaption, new != old else { return }
        run(String(localized: "Change Caption Style")) {
            try model.perform(SetDynamicCaptionStyle(clipID: id, style: new))
        }
    }

    /// Captions ▸ Dynamic Caption Style…: a sheet editing the selected dynamic caption.
    @objc func editDynamicCaptionStyle(_ sender: Any?) {
        guard let window, let (id, style) = selectedDynamicCaption else {
            ui.show(String(localized: "Select a dynamic caption on the timeline."))
            return
        }
        var sheet: NSWindow?
        let close = { [weak window] in if let s = sheet { window?.endSheet(s) } }
        let view = CaptionStyleView(style: style, apply: { [weak self] new in
            close()
            guard let self, new != style else { return }
            self.run(String(localized: "Change Caption Style")) {
                try self.model.perform(SetDynamicCaptionStyle(clipID: id, style: new))
            }
        }, cancel: close)
        let s = NSWindow(contentViewController: NSHostingController(rootView: view))
        sheet = s
        window.beginSheet(s)
    }

    /// Captions ▸ Import Captions…: SRT or WebVTT cues become classic captions.
    @objc func importCaptions(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt"), UTType(filenameExtension: "vtt")].compactMap { $0 }
        panel.message = String(localized: "Choose an SRT or WebVTT caption file.")
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.importCaptions(from: url) }
        }
    }

    func importCaptions(from url: URL) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let c = try CaptionFiles.importCommand(text)
            var ok = false
            run(String(localized: "Import Captions")) { try model.perform(c); ok = true }
            guard ok else { return }
            let dropped = c.droppedCues.count
            ui.show(dropped == 0 ? String(localized: "Imported \(c.cues.count) captions from \(url.lastPathComponent).")
                    : String(localized: "Imported captions; \(dropped) fall outside any audio clip and were skipped."))
        } catch {
            ui.show(String(localized: "Cannot import \(url.lastPathComponent): \(Self.describe(error))"), seconds: 10)
        }
    }

    @objc func exportCaptionsSRT(_ sender: Any?) { exportCaptions(ext: "srt") }
    @objc func exportCaptionsVTT(_ sender: Any?) { exportCaptions(ext: "vtt") }

    private func exportCaptions(ext: String) {
        guard let window else { return }
        let text = ext == "srt" ? CaptionFiles.srt(model.project) : CaptionFiles.vtt(model.project)
        let panel = NSSavePanel()
        if let t = UTType(filenameExtension: ext) { panel.allowedContentTypes = [t] }
        let base = (model.bundle.directory.lastPathComponent as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base).\(ext)"
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    try Data(text.utf8).write(to: url, options: .atomic)
                    self?.ui.show(String(localized: "Exported captions to \(url.lastPathComponent)."))
                } catch {
                    self?.ui.show(String(localized: "Cannot export captions: \(Self.describe(error))"))
                }
            }
        }
    }

    /// Captions ▸ Delete All Captions: removes every classic caption.
    @objc func deleteCaptions(_ sender: Any?) {
        run(String(localized: "Delete Captions")) { try model.perform(RemoveCaptions()) }
    }

    /// Menu validation for the Captions menu; nil when `action` is not a captions action.
    func validateCaptionsItem(_ action: Selector) -> Bool? {
        switch action {
        case #selector(transcribeSelection(_:)): return transcription == nil && !captionTargets.isEmpty
        case #selector(cancelTranscription(_:)): return transcription != nil
        case #selector(addDynamicCaptions(_:)): return !captionTargets.isEmpty
        case #selector(editDynamicCaptionStyle(_:)): return selectedDynamicCaption != nil
        case #selector(exportCaptionsSRT(_:)), #selector(exportCaptionsVTT(_:)):
            return !CaptionFiles.cues(in: model.project).isEmpty
        case #selector(deleteCaptions(_:)): return !ClassicCaptions.cues(in: model.project).isEmpty
        case #selector(importCaptions(_:)): return true
        default: return nil
        }
    }
}
