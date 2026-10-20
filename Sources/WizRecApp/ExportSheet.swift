import AppKit
import Exporter
import PlayerKit
import SwiftUI

/// What the export sheet asks the editor to queue.
struct ExportRequest {
    enum Scope: String, CaseIterable, Identifiable {
        case timeline, selection
        var id: String { rawValue }
    }
    var presets: [ExportPreset]
    var scope: Scope
    var includeAudio: Bool
    var folder: URL
    var baseName: String
    /// Longest output side override, px (0 = the preset's size).
    var maxSide: Int = 0
    /// Frame rate override (0 = the preset's / project rate).
    var fps: Int = 0
    var gifDither = true
    var gifLoop = true
}

/// UI state of the sheet (kept by the editor so choices survive reopening).
@MainActor @Observable
final class ExportSheetState {
    var selected: Set<String> = ["MP4 1080p (H.264)"]
    var scope: ExportRequest.Scope = .timeline
    var includeAudio = true
    var baseName = ""
    var maxSide = 0
    var fps = 0
    var gifDither = true
    var gifLoop = true
    var folder: URL = {
        if let p = UserDefaults.standard.string(forKey: "WizRec.ExportFolder") { return URL(fileURLWithPath: p) }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
    }() {
        didSet { UserDefaults.standard.set(folder.path, forKey: "WizRec.ExportFolder") }
    }
}

/// File ▸ Export…: pick presets (several = batch), range, audio and destination; queued jobs
/// show progress with cancel and reveal.
struct ExportSheet: View {
    let presets: [ExportPreset]
    let state: ExportSheetState
    let queue: ExportQueue
    let hasSelection: Bool
    let export: (ExportRequest) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export").font(.title2.weight(.semibold))
            if presets.isEmpty {
                Text("Export is not available in this build.").foregroundStyle(.secondary)
            } else {
                settings
            }
            if !queue.jobs.isEmpty { jobs }
            HStack {
                if queue.isRunning {
                    Button("Cancel All") { queue.cancelAll() }.accessibilityIdentifier("export.cancelAll")
                }
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("export.close")
                Button("Export") {
                    export(ExportRequest(presets: presets.filter { state.selected.contains($0.name) },
                                         scope: hasSelection ? state.scope : .timeline,
                                         includeAudio: state.includeAudio, folder: state.folder,
                                         baseName: state.baseName, maxSide: state.maxSide, fps: state.fps,
                                         gifDither: state.gifDither, gifLoop: state.gifLoop))
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("export.start")
                .disabled(state.selected.isEmpty || presets.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .frame(minHeight: 420)
    }

    private var settings: some View {
        @Bindable var s = state
        return VStack(alignment: .leading, spacing: 10) {
            Text("Formats").font(.headline)
            Text("Choose one or more; each becomes its own file.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(presets, id: \.name) { p in
                        Toggle(p.name, isOn: Binding(
                            get: { state.selected.contains(p.name) },
                            set: { on in if on { state.selected.insert(p.name) } else { state.selected.remove(p.name) } }))
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("export.preset.\(p.name)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 150)
            Picker("Range", selection: $s.scope) {
                Text("Whole timeline").tag(ExportRequest.Scope.timeline)
                Text("Selected clips").tag(ExportRequest.Scope.selection)
            }
            .pickerStyle(.segmented)
            .disabled(!hasSelection)
            HStack {
                Picker("Resolution", selection: $s.maxSide) {
                    Text("As preset").tag(0)
                    Text("4K (3840)").tag(3840)
                    Text("1080p (1920)").tag(1920)
                    Text("720p (1280)").tag(1280)
                    Text("480p (854)").tag(854)
                }
                Picker("Frame rate", selection: $s.fps) {
                    Text("As preset").tag(0)
                    Text("24 fps").tag(24)
                    Text("25 fps").tag(25)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
            }
            Toggle("Include audio", isOn: $s.includeAudio)
            if presets.contains(where: { state.selected.contains($0.name) && { if case .gif = $0.settings.format { true } else { false } }($0) }) {
                HStack {
                    Toggle("GIF: dither colours", isOn: $s.gifDither)
                    Toggle("GIF: loop forever", isOn: $s.gifLoop)
                }
            }
            LabeledContent("File name") {
                TextField("File name", text: $s.baseName).labelsHidden()
            }
            LabeledContent("Save to") {
                HStack {
                    Text(state.folder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { chooseFolder() }
                }
            }
        }
    }

    private var jobs: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Text("Exports").font(.headline)
                Spacer()
                if queue.jobs.count > 1, queue.isRunning {
                    ProgressView(value: queue.overallProgress).frame(width: 120)
                        .accessibilityLabel("Overall progress")
                }
                if !queue.isRunning { Button("Clear") { queue.clearFinished() }.controlSize(.small) }
            }
            ForEach(queue.jobs) { job in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.output.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text(job.name).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    status(job)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private func status(_ job: ExportQueue.Job) -> some View {
        switch job.state {
        case .waiting:
            Text("Waiting").foregroundStyle(.secondary)
            Button("Cancel") { queue.cancel(job.id) }.controlSize(.small)
        case .running(let p):
            ProgressView(value: p).frame(width: 120).accessibilityLabel("Progress")
            Button("Cancel") { queue.cancel(job.id) }.controlSize(.small)
        case .done:
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.output]) }.controlSize(.small)
        case .failed(let m):
            Text("Failed").foregroundStyle(.red).help(m)
        case .cancelled:
            Text("Cancelled").foregroundStyle(.secondary)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = state.folder
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url { state.folder = url }
    }
}
