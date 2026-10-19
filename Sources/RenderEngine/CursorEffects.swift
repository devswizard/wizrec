import CoreGraphics
import Foundation
import Metal

/// Cursor and click effects (`docs/specs/cursor-effects.md`). They act on the cursor layer, never on the
/// clip's pixels. Every model constant sits in `Spec`; experiments CE1–CE3 fix them.
enum CursorEffects {
    enum Spec {
        /// LeftClickScaling: the pulse lasts `clickPulseSpeedSeconds / speed` seconds, a sine bump from 1 to
        /// `scale` and back [?: CE2].
        static let clickPulseSpeedSeconds = 1.5
        /// CursorMotionBlur shutter at intensity 1, output frames [inf].
        static let motionShutterFrames = 1.0
    }

    /// Effects that belong to the cursor layer: names starting with `Cursor`, and click effects.
    static func isCursorEffect(_ name: String) -> Bool {
        name.hasPrefix("Cursor") || name.contains("Click") || name.hasSuffix("Gesture")
    }

    /// Cursor effects renamed to the renderer that draws them on the cursor layer.
    static func layerEffects(_ effects: [EffectInstance]) -> [EffectInstance] {
        effects.compactMap { e in
            switch e.name {
            case "CursorShadow": EffectInstance(name: "DropShadow", parameters: e.parameters, bypassed: e.bypassed)
            case "CursorColor": e
            default: nil
            }
        }
    }

    /// LeftClickScaling multiplier at recording time `t` given left-press times.
    static func clickScale(_ e: EffectInstance?, leftDowns: [Double], at t: Double) -> Double {
        guard let e, !e.bypassed else { return 1 }
        let peak = e.value("scale", 1), speed = max(e.value("speed", 1), 1e-3)
        let d = Spec.clickPulseSpeedSeconds / speed
        guard let t0 = leftDowns.last(where: { $0 <= t }) else { return 1 }
        let tau = t - t0
        guard tau < d else { return 1 }
        return 1 + (peak - 1) * sin(Double.pi * tau / d)
    }
}

/// `CursorColor`: maps the cursor's luma onto a two-stop gradient — `secondColor` at
/// `secondColorLumaCutoff`, `color` at `colorLumaCutoff` — keeps its alpha, mixes by `intensity`
/// [cursor-effects.md §2, inf: the demo's black arrow with white outline renders yellow with a dark outline].
struct CursorColorEffect: EffectRenderer {
    func encode(_ e: EffectInstance, input: any MTLTexture, ctx: inout EffectContext) throws -> any MTLTexture {
        let intensity = Conventions.clamp01(e.value("intensity", 1))
        guard intensity > 0 else { return input }
        var fx = ctx.fx(input)
        fx.set(0, e.color("color", RGBA(0, 0, 0, 1)))
        fx.set(1, e.color("secondColor", RGBA(1, 1, 1, 1)))
        fx.set(2, SIMD4(Float(e.value("colorLumaCutoff", 1)), Float(e.value("secondColorLumaCutoff", 0)),
                        Float(intensity), Float(Conventions.clamp01(e.value("desaturation", 0)))))
        return try ctx.gpu.pass("cursorcolor_fs", textures: [input], fx: fx, commandBuffer: ctx.commandBuffer)
    }

    var source: String { """
    fragment float4 cursorcolor_fs(FSOut in [[stage_in]], constant FX& fx [[buffer(0)]],
                                   texture2d<float> src [[texture(0)]], sampler smp [[sampler(0)]]) {
        float4 c = src.sample(smp, in.uv);
        if (c.a <= 0.0) return c;
        float3 rgb = c.rgb / c.a;
        float l = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        float hi = fx.p[2].x, lo = fx.p[2].y;
        float t = abs(hi - lo) < 1e-5 ? step(lo, l) : clamp((l - lo) / (hi - lo), 0.0, 1.0);
        float4 tint = mix(fx.p[1], fx.p[0], t);
        float3 base = mix(rgb, float3(l), fx.p[2].w);
        float3 outc = mix(base, tint.rgb, fx.p[2].z);
        float a = c.a * mix(1.0, tint.a, fx.p[2].z);
        return float4(outc * a, a);
    }
    """ }
}
