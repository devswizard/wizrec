import Foundation

// Effects that change how a layer composites with what is below it. The compositor draws these
// itself (backdrop and matte passes) instead of running them as layer passes.

/// `BlendModeEffect`: composites the layer onto what is below it with a blend function
/// (`docs/specs/effects/BlendModeEffect.md`).
enum BlendModeSpec {
    static let name = "BlendModeEffect"

    /// WizRec's blend-function ids (see `blend_fn` in `Shaders`).
    enum Mode: Int {
        case normal = 0, multiply, screen, overlay, darken, lighten, colorDodge, colorBurn, hardLight, softLight,
             difference, exclusion, hue, saturation, color, luminosity, add, linearBurn, subtract
    }

    /// Project `mode` value → blend function. The numbering is [?] until EF5; only 12 has evidence
    /// (BlendModePreview's additive-colour discs: Screen, Lighten or Add [inf, weak]).
    /// Unknown values composite normally.
    static let modes: [Int: Mode] = [0: .normal, 12: .screen]

    static func mode(_ e: EffectInstance) -> Mode { modes[Int(e.value("mode", 0).rounded())] ?? .normal }
    /// Mix between normal compositing (0) and the blended result (1) [inf]. The spec's formula
    /// `B·(1 − a·i) + mix(L, blended, i)·a·i` would make the layer vanish at i = 0, contradicting "normal
    /// at 0"; WizRec composites `mix(L, blended, i)` source-over with alpha `a` [inf].
    static func intensity(_ e: EffectInstance) -> Double { Conventions.clamp01(e.value("intensity", 1)) }
}

/// `MediaMatte`: the clip is not drawn; it masks the track directly below
/// (`docs/specs/effects/MediaMatte.md`).
enum MediaMatteSpec {
    static let name = "MediaMatte"

    /// `matteMode` → (luminosity, inverted). Numbering [?] until EF7; assumed 1-based in UI order
    /// alpha, inverted alpha, luminosity, inverted luminosity; 0 = alpha.
    static func mode(_ e: EffectInstance) -> (luminosity: Bool, inverted: Bool) {
        switch Int(e.value("matteMode", 1).rounded()) {
        case 2: (false, true)
        case 3: (true, false)
        case 4: (true, true)
        default: (false, false)
        }
    }

    static func intensity(_ e: EffectInstance) -> Double { Conventions.clamp01(e.value("intensity", 1)) }
}

/// Region callouts (`TypeWinBlur`, `TypeWinPixelate`, `TypeWinSpotlight`) [callouts.md §3]. The region is
/// the callout box; units [?] until CO3.
enum RegionCalloutSpec {
    /// Blur σ at intensity 1, callout px.
    static let blurSigmaAtFull = 24.0
    /// Pixel block at intensity 1, callout px.
    static let pixelBlockAtFull = 60.0
}
