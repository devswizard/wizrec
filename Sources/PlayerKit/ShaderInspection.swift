import Foundation
import TimelineEngine
import TSCProjKit
import WizRecAssets

/// The adjustable parameters of a shader background clip (`.tscshadervid`, WizRec's or the
/// user's own), for the inspector: one item per `effectDef` entry, valued from the clip's
/// `sourceEffect` at the playhead (`docs/specs/shader-backgrounds.md` §3, §6).
///
/// Colours are 0–1 RGBA, numbers in the file's units (radians for angles), positions in
/// pixels of the 1920×1080 frame.
public struct ShaderInspection: Equatable, Sendable {
    /// How a parameter is edited.
    public enum Kind: Equatable, Sendable {
        /// RGBA, four clip keys (`-red`, `-green`, `-blue`, `-alpha`).
        case color
        /// One number within `range` (file units).
        case number(range: ClosedRange<Double>, unit: Unit)
        /// A WizRec on/off switch (0 or 1).
        case toggle
        /// x and y in frame pixels, two clip keys (`.x`, `.y`).
        case position
    }

    /// Display unit of a number.
    public enum Unit: Equatable, Sendable {
        case plain
        /// A 0–1 fraction shown ×100 as %.
        case percentage
        /// Radians shown in degrees.
        case angle
    }

    /// One parameter.
    public struct Item: Equatable, Sendable, Identifiable {
        /// `effectDef` name, e.g. `Color0`, `Speed`, `Pos`.
        public var name: String
        /// What the user sees.
        public var label: String
        public var kind: Kind
        /// Clip-side `sourceEffect` keys, in value order.
        public var keys: [String]
        /// Values of `keys` at the playhead.
        public var values: [Double]
        /// Any key has keyframes (edits then set a keyframe at the playhead).
        public var animated: Bool
        public var id: String { name }
    }

    /// The background clip (top-level or nested).
    public var clipID: Int64
    /// Display name of the background (WizRec library name, the file's `name`, or the file name).
    public var title: String
    public var items: [Item]
    /// Clip media time at the playhead (ticks) for keyframe edits; nil outside the clip or nested.
    public var keyframeTime: Int64?

    /// `SetSourceEffectParameters` changes that give item `name` the values `values`
    /// (keyframes at the playhead when the item is animated). Values beyond `keys` are ignored.
    public func changes(_ name: String, _ values: [Double]) -> [SourceEffectChange] {
        guard let item = items.first(where: { $0.name == name }) else { return [] }
        let kf = item.animated ? keyframeTime : nil
        return zip(item.keys, values).map { SourceEffectChange($0, $1, keyframeAt: kf) }
    }

    /// `changes(_:_:)` as editor parameter changes (`EditorDocumentModel.preview` / `set`).
    public func parameterChanges(_ name: String, _ values: [Double]) -> [EditorDocumentModel.ParameterChange] {
        changes(name, values).map { EditorDocumentModel.ParameterChange.sourceEffect(clipID: clipID, $0) }
    }

    /// The inspection of `clip` when it plays a shader background; nil otherwise. `source` is its
    /// `sourceBin` entry; `at` the clip media time (ticks) to evaluate.
    @MainActor
    public static func make(clip: Clip, source: SourceMedia?, at t: Int64, keyframeTime: Int64?) -> ShaderInspection? {
        let se = clip.object["sourceEffect"]?.object
        let isShader = source?.src.lowercased().hasSuffix(".tscshadervid") == true
        guard se != nil || isShader else { return nil }
        let params = Parameters(se?["parameters"]?.object ?? JSONObject())
        let fileName = ((source?.src ?? "") as NSString).lastPathComponent
        let asset = AssetCatalog.backgrounds.first { $0.fileName == fileName }
        let defs = source?.object["effectDef"]?.array?.items.compactMap(\.object) ?? []
        var items = defs.isEmpty ? itemsFromClip(params) : itemsFromDef(defs)
        for i in items.indices {
            let assetParam = asset?.parameters.first { $0.name == items[i].name }
            if let p = assetParam {
                items[i].label = p.displayName
                if p.kind == .bool { items[i].kind = .toggle }
            }
            let defaults = items[i].values
            items[i].values = items[i].keys.enumerated().map { k, key in
                params.value(key, at: t, default: defaults.indices.contains(k) ? defaults[k] : 0)
            }
            items[i].animated = items[i].keys.contains { params[$0]?.isAnimated ?? false }
        }
        let title = asset?.displayName ?? (fileName as NSString).deletingPathExtension
        return ShaderInspection(clipID: clip.id, title: title, items: items, keyframeTime: keyframeTime)
    }

    /// Items from the source's `effectDef` (SH2 numeric form); `values` hold the defaults.
    private static func itemsFromDef(_ defs: [JSONObject]) -> [Item] {
        defs.compactMap { e -> Item? in
            guard let name = e["name"]?.string else { return nil }
            let label = LibrarySearch.words(ofIdentifier: name)
            let dv = e["defaultValue"]
            switch e["type"]?.string {
            case "Color":
                let c = (dv?.array?.items ?? []).map { $0.double ?? 0 }
                let rgba = (0..<4).map { c.indices.contains($0) ? c[$0] : ($0 == 3 ? 1 : 0) }
                return Item(name: name, label: label, kind: .color, keys: colorKeys(name), values: rgba, animated: false)
            case "Position":
                let p = (dv?.array?.items ?? []).map { $0.double ?? 0 }
                let xy = [p.first ?? 0, p.count > 1 ? p[1] : 0]
                return Item(name: name, label: label, kind: .position, keys: [name + ".x", name + ".y"], values: xy,
                            animated: false)
            case "double":
                let v = dv?.double ?? 0
                let unit = unit(code: e["unitType"]?.int ?? 0)
                let r = range(min: e["minValue"]?.double, max: e["maxValue"]?.double, value: v, unit: unit)
                return Item(name: name, label: label, kind: .number(range: r, unit: unit), keys: [name], values: [v],
                            animated: false)
            default:
                return nil   // `sourceFileType` and unknown types are not editable
            }
        }
    }

    /// Items guessed from the clip's own keys when the source has no `effectDef`.
    private static func itemsFromClip(_ params: Parameters) -> [Item] {
        var items: [Item] = []
        var seen = Set<String>()
        for key in params.names {
            guard params[key]?.defaultValue?.double != nil else { continue }
            var base = key
            var kind = Kind.number(range: 0...1, unit: .plain)
            var keys = [key]
            if let s = ["-red", "-green", "-blue", "-alpha"].first(where: { key.hasSuffix($0) }) {
                base = String(key.dropLast(s.count)); kind = .color; keys = colorKeys(base)
            } else if key.hasSuffix(".x") || key.hasSuffix(".y") {
                base = String(key.dropLast(2)); kind = .position; keys = [base + ".x", base + ".y"]
            } else {
                let o = params[key]?.raw.object
                let u = unit(code: o?["uiHints"]?.object?["unitType"]?.int ?? 0)
                let v = params[key]?.defaultValue?.double ?? 0
                kind = .number(range: range(min: nil, max: nil, value: v, unit: u), unit: u)
            }
            guard seen.insert(base).inserted else { continue }
            let defaults: [Double] = kind == .color ? [0, 0, 0, 1] : keys.map { _ in 0 }
            items.append(Item(name: base, label: LibrarySearch.words(ofIdentifier: base), kind: kind, keys: keys,
                              values: defaults, animated: false))
        }
        return items
    }

    private static func colorKeys(_ name: String) -> [String] {
        ["red", "green", "blue", "alpha"].map { "\(name)-\($0)" }
    }

    /// `unitType` codes of the SH2 table: 1 percentage, 3 radians.
    private static func unit(code: Int64) -> Unit {
        switch code {
        case 1: .percentage
        case 3: .angle
        default: .plain
        }
    }

    /// The file's `[min, max]` when it is a real range; otherwise a range around the value
    /// (directional entries write 0…0 [obs]): a full turn either way for angles, 0…1 for
    /// percentages, else 0…max(1, 2|v|), widened to include the value.
    static func range(min lo: Double?, max hi: Double?, value v: Double, unit: Unit) -> ClosedRange<Double> {
        if let lo, let hi, lo.isFinite, hi.isFinite, lo < hi { return Swift.min(lo, v)...Swift.max(hi, v) }
        let fallback: ClosedRange<Double>
        switch unit {
        case .angle: fallback = -2 * Double.pi...2 * Double.pi
        case .percentage: fallback = 0...1
        case .plain: fallback = Swift.min(0, v)...Swift.max(1, 2 * abs(v))
        }
        return Swift.min(fallback.lowerBound, v)...Swift.max(fallback.upperBound, v)
    }
}
