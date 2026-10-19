import Foundation
import TSCProjKit

/// One effect parameter as Camtasia 2026 (format 10.0) writes it.
public enum EffectParam: Sendable {
    /// Animatable double: `{type: "double", defaultValue, interp: "linr", uiHints: {0, 0}}` [obs, demo].
    case double(Double)
    /// Bare integer constant (enums and flags: `enabled`, `mask-shape`, `mode`, `channel` …) [obs, demo].
    case int(Int)
}

/// Builders for effect entries (`clip.effects[]`), key sets and order copied from
/// the effect instances Camtasia wrote in the user's demo and vlog projects and
/// the bundle samples (`docs/specs/effects/*.md`). Feed the result to
/// TimelineEngine's `AddEffect(clipID:effectJSON:)`.
public enum EffectJSON {
    /// `{effectName, bypassed: false, category, parameters, extra…}` in that key order.
    public static func make(_ name: String, category: String = "categoryVisualEffects",
                            _ params: [(String, EffectParam)], extra: [(String, JSON)] = []) -> JSONObject {
        let p = JSONObject(params.map { k, v in
            switch v {
            case .double(let d):
                return (k, JSON.obj([
                    "type": .str("double"), "defaultValue": .dbl(d), "interp": .str("linr"),
                    "uiHints": .obj(["userInterfaceType": .num(0), "unitType": .num(0)]),
                ]))
            case .int(let i):
                return (k, JSON.num(i))
            }
        })
        return JSONObject([
            ("effectName", .str(name)), ("bypassed", .flag(false)), ("category", .str(category)),
            ("parameters", .object(p)),
        ] + extra)
    }

    /// Serialised for `AddEffect(clipID:effectJSON:)`.
    public static func string(_ effect: JSONObject) -> String {
        String(decoding: JSON.object(effect).serialized(), as: UTF8.self)
    }

    /// `DropShadow`. `angle` radians CCW from +x (+y up); `offset`, `blur` px; colour and alphas 0–1.
    public static func dropShadow(angle: Double, offset: Double, blur: Double, opacity: Double = 1,
                                  color: (Double, Double, Double) = (0, 0, 0), colorAlpha: Double = 1,
                                  enabled: Int = 1) -> JSONObject {
        make("DropShadow", [
            ("angle", .double(angle)), ("enabled", .int(enabled)), ("offset", .double(offset)),
            ("blur", .double(blur)), ("opacity", .double(opacity)),
            ("color-red", .double(color.0)), ("color-green", .double(color.1)), ("color-blue", .double(color.2)),
            ("color-alpha", .double(colorAlpha)),
        ])
    }

    /// `RoundCorners`. `radius` layer px; corner flags 0–1 (tl, tr, bl, br).
    public static func roundCorners(radius: Double, corners: (Double, Double, Double, Double) = (1, 1, 1, 1)) -> JSONObject {
        make("RoundCorners", [
            ("radius", .double(radius)), ("top-left", .double(corners.0)), ("top-right", .double(corners.1)),
            ("bottom-left", .double(corners.2)), ("bottom-right", .double(corners.3)),
        ])
    }

    /// `Mask`. Sizes and position in layer px, rotation radians.
    public static func mask(shape: Int = 0, width: Double = 600, height: Double = 600, positionX: Double = 0,
                            positionY: Double = 0, rotation: Double = 0, cornerRadius: Double = 0,
                            blend: Double = 0, opacity: Double = 0, invert: Int = 0) -> JSONObject {
        make("Mask", [
            ("mask-shape", .int(shape)), ("mask-opacity", .double(opacity)), ("mask-blend", .double(blend)),
            ("mask-invert", .int(invert)), ("mask-rotation", .double(rotation)), ("mask-width", .double(width)),
            ("mask-height", .double(height)), ("mask-positionX", .double(positionX)),
            ("mask-positionY", .double(positionY)), ("mask-cornerRadius", .double(cornerRadius)),
        ])
    }

    /// The shared "range" block at its defaults (whole image) [obs].
    static let rangeDefaults: [(String, EffectParam)] = [
        ("channel", .int(0)), ("shadowRampStart", .double(0)), ("shadowRampEnd", .double(0)),
        ("highlightRampStart", .double(1)), ("highlightRampEnd", .double(1)),
    ]

    /// `ColorAdjustment` (vlog key set).
    public static func colorAdjustment(brightness: Double, contrast: Double, saturation: Double) -> JSONObject {
        make("ColorAdjustment", [
            ("brightness", .double(brightness)), ("contrast", .double(contrast)), ("saturation", .double(saturation)),
        ] + rangeDefaults)
    }

    /// `BlendModeEffect` (BlendModePreview key set, with its zero-length edge ramps).
    public static func blendMode(mode: Int, intensity: Double = 1, invert: Int = 0) -> JSONObject {
        func edge(_ fn: String) -> JSON {
            .arr([.obj([
                "group": .str("Video"), "duration": .num(0),
                "parameters": .arr([.obj(["name": .str("intensity"), "func": .str(fn)])]),
            ])])
        }
        return make("BlendModeEffect", [("mode", .int(mode)), ("intensity", .double(intensity)), ("invert", .int(invert))]
                    + rangeDefaults,
                    extra: [("leftEdgeMods", edge("FadeInFunc")), ("rightEdgeMods", edge("FadeOutFunc"))])
    }

    /// `MotionBlur`; `intensity` 1 = default shutter.
    public static func motionBlur(intensity: Double) -> JSONObject {
        make("MotionBlur", [("intensity", .double(intensity))])
    }

    /// `MediaMatte` (MediaMattePreview key set).
    public static func mediaMatte(mode: Int, intensity: Double = 1) -> JSONObject {
        make("MediaMatte", [("intensity", .double(intensity)), ("matteMode", .int(mode))])
    }
}
