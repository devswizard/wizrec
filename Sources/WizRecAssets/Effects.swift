import Foundation

// Effect presets for the library panel. Parameter keys and defaults follow
// `docs/specs/effects/*.md`; the values are WizRec's own starting points where a spec marks
// the format's default as unknown.

enum BuiltInEffects {
    private typealias V = PresetValue

    static let all: [EffectPreset] = [
        EffectPreset(name: "RoundCorners", displayName: "Rounded Corners", parameters: [
            V("radius", 32), V("top-left", 1), V("top-right", 1), V("bottom-left", 1), V("bottom-right", 1),
        ]),
        EffectPreset(name: "DropShadow", displayName: "Drop Shadow", parameters: [
            V("angle", 3 * Double.pi / 2), V("offset", 15), V("blur", 25), V("opacity", 0.2),
            V("color-red", 31.0 / 255), V("color-green", 31.0 / 255), V("color-blue", 31.0 / 255),
            V("color-alpha", 1), V("enabled", 1),
        ]),
        EffectPreset(name: "Mask", displayName: "Mask", parameters: [
            V("mask-shape", 0), V("mask-width", 1080), V("mask-height", 1080), V("mask-positionX", 0),
            V("mask-positionY", 0), V("mask-rotation", 0), V("mask-cornerRadius", 0), V("mask-blend", 0),
            V("mask-opacity", 0), V("mask-invert", 0),
        ]),
        EffectPreset(name: "ColorAdjustment", displayName: "Color Adjustment", parameters: [
            V("brightness", 0), V("contrast", 0), V("saturation", 0), V("channel", 0),
            V("shadowRampStart", 0), V("shadowRampEnd", 0), V("highlightRampStart", 1), V("highlightRampEnd", 1),
        ]),
        EffectPreset(name: "MotionBlur", displayName: "Motion Blur", parameters: [V("intensity", 1)]),
    ]
}
