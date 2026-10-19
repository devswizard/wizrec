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
            Form {
                Section("Current word") {
                    Toggle("Highlight the word being spoken", isOn: $style.currentWordEnabled)
                    ColorPicker("Text color", selection: color(\.currentWordColor))
                    ColorPicker("Outline color", selection: color(\.currentWordStrokeColor))
                    slider("Grow", value: $style.currentWordExtraScale, in: 0...1, percent: true)
                    Toggle("Box behind the word", isOn: Binding(
                        get: { style.wordRectangleColor.a > 0 },
                        set: { style.wordRectangleColor.a = $0 ? 1 : 0 }))
                    if style.wordRectangleColor.a > 0 {
                        ColorPicker("Box color", selection: color(\.wordRectangleColor))
                    }
                }
                Section("Other words") {
                    slider("Spoken words opacity", value: $style.pastWordOpacity, in: 0...1, percent: true)
                    slider("Upcoming words opacity", value: $style.futureWordOpacity, in: 0...1, percent: true)
                    Toggle("Start a new block at each sentence", isOn: $style.newParagraphForEachSentence)
                }
                Section("Background") {
                    Toggle("Background behind the caption", isOn: Binding(
                        get: { style.backgroundFillColor.a > 0 },
                        set: { style.backgroundFillColor.a = $0 ? 0.6 : 0 }))
                    if style.backgroundFillColor.a > 0 {
                        ColorPicker("Background color", selection: color(\.backgroundFillColor))
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Reset to Defaults") { style = DynamicCaptionStyle() }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Apply") { apply(style) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 560)
    }

    private func slider(_ title: LocalizedStringKey, value: Binding<Double>, in range: ClosedRange<Double>,
                        percent: Bool) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range).accessibilityLabel(title)
                Text(percent ? "\(Int((value.wrappedValue * 100).rounded())) %" : String(format: "%.2f", value.wrappedValue))
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
