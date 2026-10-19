import Foundation
import TSCProjKit

/// Builders for `Callout.def` objects (`docs/specs/callouts.md` §2–§5). Key sets and
/// order follow the callouts Camtasia wrote in its sample projects [obs]; WizRec
/// draws its own geometry, so nothing here carries TechSmith artwork.
public enum CalloutDef {
    /// sRGB 0–1 colour with alpha.
    public typealias RGBA = (r: Double, g: Double, b: Double, a: Double)

    /// Text content and style; `fontSize` is written as the `textAttributes` run size (callout px).
    public struct Text: Sendable {
        public var text: String
        public var font: String
        public var fontSize: Double
        /// sRGB 0–255.
        public var color: (UInt8, UInt8, UInt8)
        public init(_ text: String, font: String = "Montserrat", fontSize: Double = 48, color: (UInt8, UInt8, UInt8) = (0, 0, 0)) {
            self.text = text; self.font = font; self.fontSize = fontSize; self.color = color
        }
    }

    static func fontObject(_ t: Text?) -> JSON {
        let c = t?.color ?? (255, 255, 255)
        return .obj([
            "color-blue": .dbl(Double(c.2) / 255), "color-green": .dbl(Double(c.1) / 255), "color-opacity": .dbl(1),
            "color-red": .dbl(Double(c.0) / 255), "size": .dbl(t?.fontSize ?? 64), "tracking": .dbl(0),
            "name": .str(t?.font ?? "Montserrat"), "weight": .str("Regular"),
        ])
    }

    /// One `textAttributeList` keyframe at time 0; `value: null` without text [obs].
    static func textAttributes(_ t: Text?) -> JSON {
        var value: JSON = .null
        if let t, !t.text.isEmpty {
            let end = t.text.utf16.count  // UTF-16 ranges [inf, callouts.md §5]
            func run(_ name: String, _ v: JSON, _ type: String) -> JSON {
                .obj(["name": .str(name), "rangeEnd": .num(end), "rangeStart": .num(0), "value": v, "valueType": .str(type)])
            }
            value = .arr([
                run("fontItalic", .num(0), "int"), run("fontSize", .dbl(t.fontSize), "double"),
                run("fontName", .str(t.font), "string"),
                run("fgColor", .str("(\(t.color.0),\(t.color.1),\(t.color.2),255)"), "color"),
                run("fontWeight", .num(400), "int"), run("underline", .num(0), "int"),
                run("kerning", .dbl(0), "double"), run("strikethrough", .num(0), "int"),
            ])
        }
        return .obj(["type": .str("textAttributeList"),
                     "keyframes": .arr([.obj(["endTime": .num(0), "time": .num(0), "value": value, "duration": .num(0)])])])
    }

    /// A `remix` shape or text callout of `width × height` callout px. `tail` = tail tip
    /// relative to the centre, callout px, +y up (bubbles and text arrows only).
    public static func shape(_ shape: String, style: String = "basic", width: Double = 240, height: Double = 160,
                             fill: RGBA = (0.2, 0.4, 0.8, 1), stroke: RGBA = (0, 0, 0, 1), strokeWidth: Double = 6,
                             strokeStyle: String = "solid", tail: (Double, Double)? = nil, text: Text? = nil) -> JSONObject {
        var pairs: [(String, JSON)] = [
            ("kind", .str("remix")), ("shape", .str(shape)), ("style", .str(style)),
            ("fill-color-blue", .dbl(fill.b)), ("fill-color-green", .dbl(fill.g)),
            ("fill-color-opacity", .dbl(fill.a)), ("fill-color-red", .dbl(fill.r)),
            ("height", .dbl(height)),
            ("stroke-color-blue", .dbl(stroke.b)), ("stroke-color-green", .dbl(stroke.g)),
            ("stroke-color-opacity", .dbl(stroke.a)), ("stroke-color-red", .dbl(stroke.r)),
            ("stroke-width", .dbl(strokeWidth)),
        ]
        if let tail { pairs += [("tail-x", .dbl(tail.0)), ("tail-y", .dbl(tail.1))] }
        pairs += [
            ("width", .dbl(width)), ("word-wrap", .dbl(1)), ("fill-style", .str("solid")),
            ("horizontal-alignment", .str("center")), ("stroke-style", .str(strokeStyle)),
            ("text", .str(text?.text ?? "")), ("vertical-alignment", .str("center")),
            ("font", fontObject(text)), ("textAttributes", textAttributes(text)),
        ]
        return JSONObject(pairs)
    }

    /// An `arrow` callout from its origin (anchor) to `tail` (callout px, +y up), with end caps.
    /// The tail coordinates are animatable `{defaultValue, interp: "eioe"}` objects [obs, presets].
    public static func arrow(tail: (Double, Double), anchor: String = "none", tailCap: String = "arrow",
                             style: String = "basic", stroke: RGBA = (0.2, 0.4, 0.8, 1), strokeWidth: Double = 6,
                             strokeStyle: String = "solid") -> JSONObject {
        JSONObject([
            ("kind", .str("remix")), ("shape", .str("arrow")), ("style", .str(style)),
            ("stroke-color-blue", .dbl(stroke.b)), ("stroke-color-green", .dbl(stroke.g)),
            ("stroke-color-opacity", .dbl(stroke.a)), ("stroke-color-red", .dbl(stroke.r)),
            ("stroke-width", .dbl(strokeWidth)),
            ("tail-x", .obj(["defaultValue": .dbl(tail.0), "interp": .str("eioe")])),
            ("tail-y", .obj(["defaultValue": .dbl(tail.1), "interp": .str("eioe")])),
            ("stroke-style", .str(strokeStyle)), ("shape-anchor", .str(anchor)), ("shape-tail", .str(tailCap)),
        ])
    }
}
