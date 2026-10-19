import Foundation

/// One key of a callout's `def` object, in the project form of `docs/specs/callouts.md` §2
/// (colours as split 0–1 doubles). Objects nest (the `font` entry).
public struct CalloutDefEntry: Sendable, Hashable {
    public enum Value: Sendable, Hashable {
        case number(Double)
        case string(String)
        case object([CalloutDefEntry])
    }

    public var key: String
    public var value: Value

    public init(_ key: String, _ value: Value) { self.key = key; self.value = value }
}

/// A callout preset for the library panel: our own colour and size choices for one of the
/// format's callout `kind`/`shape` ids. Geometry is drawn by RenderEngine.
public struct CalloutPreset: Sendable, Hashable, Identifiable {
    /// Library tab.
    public enum Group: String, Sendable, CaseIterable {
        case shapes, bubbles, arrows, text, regions
    }

    /// Stable identifier, e.g. `bubble-speech-blue`.
    public var id: String
    public var displayName: String
    public var group: Group
    /// `def.kind`: `remix` for vector shapes, `TypeWinBlur` etc. for region callouts.
    public var kind: String
    /// `def.shape`, e.g. `shape-rectangle`, `speech-bubble`, `arrow`; `""` for region kinds.
    public var shape: String
    /// `def.style`: `basic` for remix kinds, `""` otherwise.
    public var style: String
    /// Box size, callout px (0 for arrows, whose extent comes from the tail vector).
    public var width: Double
    public var height: Double
    public var fill: AssetColor
    public var stroke: AssetColor
    /// Outline width, callout px.
    public var strokeWidth: Double
    /// `solid`, `dash`, `dot`, `dashdot` or `dashdotdot`.
    public var strokeStyle: String
    /// Box corner radius, px.
    public var cornerRadius: Double
    /// Tail tip (bubbles) or arrow head (arrows) relative to the centre, px, +y up; nil = none.
    public var tail: SIMD2<Double>?
    /// Arrow start cap (`shape-anchor`: `none`, `arrow`, `circle`, …); nil on non-arrows.
    public var anchorCap: String?
    /// Arrow end cap (`shape-tail`: `arrow` or `none`); nil on non-arrows.
    public var tailCap: String?
    /// Placeholder text; `""` for shape-only callouts.
    public var text: String
    /// Font family (one of `AssetCatalog.fonts`, or a system family).
    public var fontName: String
    /// Font weight name, e.g. `Regular`, `Bold`.
    public var fontWeight: String
    /// Font size, pt (= callout px at scale 1).
    public var fontSize: Double
    public var textColor: AssetColor
    /// Region callouts: extra numeric keys such as `intensity`.
    public var extras: [PresetValue]

    public init(id: String, displayName: String, group: Group, kind: String = "remix", shape: String,
                style: String? = nil, width: Double, height: Double, fill: AssetColor,
                stroke: AssetColor = AssetColor(0, 0, 0, 0), strokeWidth: Double = 0, strokeStyle: String = "solid",
                cornerRadius: Double = 0, tail: SIMD2<Double>? = nil, arrowCaps: (anchor: String, tail: String)? = nil,
                text: String = "", fontName: String = "Montserrat", fontWeight: String = "Regular",
                fontSize: Double = 64, textColor: AssetColor = AssetColor(1, 1, 1), extras: [PresetValue] = []) {
        self.id = id; self.displayName = displayName; self.group = group; self.kind = kind; self.shape = shape
        self.style = style ?? (kind == "remix" ? "basic" : "")
        self.width = width; self.height = height; self.fill = fill; self.stroke = stroke
        self.strokeWidth = strokeWidth; self.strokeStyle = strokeStyle; self.cornerRadius = cornerRadius
        self.tail = tail; self.anchorCap = arrowCaps?.anchor; self.tailCap = arrowCaps?.tail
        self.text = text; self.fontName = fontName; self.fontWeight = fontWeight; self.fontSize = fontSize
        self.textColor = textColor; self.extras = extras
    }

    /// The `def` object for a new callout, in project form and key order [callouts.md §2].
    /// `textAttributes` is left to the writer (it depends on the final text and box).
    public var definition: [CalloutDefEntry] {
        typealias E = CalloutDefEntry
        func rgba(_ prefix: String, _ c: AssetColor, alpha: String) -> [E] {
            [E("\(prefix)-red", .number(c.red)), E("\(prefix)-green", .number(c.green)),
             E("\(prefix)-blue", .number(c.blue)), E("\(prefix)-\(alpha)", .number(c.alpha))]
        }
        var d: [E] = [E("kind", .string(kind)), E("shape", .string(shape)), E("style", .string(style))]
        if width > 0 || height > 0 { d += [E("width", .number(width)), E("height", .number(height))] }
        d += rgba("fill-color", fill, alpha: "opacity") + [E("fill-style", .string("solid"))]
        d += rgba("stroke-color", stroke, alpha: "opacity")
        d += [E("stroke-width", .number(strokeWidth)), E("stroke-style", .string(strokeStyle))]
        if cornerRadius > 0 { d.append(E("corner-radius", .number(cornerRadius))) }
        if let tail { d += [E("tail-x", .number(tail.x)), E("tail-y", .number(tail.y))] }
        if let anchorCap { d.append(E("shape-anchor", .string(anchorCap))) }
        if let tailCap { d.append(E("shape-tail", .string(tailCap))) }
        if kind == "remix" {
            d.append(E("text", .string(text)))
            d.append(E("font", .object([
                E("name", .string(fontName)), E("weight", .string(fontWeight)), E("size", .number(fontSize)),
                E("color-red", .number(textColor.red)), E("color-green", .number(textColor.green)),
                E("color-blue", .number(textColor.blue)), E("color-opacity", .number(textColor.alpha)),
                E("tracking", .number(0)), E("leading", .number(0)),
            ])))
            d += [E("horizontal-alignment", .string("center")), E("vertical-alignment", .string("center")),
                  E("word-wrap", .number(1)), E("line-spacing", .number(0)), E("tracking", .number(0)),
                  E("resize-behavior", .string("resizeText"))]
        }
        d += extras.map { E($0.key, .number($0.value)) }
        return d
    }
}

// Our own presets: colours from the WizRec palette, sizes chosen for a 1920×1080 canvas.
enum BuiltInCallouts {
    private static func c(_ hex: String) -> AssetColor { AssetColor(hex: hex) ?? AssetColor(0, 0, 0) }

    static let all: [CalloutPreset] = [
        // Shapes
        CalloutPreset(id: "shape-rectangle-outline", displayName: "Outline Box", group: .shapes,
                      shape: "shape-rectangle", width: 400, height: 240, fill: c("00000000"),
                      stroke: c("F43F5E"), strokeWidth: 6),
        CalloutPreset(id: "shape-rectangle-filled", displayName: "Filled Box", group: .shapes,
                      shape: "shape-rectangle", width: 400, height: 240, fill: c("4F46E5"), cornerRadius: 16),
        CalloutPreset(id: "shape-ellipse-outline", displayName: "Outline Circle", group: .shapes,
                      shape: "shape-ellipse", width: 300, height: 300, fill: c("00000000"),
                      stroke: c("F43F5E"), strokeWidth: 6),
        CalloutPreset(id: "shape-star", displayName: "Star", group: .shapes,
                      shape: "shape-star", width: 240, height: 240, fill: c("FACC15")),
        CalloutPreset(id: "shape-triangle", displayName: "Triangle", group: .shapes,
                      shape: "shape-triangle", width: 240, height: 210, fill: c("22C55E")),
        CalloutPreset(id: "shape-octagon", displayName: "Stop", group: .shapes,
                      shape: "shape-octagon", width: 240, height: 240, fill: c("DC2626")),
        // Bubbles
        CalloutPreset(id: "bubble-speech", displayName: "Speech Bubble", group: .bubbles,
                      shape: "speech-bubble", width: 420, height: 220, fill: c("FFFFFF"),
                      stroke: c("1E293B"), strokeWidth: 2, tail: SIMD2(-120, -200), text: "Say something",
                      fontSize: 48, textColor: c("1E293B")),
        CalloutPreset(id: "bubble-thought", displayName: "Thought Bubble", group: .bubbles,
                      shape: "thought-bubble", width: 420, height: 240, fill: c("FFFFFF"),
                      stroke: c("1E293B"), strokeWidth: 2, tail: SIMD2(-140, -220), text: "Hmm…",
                      fontName: "Caveat", fontSize: 64, textColor: c("1E293B")),
        // Arrows and lines
        CalloutPreset(id: "arrow-basic", displayName: "Arrow", group: .arrows, shape: "arrow",
                      width: 0, height: 0, fill: c("F43F5E"), stroke: c("F43F5E"), strokeWidth: 8,
                      tail: SIMD2(240, 0), arrowCaps: ("none", "arrow")),
        CalloutPreset(id: "arrow-double", displayName: "Double Arrow", group: .arrows, shape: "arrow",
                      width: 0, height: 0, fill: c("0EA5E9"), stroke: c("0EA5E9"), strokeWidth: 8,
                      tail: SIMD2(240, 0), arrowCaps: ("arrow", "arrow")),
        CalloutPreset(id: "line-dotted", displayName: "Dotted Line", group: .arrows, shape: "arrow",
                      width: 0, height: 0, fill: c("FFFFFF"), stroke: c("FFFFFF"), strokeWidth: 6,
                      strokeStyle: "dot", tail: SIMD2(240, 0), arrowCaps: ("circle", "none")),
        // Text
        CalloutPreset(id: "text-title", displayName: "Title", group: .text, shape: "text",
                      width: 1200, height: 200, fill: c("00000000"), text: "Your Title",
                      fontName: "Bebas Neue", fontSize: 140),
        CalloutPreset(id: "text-label", displayName: "Label", group: .text, shape: "text-rectangle",
                      width: 520, height: 120, fill: c("111827E6"), cornerRadius: 12, text: "Label",
                      fontName: "Lato", fontWeight: "Bold", fontSize: 56),
        CalloutPreset(id: "text-handwritten", displayName: "Handwritten Note", group: .text, shape: "text",
                      width: 600, height: 180, fill: c("00000000"), text: "Note", fontName: "Caveat",
                      fontSize: 96, textColor: c("FDE047")),
        CalloutPreset(id: "text-lower-third", displayName: "Lower Third", group: .text, shape: "text-rectangle",
                      width: 900, height: 140, fill: c("4F46E5"), cornerRadius: 8, text: "Name · Role",
                      fontName: "Montserrat", fontWeight: "Bold", fontSize: 52),
        // Region callouts (act on the pixels below)
        CalloutPreset(id: "region-blur", displayName: "Blur", group: .regions, kind: "TypeWinBlur", shape: "",
                      width: 400, height: 240, fill: c("00000000"),
                      extras: [PresetValue("intensity", 0.8), PresetValue("blur-invert", 0)]),
        CalloutPreset(id: "region-pixelate", displayName: "Pixelate", group: .regions, kind: "TypeWinPixelate",
                      shape: "", width: 400, height: 240, fill: c("00000000"),
                      extras: [PresetValue("intensity", 0.35)]),
        CalloutPreset(id: "region-highlight", displayName: "Highlight", group: .regions,
                      kind: "TypeWinHighlighter", shape: "", width: 400, height: 80, fill: c("FDE04780"),
                      extras: [PresetValue("fill-invert", 0)]),
        CalloutPreset(id: "region-spotlight", displayName: "Spotlight", group: .regions,
                      kind: "TypeWinSpotlight", shape: "", width: 400, height: 240, fill: c("00000000"),
                      extras: [PresetValue("intensity", 0.5)]),
    ]
}
