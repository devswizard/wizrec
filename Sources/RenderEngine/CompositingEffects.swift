import Foundation

// Effects that change how a layer composites with what is below it. The compositor draws these
// itself (backdrop and matte passes) instead of running them as layer passes.

/// `BlendModeEffect`: composites the layer onto what is below it with a blend function
/// (`docs/specs/effects/BlendModeEffect.md`).
enum BlendModeSpec {
    static let name = "BlendModeEffect"

    /// The project's `mode` numbers [obs, BlendModeEffect.md, RT-015]; the raw value is also the
    /// `blend_fn` id in `Shaders`. Formulas are the standard layered-image-editor ones [inf].
    enum Mode: Int, CaseIterable {
        case normal = 0
        case stencilAlpha = 1, silhouetteAlpha, stencilLuma, silhouetteLuma
        case dissolve = 5, darken, multiply, colorBurn, linearBurn, darkerColor
        case lighten = 11, screen, colorDodge, linearDodge, lighterColor
        case overlay = 16, softLight, hardLight, vividLight, linearLight, pinLight, hardMix
        case difference = 23, exclusion, subtract, divide
        case hue = 27, saturation, color, luminosity

        /// Stencil / silhouette modes act as a matte on what lies below; the layer itself is not
        /// drawn [inf from the names]: (luminosity?, inverted?).
        var stencil: (luminosity: Bool, inverted: Bool)? {
            switch self {
            case .stencilAlpha: (false, false)
            case .silhouetteAlpha: (false, true)
            case .stencilLuma: (true, false)
            case .silhouetteLuma: (true, true)
            default: nil
            }
        }
    }

    /// `mode` written when the effect is added (Screen) [obs, catalog]; used when the key is missing.
    static let defaultMode = 12.0

    /// The blend mode; values outside 0–30 are [?] and composite normally.
    static func mode(_ e: EffectInstance) -> Mode { Mode(rawValue: Int(e.value("mode", defaultMode).rounded())) ?? .normal }
    /// Mix between normal compositing (0) and the blended result (1) [inf]. The spec's formula
    /// `B·(1 − a·i) + mix(L, blended, i)·a·i` would make the layer vanish at i = 0, contradicting "normal
    /// at 0"; WizRec composites `mix(L, blended, i)` source-over with alpha `a` [inf].
    static func intensity(_ e: EffectInstance) -> Double { Conventions.clamp01(e.value("intensity", 1)) }
}

/// `MediaMatte`: the clip is not drawn; it masks the track directly below
/// (`docs/specs/effects/MediaMatte.md`).
enum MediaMatteSpec {
    static let name = "MediaMatte"

    /// `matteMode` → (luminosity, inverted): 1 Alpha (default), 2 Alpha Invert, 3 Luminosity,
    /// 4 Luminosity Invert [obs, RT-015]; 0 and other values are [?], treated as 1.
    static func mode(_ e: EffectInstance) -> (luminosity: Bool, inverted: Bool) {
        switch Int(e.value("matteMode", 1).rounded()) {
        case 2: (false, true)
        case 3: (true, false)
        case 4: (true, true)
        default: (false, false)
        }
    }

    /// `trackDepth` written by Camtasia on new mattes: "all tracks below" [inf].
    static let allTracksBelow = 10002
    /// How many tracks below the matte it masks [WizRec, DECISIONS]: a missing key → only the track
    /// directly below (older files); an explicit N → N tracks; 10002 (or more) → every track below in
    /// the same canvas (`Int.max`). Tracks are counted as the layers drawn below at that time.
    static func trackDepth(_ e: EffectInstance) -> Int {
        guard let v = e.parameters["trackDepth"], v.isFinite else { return 1 }
        let n = Int(v.rounded())
        return n >= allTracksBelow ? Int.max : max(n, 1)
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
