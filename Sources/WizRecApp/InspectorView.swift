import Captions
import Observation
import PlayerKit
import RenderEngine
import SwiftUI
import TSCProjKit

/// What the inspector shows; the window controller refreshes it on every project
/// change and playhead move.
@MainActor @Observable
final class InspectorState {
    var inspection: ClipInspection?
    var selectionCount = 0
    var timebase = Timebase.camtasia
    var error: String?
    /// The selected clip sits directly on a track (speed can be changed).
    var speedEditable = false
    /// The selected clip is a dynamic caption: its stored style (nil otherwise).
    var captionStyle: DynamicCaptionStyle?
}

/// Callbacks from the inspector into the window controller.
struct InspectorActions {
    /// Live value while a slider is dragged (no undo step yet).
    var preview: (InspectorField, Double) -> Void
    /// Slider released: the previewed value becomes one undo step.
    var commit: () -> Void
    /// Typed value: one undo step.
    var set: (InspectorField, Double) -> Void
    /// New clip speed (1 = normal), top-level clips only.
    var setSpeed: (Double) -> Void
    /// New style for the selected dynamic caption: one undo step.
    var setCaptionStyle: (DynamicCaptionStyle) -> Void
    /// Live values of a shader background parameter (`ShaderInspection.Item.name`), no undo step yet;
    /// `commit` makes them one.
    var previewBackground: (String, [Double]) -> Void = { _, _ in }
    /// Shader background parameter values: one undo step.
    var setBackground: (String, [Double]) -> Void = { _, _ in }
}

/// Properties of the selected clip: transform, crop, opacity, volume; speed read-only.
struct InspectorView: View {
    let state: InspectorState
    let actions: InspectorActions

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Properties").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if let i = state.inspection {
                ScrollView { content(i).padding(12) }
            } else {
                Text(state.selectionCount > 1 ? "\(state.selectionCount) clips selected" : "Select a clip on the canvas or timeline")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            }
            if let e = state.error {
                Text(e).font(.caption).foregroundStyle(.red).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(_ i: ClipInspection) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Clip") {
                info("Name", i.name.isEmpty ? "—" : i.name)
                info("Type", Self.typeLabel(i.typeName))
                info("Start", state.timebase.timecode(i.start))
                info("Duration", state.timebase.timecode(i.duration))
                if state.speedEditable {
                    HStack(spacing: 6) {
                        Text("Speed").font(.callout).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                        Spacer()
                        NumberField(value: i.speed * 100, unit: "%") { actions.setSpeed($0 / 100) }
                            .frame(width: 70)
                    }
                } else {
                    info("Speed", String(format: "%.0f%%", i.speed * 100))
                }
            }
            if i.visualClipID != nil {
                section("Transform") {
                    row(i, .positionX, "X", unit: "px", scale: 1, range: -4000...4000, step: 1)
                    row(i, .positionY, "Y", unit: "px", scale: 1, range: -4000...4000, step: 1)
                    row(i, .scale, "Scale", unit: "%", scale: 100, range: 0...400, step: 1)
                    row(i, .rotation, "Rotation", unit: "°", scale: 180 / .pi, range: -180...180, step: 1)
                }
                section("Crop") {
                    row(i, .cropLeft, "Left", unit: "%", scale: 100, range: 0...100, step: 1)
                    row(i, .cropTop, "Top", unit: "%", scale: 100, range: 0...100, step: 1)
                    row(i, .cropRight, "Right", unit: "%", scale: 100, range: 0...100, step: 1)
                    row(i, .cropBottom, "Bottom", unit: "%", scale: 100, range: 0...100, step: 1)
                }
                section("Visual") {
                    row(i, .opacity, "Opacity", unit: "%", scale: 100, range: 0...100, step: 1)
                }
            }
            if let shader = i.shader, !shader.items.isEmpty {
                section("Background") {
                    BackgroundInspectorSection(shader: shader, preview: actions.previewBackground,
                                               commit: actions.commit, set: actions.setBackground)
                }
            }
            if let style = state.captionStyle {
                section("Dynamic Caption") {
                    CaptionStyleInspectorSection(stored: style, clipID: i.clipID, apply: actions.setCaptionStyle)
                }
            }
            if i.audioClipID != nil {
                section("Audio") {
                    row(i, .volume, "Volume", unit: "%", scale: 100, range: 0...200, step: 1)
                    if let g = i.gain { info("Gain", String(format: "%.0f%%", g * 100)) }
                }
            }
            if !i.effects.isEmpty {
                section("Effects") {
                    ForEach(Array(i.effects.enumerated()), id: \.offset) { _, e in
                        HStack {
                            Text(e.name).font(.callout)
                            Spacer()
                            if e.bypassed {
                                Text("off").font(.caption).foregroundStyle(.secondary)
                            } else if !Compositor.renderedEffects.contains(e.name) {
                                Text("not previewed").font(.caption).foregroundStyle(.orange)
                                    .help("WizRec keeps this effect in the project but does not draw it yet.")
                            }
                        }
                    }
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder _ body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            body()
        }
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).font(.callout.monospacedDigit()).textSelection(.enabled)
            Spacer()
        }
    }

    /// Slider + numeric field. `scale` converts the stored value to the shown unit.
    private func row(_ i: ClipInspection, _ f: InspectorField, _ label: String, unit: String, scale: Double,
                     range: ClosedRange<Double>, step: Double) -> some View {
        let stored = i.values[f] ?? f.defaultValue
        let shown = stored * scale
        return HStack(spacing: 6) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Slider(value: Binding(get: { min(max(shown, range.lowerBound), range.upperBound) },
                                  set: { actions.preview(f, $0 / scale) }),
                   in: range, onEditingChanged: { editing in if !editing { actions.commit() } })
                .controlSize(.small)
            NumberField(value: shown, unit: unit) { actions.set(f, $0 / scale) }
                .frame(width: 70)
            if i.animated.contains(f) {
                Image(systemName: "diamond.fill").font(.system(size: 8)).foregroundStyle(.orange)
                    .help("Animated: edits set a keyframe at the playhead")
                    .accessibilityLabel("Animated")
            }
        }
    }

    static func typeLabel(_ t: String) -> String {
        switch t {
        case "UnifiedMedia": "Video + audio"
        case "VMFile": "Video"
        case "ScreenVMFile": "Screen recording"
        case "AMFile": "Audio"
        case "IMFile": "Image"
        case "StitchedMedia": "Stitched media"
        case "Group": "Group"
        case "Callout": "Annotation"
        default: t
        }
    }
}

/// A numeric text field that reports a new value on Return or focus loss.
struct NumberField: View {
    let value: Double
    let unit: String
    let onSet: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 2) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit(apply)
                .onChange(of: focused) { _, f in if !f { apply() } }
            Text(unit).font(.caption).foregroundStyle(.secondary).frame(width: 18, alignment: .leading)
        }
        .onAppear { text = Self.format(value) }
        .onChange(of: value) { _, v in if !focused { text = Self.format(v) } }
    }

    private func apply() {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let v = Double(t) else { text = Self.format(value); return }
        if abs(v - value) > 1e-9 { onSet(v) }
    }

    static func format(_ v: Double) -> String {
        abs(v - v.rounded()) < 0.005 ? String(Int(v.rounded())) : String(format: "%.2f", v)
    }
}
