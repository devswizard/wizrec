import Captions
import SwiftUI

/// Captions ▸ Dynamic Caption Style…: edits the selected dynamic-caption callout's
/// `DynamicCaptionStyle`. Apply writes it as one undo step (`SetDynamicCaptionStyle`).
struct CaptionStyleView: View {
    @State var style: DynamicCaptionStyle
    let apply: (DynamicCaptionStyle) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dynamic Caption Style").font(.title3.weight(.semibold))
            ScrollView { CaptionStyleControls(style: $style).padding(.vertical, 4) }
            HStack {
                Button("Reset to Defaults") { style = DynamicCaptionStyle() }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Apply") { apply(style) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400, height: 520)
    }
}

/// Inspector section for a selected dynamic caption: edits a draft of its style; Apply writes
/// the draft as one undo step, Revert drops it. The draft follows the clip when the selection
/// or the project (undo/redo) changes.
struct CaptionStyleInspectorSection: View {
    /// The selected caption's style as stored in the project.
    let stored: DynamicCaptionStyle
    /// Selected callout id; a new id resets the draft.
    let clipID: Int64
    let apply: (DynamicCaptionStyle) -> Void
    @State private var draft = DynamicCaptionStyle()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CaptionStyleControls(style: $draft, compact: true)
            HStack {
                Button("Defaults") { draft = DynamicCaptionStyle() }
                    .help("Reset the draft to WizRec's default caption style")
                Spacer()
                Button("Revert") { draft = stored }.disabled(draft == stored)
                Button("Apply") { apply(draft) }.disabled(draft == stored)
            }
            .controlSize(.small)
        }
        .onAppear { draft = stored }
        .onChange(of: clipID) { _, _ in draft = stored }
        .onChange(of: stored) { _, new in draft = new }
    }
}

/// The style's controls, grouped by what they affect. Used by the sheet and the inspector.
struct CaptionStyleControls: View {
    @Binding var style: DynamicCaptionStyle
    /// Inspector layout: smaller controls, shorter labels.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 16) {
            group("Current word") {
                Toggle("Highlight the word being spoken", isOn: $style.currentWordEnabled)
                ColorPicker("Text color", selection: color(\.currentWordColor))
                ColorPicker("Outline color", selection: color(\.currentWordStrokeColor))
                slider("Grow", value: $style.currentWordExtraScale, in: 0...1)
                Toggle("Box behind the word", isOn: Binding(
                    get: { style.wordRectangleColor.a > 0 },
                    set: { style.wordRectangleColor.a = $0 ? 1 : 0 }))
                if style.wordRectangleColor.a > 0 {
                    ColorPicker("Box color", selection: color(\.wordRectangleColor))
                }
            }
            group("Other words") {
                slider("Spoken words opacity", value: $style.pastWordOpacity, in: 0...1)
                slider("Upcoming words opacity", value: $style.futureWordOpacity, in: 0...1)
                Toggle("Start a new block at each sentence", isOn: $style.newParagraphForEachSentence)
            }
            group("Background") {
                Toggle("Background behind the caption", isOn: Binding(
                    get: { style.backgroundFillColor.a > 0 },
                    set: { style.backgroundFillColor.a = $0 ? 0.6 : 0 }))
                if style.backgroundFillColor.a > 0 {
                    ColorPicker("Background color", selection: color(\.backgroundFillColor))
                }
            }
        }
        .controlSize(compact ? .small : .regular)
        .font(compact ? .callout : .body)
    }

    private func group(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(compact ? .caption.weight(.semibold) : .headline).foregroundStyle(.secondary)
            content()
        }
        .accessibilityElement(children: .contain)
    }

    private func slider(_ title: LocalizedStringKey, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            HStack {
                Slider(value: value, in: range).accessibilityLabel(Text(title))
                Text("\(Int((value.wrappedValue * 100).rounded())) %")
                    .font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
            }
        }
    }

    private func color(_ key: WritableKeyPath<DynamicCaptionStyle, CaptionColor>) -> Binding<Color> {
        Binding(
            get: { let c = style[keyPath: key]; return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: max(c.a, 0.01)) },
            set: { new in
                guard let c = NSColor(new).usingColorSpace(.sRGB) else { return }
                let a = style[keyPath: key].a
                style[keyPath: key] = CaptionColor(c.redComponent, c.greenComponent, c.blueComponent, a > 0 ? c.alphaComponent : a)
            })
    }
}
