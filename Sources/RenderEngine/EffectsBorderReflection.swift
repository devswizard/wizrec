import CoreGraphics
import Foundation
import Metal

// Border and Reflection: parameter names and defaults from Camtasia saves (EF0) [obs]
// (`docs/specs/effects/Border.md`, `Reflection.md`, `catalog.md`). The look is PROVISIONAL until
// the EF8/EF9 reference sheets: units and shapes sit in each `Spec` enum. Tags: [obs] observed,
// [inf] inferred, [?] unknown, [WizRec] our own choice.

// MARK: - Border

/// A solid border around the layer's silhouette, drawn outside it (`docs/specs/effects/Border.md`).
struct BorderEffect: EffectRenderer {
    enum Spec {
        static let name = "Border"
        /// Defaults written when the effect is added [obs, EF0]: on, opaque white, width 1, type 0.
        static let defaultEnabled = 1.0
        static let defaultColor = RGBA(1, 1, 1, 1)
        static let defaultWidth = 1.0
        /// `width` in canvas px [?: canvas or layer px, EF8 cells 1–2], like `DropShadow`'s units.
        static let canvasUnits = true
        /// `type` 0 is the default style [obs]; other values and their looks are [?]: all draw solid.
        /// The stroke follows the alpha silhouette after earlier effects [inf], grown with a square
        /// (Chebyshev) dilation [WizRec], so a rectangle gets square outside corners.
        static let maxTaps = 64
    }

    private func widthLayerPx(_ e: EffectInstance, layerScale: Double) -> Double {
        let w = max(e.value("width", Spec.defaultWidth), 0)
        return Spec.canvasUnits ? w / max(layerScale, 1e-6) : w
    }

    private func active(_ e: EffectInstance) -> Bool {
        e.value("enabled", Spec.defaultEnabled) >= 0.5 && e.value("color-alpha", Spec.defaultColor.a) > 0
    }

    func margin(_ e: EffectInstance, ctx: MarginContext) -> Margin {
        guard active(e) else { return .zero }
        return .all(widthLayerPx(e, layerScale: ctx.layerScale) + 1)
    }

    func encode(_ e: EffectInstance, input: any MTLTexture, ctx: inout EffectContext) throws -> any MTLTexture {
        guard active(e) else { return input }
        let radius = widthLayerPx(e, layerScale: ctx.layerScale) * ctx.scale // texture px
        guard radius > 0 else { return input }
        let taps = Float(min(ceil(radius), Double(Spec.maxTaps)))
        let step = Float(radius) / max(taps, 1)
        var fx = ctx.fx(input)
        fx.set(0, SIMD4(Float(radius), taps, step, 0))
        fx.set(1, SIMD4(1, 0, 0, 0))
        let h = try ctx.gpu.pass("border_dilate_fs", textures: [input], fx: fx, commandBuffer: ctx.commandBuffer)
        fx.set(1, SIMD4(0, 1, 0, 0))
        let grown = try ctx.gpu.pass("border_dilate_fs", textures: [h], fx: fx, commandBuffer: ctx.commandBuffer)
        var c = ctx.fx(input)
        c.set(0, e.color("color", Spec.defaultColor))
        return try ctx.gpu.pass("border_composite_fs", textures: [input, grown], fx: c, commandBuffer: ctx.commandBuffer)
    }

    var source: String { """
    // Max of alpha within ±radius along fx.p[1].xy (texture px); output alpha only.
    fragment float4 border_dilate_fs(FSOut in [[stage_in]], constant FX& fx [[buffer(0)]],
                                     texture2d<float> src [[texture(0)]], sampler smp [[sampler(0)]]) {
        float radius = fx.p[0].x;
        int taps = int(fx.p[0].y);
        float stepPx = fx.p[0].z;
        float2 dir = fx.p[1].xy / fx.size;
        float a = fx_sample(src, smp, in.uv).a;
        for (int i = 1; i <= taps; i++) {
            float x = min(float(i) * stepPx, radius);
            a = max(a, max(fx_sample(src, smp, in.uv + dir * x).a, fx_sample(src, smp, in.uv - dir * x).a));
        }
        return float4(0.0, 0.0, 0.0, a);
    }

    // The layer over its border (straight colour fx.p[0]).
    fragment float4 border_composite_fs(FSOut in [[stage_in]], constant FX& fx [[buffer(0)]],
                                        texture2d<float> src [[texture(0)]], texture2d<float> grown [[texture(1)]],
                                        sampler smp [[sampler(0)]]) {
        float4 c = src.sample(smp, in.uv);
        float a = grown.sample(smp, in.uv).a * fx.p[0].a;
        return c + float4(fx.p[0].rgb * a, a) * (1.0 - c.a);
    }
    """ }
}

// MARK: - Reflection

/// A mirrored, fading copy of the layer below its bottom edge (`docs/specs/effects/Reflection.md`).
struct ReflectionEffect: EffectRenderer {
    enum Spec {
        static let name = "Reflection"
        /// Defaults written when the effect is added [obs, EF0].
        static let defaultDistance = 20.0
        static let defaultOpacity = 0.4
        /// `distance` (gap between the layer's bottom edge and the copy) in canvas px [?, probably px].
        static let canvasUnits = true
        /// Fade length of the copy, fraction of the visible layer height: alpha ramps linearly from
        /// `opacity` at the flip line to 0 [WizRec; the real ramp is fixed by Camtasia and [?], EF9].
        static let fadeFraction = 0.5
        /// The copy is part of the layer: it moves, scales and rotates with it, and draws under it [inf].
    }

    private func distanceLayerPx(_ e: EffectInstance, layerScale: Double) -> Double {
        let d = max(e.value("distance", Spec.defaultDistance), 0)
        return Spec.canvasUnits ? d / max(layerScale, 1e-6) : d
    }

    func margin(_ e: EffectInstance, ctx: MarginContext) -> Margin {
        guard e.value("opacity", Spec.defaultOpacity) > 0 else { return .zero }
        var m = Margin.zero
        m.bottom = distanceLayerPx(e, layerScale: ctx.layerScale) + ctx.contentSize.height * Spec.fadeFraction + 1
        return m
    }

    func encode(_ e: EffectInstance, input: any MTLTexture, ctx: inout EffectContext) throws -> any MTLTexture {
        let opacity = Conventions.clamp01(e.value("opacity", Spec.defaultOpacity))
        guard opacity > 0 else { return input }
        let gap = distanceLayerPx(e, layerScale: ctx.layerScale) * ctx.scale // texture px
        let height = Double(ctx.contentRect.w - ctx.contentRect.y)
        var fx = ctx.fx(input)
        fx.set(0, SIMD4(Float(gap), Float(max(height * Spec.fadeFraction, 1e-3)), Float(opacity), 0))
        return try ctx.gpu.pass("reflection_fs", textures: [input], fx: fx, commandBuffer: ctx.commandBuffer)
    }

    var source: String { """
    // Below the content's bottom edge (fx.rect.w, y down) plus the gap, mirror the content upwards
    // and fade it out over fx.p[0].y px; draw the layer over it.
    fragment float4 reflection_fs(FSOut in [[stage_in]], constant FX& fx [[buffer(0)]],
                                  texture2d<float> src [[texture(0)]], sampler smp [[sampler(0)]]) {
        float4 c = src.sample(smp, in.uv);
        float2 px = in.uv * fx.size;
        float bottom = fx.rect.w;
        float m = px.y - bottom - fx.p[0].x;            // depth into the reflection
        if (m < 0.0 || m > fx.p[0].y) return c;
        float srcY = bottom - m;
        if (srcY < fx.rect.y) return c;
        float4 r = fx_sample(src, smp, float2(px.x, srcY) / fx.size) * fx.p[0].z * (1.0 - m / fx.p[0].y);
        return c + r * (1.0 - c.a);
    }
    """ }
}
