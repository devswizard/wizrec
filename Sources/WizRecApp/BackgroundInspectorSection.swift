import AppKit
import PlayerKit
import SwiftUI

/// Inspector controls for a shader background's `sourceEffect` parameters
/// (`ShaderInspection`): colour wells, sliders with number fields, switches and x/y fields.
///
/// Sliders preview while dragged and become one undo step on release; typed values, switches
/// and position fields are one step each; a colour becomes one step once the colour panel has
/// been still for a moment. Animated parameters get a keyframe at the playhead. Every control
/// has the accessibility identifier `inspector.background.<name>` (`.x` / `.y` for positions,
/// `.field` for a slider's number field).
struct BackgroundInspectorSection: View {
    let shader: ShaderInspection
    /// Live value while dragging (no undo step yet).
    let preview: (String, [Double]) -> Void
    /// Turns the live value into one undo step.
    let commit: () -> Void
    /// One undo step.
    let set: (String, [Double]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(shader.title).font(.callout.weight(.medium))
            ForEach(shader.items) { item in row(item) }
        }
    }

    @ViewBuilder
    private func row(_ item: ShaderInspection.Item) -> some View {
        switch item.kind {
        case .color:
            BackgroundColorRow(item: item, preview: preview, commit: commit)
        case .toggle:
            HStack {
                Toggle(item.label, isOn: Binding(get: { (item.values.first ?? 0) >= 0.5 },
                                                 set: { set(item.name, [$0 ? 1 : 0]) }))
                    .toggleStyle(.switch).controlSize(.small)
                    .accessibilityIdentifier("inspector.background.\(item.name)")
                animatedMark(item)
            }
        case .position:
            HStack(spacing: 6) {
                label(item.label)
                Spacer()
                ForEach(Array(["x", "y"].enumerated()), id: \.offset) { k, axis in
                    Text(axis.uppercased()).font(.caption).foregroundStyle(.secondary)
                    NumberField(value: item.values.indices.contains(k) ? item.values[k] : 0, unit: "px") { v in
                        var values = item.values
                        if values.indices.contains(k) { values[k] = v }
                        set(item.name, values)
                    }
                    .frame(width: 64)
                    .accessibilityIdentifier("inspector.background.\(item.name).\(axis)")
                    .accessibilityLabel("\(item.label) \(axis.uppercased())")
                }
                animatedMark(item)
            }
        case .number(let range, let unit):
            numberRow(item, range: range, unit: unit)
        }
    }

    private func numberRow(_ item: ShaderInspection.Item, range: ClosedRange<Double>,
                           unit: ShaderInspection.Unit) -> some View {
        let scale: Double = switch unit {
        case .percentage: 100
        case .angle: 180 / Double.pi
        case .plain: 1
        }
        let symbol: String = switch unit {
        case .percentage: "%"
        case .angle: "°"
        case .plain: ""
        }
        let shown: Double = (item.values.first ?? 0) * scale
        let lo: Double = range.lowerBound * scale
        let hi: Double = range.upperBound * scale
        return HStack(spacing: 6) {
            label(item.label)
            Slider(value: Binding(get: { min(max(shown, lo), hi) }, set: { preview(item.name, [$0 / scale]) }),
                   in: lo...hi, onEditingChanged: { editing in if !editing { commit() } })
                .controlSize(.small)
                .accessibilityIdentifier("inspector.background.\(item.name)")
                .accessibilityLabel(item.label)
            NumberField(value: shown, unit: symbol) { set(item.name, [$0 / scale]) }
                .frame(width: 70)
                .accessibilityIdentifier("inspector.background.\(item.name).field")
                .accessibilityLabel(item.label)
            animatedMark(item)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            .frame(width: 64, alignment: .leading).help(text)
    }

    @ViewBuilder
    private func animatedMark(_ item: ShaderInspection.Item) -> some View {
        if item.animated {
            Image(systemName: "diamond.fill").font(.system(size: 8)).foregroundStyle(.orange)
                .help("Animated: edits set a keyframe at the playhead")
                .accessibilityLabel("Animated")
        }
    }
}

/// A colour well for one RGBA background parameter. Changes preview at once and become one
/// undo step after the colour has been still for `settle`, or when the row goes away.
private struct BackgroundColorRow: View {
    let item: ShaderInspection.Item
    let preview: (String, [Double]) -> Void
    let commit: () -> Void
    static let settle: Duration = .milliseconds(400)
    @State private var pending: Task<Void, Never>?

    var body: some View {
        HStack {
            ColorPicker(item.label, selection: binding, supportsOpacity: true)
                .accessibilityIdentifier("inspector.background.\(item.name)")
            if item.animated {
                Image(systemName: "diamond.fill").font(.system(size: 8)).foregroundStyle(.orange)
                    .help("Animated: edits set a keyframe at the playhead")
                    .accessibilityLabel("Animated")
            }
        }
        .onDisappear { flush() }
    }

    private var binding: Binding<Color> {
        Binding(
            get: {
                let v: [Double] = item.values + [0, 0, 0, 1].dropFirst(item.values.count)
                return Color(.sRGB, red: v[0], green: v[1], blue: v[2], opacity: v[3])
            },
            set: { new in
                guard let c = NSColor(new).usingColorSpace(.sRGB) else { return }
                let rgba: [Double] = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
                    .map { min(max(Double($0), 0), 1) }
                preview(item.name, rgba)
                pending?.cancel()
                pending = Task { @MainActor in
                    try? await Task.sleep(for: Self.settle)
                    guard !Task.isCancelled else { return }
                    pending = nil
                    commit()
                }
            })
    }

    private func flush() {
        guard let p = pending else { return }
        p.cancel()
        pending = nil
        commit()
    }
}
