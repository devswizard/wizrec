import Captions
import PlayerKit
import SwiftUI
import TimelineUI

/// What the Captions tab asks the editor to do.
struct CaptionActions {
    /// Transcribe the selected audio (when needed) and write classic captions from the words.
    var generate: () -> Void = {}
    /// One caption at the playhead with placeholder text.
    var addAtPlayhead: () -> Void = {}
    var importFile: () -> Void = {}
    var exportSRT: () -> Void = {}
    /// New text for a caption (one undo step).
    var setText: (CaptionCue, String) -> Void = { _, _ in }
    var delete: (CaptionCue) -> Void = { _ in }
    /// Move the playhead to a time, seconds.
    var seek: (Double) -> Void = { _ in }
}

/// Sidebar ▸ Captions (ui-workflow.md §5–§6, §12 item 9; our own layout): a short how-to, the
/// two ways to get captions (generate from speech, add at the playhead), import/export, every
/// caption as an editable row, and the dynamic caption styles (drag onto a clip with audio, or
/// double-click).
struct CaptionsPanel: View {
    let model: EditorDocumentModel
    let actions: CaptionActions
    let apply: (LibraryItem.Kind, String) -> Bool
    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 8)]

    var body: some View {
        let _ = model.revision
        let cues = ClassicCaptions.cues(in: model.project)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("1. Select a clip with audio on the timeline.\n2. Generate captions from its speech, or add one at the playhead.\n3. Type into a caption below to change it; click its time to go there.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Generate Captions", action: actions.generate)
                        .accessibilityIdentifier("captions.generate")
                        .help("Transcribe the selected audio and add captions from the words")
                    Button("Add at Playhead", action: actions.addAtPlayhead)
                        .accessibilityIdentifier("captions.addAtPlayhead")
                }
                HStack {
                    Button("Import…", action: actions.importFile).accessibilityIdentifier("captions.import")
                    Button("Export SRT…", action: actions.exportSRT).disabled(cues.isEmpty)
                        .accessibilityIdentifier("captions.export")
                }
                Divider()
                Text("Captions (\(cues.count))").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                if cues.isEmpty {
                    Text("No captions yet.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(cues.enumerated()), id: \.offset) { i, cue in
                    CaptionRow(cue: cue, index: i, actions: actions)
                        .id("\(i)-\(cue.start)-\(cue.end)-\(cue.text)")
                }
                Divider()
                Text("Dynamic caption styles").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text("Drag a style onto a clip with audio, or double-click it to caption the selected audio at the playhead.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(DynamicCaptionPreset.all, id: \.presetID) { styleTile($0) }
                }
            }
            .padding(10)
        }
    }

    private func styleTile(_ p: DynamicCaptionPreset) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12))
                Image(systemName: "captions.bubble").font(.system(size: 22)).foregroundStyle(Color.accentColor)
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            Text(p.displayName).font(.caption).lineLimit(2).multilineTextAlignment(.center)
        }
        .contentShape(Rectangle())
        .help(p.displayName)
        .onTapGesture(count: 2) { if !apply(.captionStyle, p.presetID) { NSSound.beep() } }
        .onDrag { LibraryList.provider(type: TimelineView.captionStyleType.rawValue, name: p.presetID) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(p.displayName)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("captionStyle.\(p.presetID)")
        .accessibilityAction { _ = apply(.captionStyle, p.presetID) }
    }
}

/// One caption: its time (click: go there), its text (Return or leaving the field: apply), delete.
private struct CaptionRow: View {
    let cue: CaptionCue
    let index: Int
    let actions: CaptionActions
    @State private var text: String
    @FocusState private var focused: Bool

    init(cue: CaptionCue, index: Int, actions: CaptionActions) {
        self.cue = cue; self.index = index; self.actions = actions
        _text = State(initialValue: cue.text)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button(Self.time(cue.start)) { actions.seek(cue.start) }
                .buttonStyle(.link).font(.caption.monospacedDigit())
                .help("Go to this caption")
            TextField("Caption text", text: $text)
                .textFieldStyle(.roundedBorder).font(.callout)
                .focused($focused)
                .onSubmit { actions.setText(cue, text) }
                .onChange(of: focused) { _, now in if !now { actions.setText(cue, text) } }
                .accessibilityIdentifier("captions.text.\(index)")
            Button { actions.delete(cue) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Delete this caption")
                .accessibilityLabel("Delete caption")
        }
    }

    /// `m:ss.t`.
    static func time(_ s: Double) -> String {
        let t = max(0, s)
        let m = Int(t) / 60
        let rest = t - Double(m * 60)
        return String(format: "%d:%04.1f", m, rest)
    }
}
