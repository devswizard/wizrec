import CaptionLayout
import CoreGraphics
import Foundation
import TSCProjKit

/// A dynamic caption's style, block rules and the transcribed audio clips it reads from
/// (`docs/specs/captions.md` §3–§4). Times: ticks of the callout's parent timeline.
struct SDynamicCaption: Sendable {
    struct Audio: Sendable {
        var start: Int64
        var end: Int64
        var mediaStart: Rational
        var scalar: Rational
        /// Words on the source's media axis, seconds.
        var timeline: DynamicCaptionTimeline
    }

    var style: DynamicCaptionStyle
    var rules: CaptionBlockRules
    /// Paired audio clips, bottom track first.
    var audio: [Audio] = []

    /// The caption at parent time `t`: the first paired clip playing at `t`, at its media time.
    func frame(at t: Rational, editRate: Int64) -> DynamicCaptionFrame? {
        guard let a = audio.first(where: { Q.le(Rational($0.start), t) && Q.lt(t, Rational($0.end)) }) else { return nil }
        let m = Conventions.mediaTime(parent: t, start: a.start, mediaStart: a.mediaStart, scalar: a.scalar)
        return a.timeline.frame(at: m.double / Double(max(editRate, 1)))
    }

    /// One run over the whole block text with the `def` runs' font, weight, italic and colour (the
    /// runs' ranges index the placeholder `def.text`, and their fitted `fontSize` belongs to it too).
    static func textRun(_ runs: [CalloutTextRun], length: Int) -> [CalloutTextRun] {
        guard length > 0 else { return [] }
        var r = CalloutTextRun(range: 0..<length)
        for x in runs {
            r.fontName = r.fontName ?? x.fontName; r.fontWeight = r.fontWeight ?? x.fontWeight
            r.italic = r.italic ?? x.italic; r.color = r.color ?? x.color
        }
        return [r]
    }
}

/// Sendable projection of a callout's `def` (`docs/specs/callouts.md` §2–§5). Numeric keys stay
/// animatable (`tail-x`/`tail-y` on arrows are keyframed objects); strings and text runs are fixed,
/// except `textAttributes`, whose keyframes switch run lists over time.
struct SCallout: Sendable {
    var strings: [String: String]
    var numbers: SParams
    var text: String
    var font: (name: String, weight: String, size: Double, color: RGBA, tracking: Double)
    /// `textAttributes.keyframes`: keyframe time (keyframe axis, ticks) and its runs, sorted.
    var runKeys: [(time: Double, runs: [CalloutTextRun])]
    /// Set when the `def` is a dynamic caption; its audio is paired by `SceneBuilder`.
    var caption: SDynamicCaption?

    init(_ def: JSONObject) {
        caption = DynamicCaptionStyle.isDynamicCaption(def)
            ? SDynamicCaption(style: DynamicCaptionStyle(def: def), rules: CaptionBlockRules(def: def)) : nil
        var strings: [String: String] = [:]
        for (k, v) in def.entries { if let s = v.string { strings[k] = s } }
        self.strings = strings
        numbers = SParams(def)
        text = def["text"]?.string ?? ""
        let f = def["font"]?.object
        func fnum(_ k: String) -> Double? { f?[k]?.double }
        font = (name: f?["name"]?.string ?? "Helvetica", weight: f?["weight"]?.string ?? "Regular",
                size: fnum("size") ?? 64,
                color: RGBA(fnum("color-red") ?? 0, fnum("color-green") ?? 0, fnum("color-blue") ?? 0,
                            fnum("color-opacity") ?? fnum("color-alpha") ?? 1),
                tracking: fnum("tracking") ?? 0)
        let kfs = def["textAttributes"]?.object?["keyframes"]?.array?.items.compactMap(\.object) ?? []
        runKeys = kfs.map { k in
            (k["time"]?.double ?? 0, (k["value"]?.array?.items.compactMap(\.object) ?? []).compactMap(Self.run))
        }
        .sorted { $0.time < $1.time }
    }

    /// One `{name, rangeStart, rangeEnd, value, valueType}` entry as a run with one attribute set.
    static func run(_ o: JSONObject) -> CalloutTextRun? {
        guard let name = o["name"]?.string, let lo = o["rangeStart"]?.int, let hi = o["rangeEnd"]?.int,
              lo <= hi else { return nil }
        var r = CalloutTextRun(range: Int(lo)..<Int(hi))
        let v = o["value"]
        switch name {
        case "fontName": r.fontName = v?.string
        case "fontSize": r.fontSize = v?.double
        case "fontWeight": r.fontWeight = v?.int.map(Int.init)
        case "fontItalic": r.italic = (v?.double ?? 0) != 0
        case "underline": r.underline = (v?.double ?? 0) != 0
        case "strikethrough": r.strikethrough = (v?.double ?? 0) != 0
        case "fgColor": r.color = v?.string.flatMap(Self.parenColor)
        case "kerning": r.kerning = v?.double
        default: return nil
        }
        return r
    }

    /// `"(r,g,b,a)"` with 0–255 components [callouts.md §5].
    static func parenColor(_ s: String) -> RGBA? {
        let parts = s.trimmingCharacters(in: CharacterSet(charactersIn: "() ")).split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 3 else { return nil }
        return RGBA(parts[0] / 255, parts[1] / 255, parts[2] / 255, parts.count > 3 ? parts[3] / 255 : 1)
    }

    /// Preset form `"RRGGBB"` / `"RRGGBBAA"` [callouts.md §2].
    static func hexColor(_ s: String) -> RGBA? {
        let h = s.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        if h.count == 6 {
            return RGBA(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255, 1)
        }
        return RGBA(Double((v >> 24) & 0xFF) / 255, Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255,
                    Double(v & 0xFF) / 255)
    }

    /// The `def` at keyframe time `kt`, with box `size` (from the clip) as fallback for width/height.
    func content(at kt: Double, size: CGSize) -> CalloutContent {
        let p = numbers.evaluated(at: kt)
        func n(_ k: String, _ d: Double) -> Double { p[k] ?? d }
        func color(_ prefix: String, alphaKey: String, _ d: RGBA) -> RGBA {
            if p["\(prefix)-red"] != nil || p["\(prefix)-green"] != nil || p["\(prefix)-blue"] != nil {
                return RGBA(Conventions.clamp01(n("\(prefix)-red", 0)), Conventions.clamp01(n("\(prefix)-green", 0)),
                            Conventions.clamp01(n("\(prefix)-blue", 0)), Conventions.clamp01(n("\(prefix)-\(alphaKey)", 1)))
            }
            return strings[prefix].flatMap(Self.hexColor) ?? d
        }
        let runs = runKeys.last { $0.time <= kt }?.runs ?? runKeys.first?.runs ?? []
        let w = n("width", size.width), h = n("height", size.height)
        return CalloutContent(
            kind: strings["kind"] ?? "remix", shape: strings["shape"] ?? "", style: strings["style"] ?? "",
            size: CGSize(width: max(w, 0), height: max(h, 0)),
            fill: color("fill-color", alphaKey: "opacity", RGBA(1, 1, 1, 0)),
            stroke: color("stroke-color", alphaKey: "opacity", RGBA(0, 0, 0, 1)),
            strokeWidth: max(n("stroke-width", 0), 0), strokeStyle: strings["stroke-style"] ?? "solid",
            cornerRadius: max(n("corner-radius", 0), 0),
            tail: CGPoint(x: n("tail-x", 0), y: n("tail-y", 0)),
            anchorCap: strings["shape-anchor"] ?? "none", tailCap: strings["shape-tail"] ?? "arrow",
            text: text, runs: runs, fontName: font.name, fontWeight: font.weight, fontSize: font.size,
            textColor: font.color,
            horizontalAlignment: strings["horizontal-alignment"] ?? "center",
            verticalAlignment: strings["vertical-alignment"] ?? "center",
            wordWrap: n("word-wrap", 1) != 0, lineSpacing: n("line-spacing", 0),
            tracking: n("tracking", font.tracking),
            textStrokeWidth: max(n("text-stroke-width", 0), 0),
            textStrokeColor: color("text-stroke-color", alphaKey: "alpha", RGBA(0, 0, 0, 1)),
            intensity: n("intensity", 0.5),
            invert: n("blur-invert", 0) != 0 || n("fill-invert", 0) != 0)
    }
}
