import AppKit
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
    /// The project's frame grid (Clip Speed's Duration field counts frames at its rate).
    var grid = FrameGrid(timebase: .camtasia, fps: Rational(30), duration: 0)
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
    /// New clip speed (1 = normal, two-decimal precision), top-level clips only.
    var setSpeed: (Rational) -> Void
    /// New clip duration (ticks) through Clip Speed (`SetClipDuration`), top-level clips only.
    var setDuration: (Int64) -> Void = { _ in }
    /// New style for the selected dynamic caption: one undo step.
    var setCaptionStyle: (DynamicCaptionStyle) -> Void
    /// Live values of a shader background parameter (`ShaderInspection.Item.name`), no undo step yet;
    /// `commit` makes them one.
    var previewBackground: (String, [Double]) -> Void = { _, _ in }
    /// Shader background parameter values: one undo step.
    var setBackground: (String, [Double]) -> Void = { _, _ in }
}

/// Properties of the selected clip: transform, crop, opacity, volume, and Clip Speed (duration
/// and speed, editable on clips that sit directly on a track).
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
                VStack(spacing: 6) {
                    Text(state.selectionCount > 1 ? "\(state.selectionCount) clips selected" : "No clip selected")
                        .font(.headline).foregroundStyle(.secondary)
                    Text(state.selectionCount > 1
                         ? "Select one clip to see and change its properties."
                         : "Click a clip on the timeline or the canvas to see and change its position, size, crop, opacity, speed and volume.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("inspector.empty")
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
                if state.speedEditable {
                    clipSpeedRow("Duration", id: "inspector.duration",
                                 shown: ClipSpeedFields.durationText(i.duration, grid: state.grid), unit: "",
                                 help: "Clip Speed: type a length (seconds;frames, e.g. 5;11) to speed the clip up or slow it down") { text in
                        guard let t = ClipSpeedFields.durationTicks(text, grid: state.grid), t > 0 else { return false }
                        actions.setDuration(t)
                        return true
                    }
                    clipSpeedRow("Speed", id: "inspector.speed", shown: ClipSpeedFields.speedText(i.speed), unit: "x",
                                 help: "Clip Speed: 2 plays twice as fast, 0.5 at half speed") { text in
                        guard let r = ClipSpeedFields.speed(text) else { return false }
                        actions.setSpeed(r)
                        return true
                    }
                } else {
                    info("Duration", ClipSpeedFields.durationText(i.duration, grid: state.grid))
                    info("Speed", ClipSpeedFields.speedText(i.speed) + "x")
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

    /// A Clip Speed text field: `apply` gets the typed text and returns false to put `shown` back.
    private func clipSpeedRow(_ label: LocalizedStringKey, id: String, shown: String, unit: String, help: LocalizedStringKey,
                              apply: @escaping (String) -> Bool) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Spacer()
            TextEntryField(shown: shown, unit: unit, apply: apply)
                .frame(width: 96)
                .accessibilityLabel(label)
                .accessibilityIdentifier(id)
                .help(help)
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

/// A text field that hands its text to `apply` on Return or focus loss when it differs from
/// `shown`; when `apply` refuses it (false), the field shows `shown` again.
struct TextEntryField: View {
    let shown: String
    let unit: String
    let apply: (String) -> Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 2) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, f in if !f { commit() } }
            if !unit.isEmpty {
                Text(unit).font(.caption).foregroundStyle(.secondary).frame(width: 12, alignment: .leading)
            }
        }
        .onAppear { text = shown }
        .onChange(of: shown) { _, v in if !focused { text = v } }
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t != shown else { return }
        if !apply(t) { NSSound.beep(); text = shown }
    }
}
