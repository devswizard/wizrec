import CoreGraphics
import Foundation
import Metal

// Group-1 visual effects. PROVISIONAL maths until `docs/specs/effects/<Name>.md` is
// published: every unit and default sits in the effect's `Spec` enum so the spec's answers
// are one-line changes. Tags: [obs] observed, [inf] inferred, [?] unknown.

extension EffectInstance {
    func value(_ key: String, _ d: Double) -> Double {
        let v = parameters[key] ?? d
        return v.isFinite ? v : d
    }

    /// `<prefix>-red/green/blue/alpha`, 0–1, straight alpha.
    func color(_ prefix: String, _ d: RGBA) -> SIMD4<Float> {
        SIMD4(Float(Conventions.clamp01(value("\(prefix)-red", d.r))), Float(Conventions.clamp01(value("\(prefix)-green", d.g))),
              Float(Conventions.clamp01(value("\(prefix)-blue", d.b))), Float(Conventions.clamp01(value("\(prefix)-alpha", d.a))))
    }
}

// MARK: - RoundCorners

/// Rounds the corners of the layer's visible rect (`docs/specs/effects/RoundCorners.md`).
struct RoundCornersEffect: EffectRenderer {
    enum Spec {
        /// `radius` is in layer px [inf, strong: demo 233.81 × scale 0.2887 = 67.5 canvas px exactly].
        static let radiusInCanvasPx = false
        /// Corner flags `top-left`… multiply the radius [inf, weak]; default on.
        static let cornerDefault = 1.0
    }

    func encode(_ e: EffectInstance, input: any MTLTexture, ctx: inout EffectContext) throws -> any MTLTexture {
        var r = max(e.value("radius", 0), 0)
        if Spec.radiusInCanvasPx { r /= max(ctx.layerScale, 1e-6) }
        guard r > 0 else { return input }
        var fx = ctx.fx(input)
        fx.set(0, SIMD4(Float(r * ctx.scale), 0, 0, 0))
        fx.set(1, SIMD4(Float(e.value("top-left", Spec.cornerDefault)), Float(e.value("top-right", Spec.cornerDefault)),
                        Float(e.value("bottom-right", Spec.cornerDefault)), Float(e.value("bottom-left", Spec.cornerDefault))))
        return try ctx.gpu.pass("roundcorners_fs", textures: [input], fx: fx, commandBuffer: ctx.commandBuffer)
    }

    var source: String { """
    fragment float4 roundcorners_fs(FSOut in [[stage_in]], constant FX& fx [[buffer(0)]],
                                    texture2d<float> src [[texture(0)]], sampler smp [[sampler(0)]]) {
        float4 c = src.sample(smp, in.uv);
        float2 px = in.uv * fx.size;
        float2 lo = fx.rect.xy, hi = fx.rect.zw;
        float2 centre = (lo + hi) * 0.5, half_ = (hi - lo) * 0.5;
        float2 p = px - centre;   // y down
        float4 flags = fx.p[1];   // tl, tr, br, bl
        float on = p.x < 0.0 ? (p.y < 0.0 ? flags.x : flags.w) : (p.y < 0.0 ? flags.y : flags.z);
        float r = min(fx.p[0].x * clamp(on, 0.0, 1.0), min(half_.x, half_.y));
        float d = fx_sd_round_box(p, half_, r);
        return c * clamp(0.5 - d, 0.0, 1.0);
    }
    """ }
}

// MARK: - Mask

/// Keeps an ellipse or rectangle of the layer; the rest gets `mask-opacity`
/// (`docs/specs/effects/Mask.md`).
struct MaskEffect: EffectRenderer {
    enum Spec {
        /// `mask-width/height/positionX/Y` in layer px, origin at the layer centre [obs, transform.md §10];
        /// +y up like `translation1` [?, assumed].
        static let positionYUp = true
        /// `mask-shape`: 0 = ellipse [inf, strong: the demo circle]; other values = (rounded) rectangle [?].
        static let ellipseShape = 0.0
        /// `mask-opacity` = alpha kept outside the shape [inf]. `mask-blend` = feather, sign and units [?];
        /// ignored (1-px antialiasing; the demo's −0.02 is a hard edge [obs]).
    }

    func encode(_ e: EffectInstance, input: any MTLTexture, ctx: inout EffectContext) throws -> any MTLTexture {
        let w = e.value("mask-width", ctx.layerSize.width), h = e.value("mask-height", ctx.layerSize.height)
        let x = e.value("mask-positionX", 0), y = e.value("mask-positionY", 0) * (Spec.positionYUp ? 1 : -1)
        let s = ctx.scale
        let origin = ctx.layerOrigin
        let cx = origin.x + x * s, cy = origin.y - y * s
        let outside = Conventions.clamp01(e.value("mask-opacity", 0))
        let invert = e.value("mask-invert", 0) >= 0.5
        var fx = ctx.fx(input)
        fx.set(0, SIMD4(Float(cx), Float(cy), Float(w * s / 2), Float(h * s / 2)))
        fx.set(1, SIMD4(Float(e.value("mask-rotation", 0)), Float(max(e.value("mask-cornerRadius", 0), 0) * s),
                        Float(abs(e.value("mask-shape", 0) - Spec.ellipseShape) < 0.5 ? 1 : 0), Float(outside)))
        fx.set(2, SIMD4(invert ? 1 : 0, 0, 0, 0))
        // Whether later effects see the mask's box as the layer bounds is [?] (EF3 cell 6): they don't.
        return try ctx.gpu.pass("mask_fs", textures: [input], fx: fx, commandBuffer: ctx.commandBuffer)
    }

    var source: String { """
    fragment float4 mask_fs(FSOut in [[stage_in]], constant FX& fx [[buffer(0)]],
                            texture2d<float> src [[texture(0)]], sampler smp [[sampler(0)]]) {
        float4 c = src.sample(smp, in.uv);
        float2 p = in.uv * fx.size - fx.p[0].xy;          // y down
        float a = fx.p[1].x;                              // rotation, ccw in y-up space
        float2 q = float2(cos(a) * p.x - sin(a) * p.y, sin(a) * p.x + cos(a) * p.y);
        float2 b = fx.p[0].zw;
        float d;
        if (fx.p[1].z > 0.5) {
            float2 n = q / max(b, float2(1e-3));
            d = (length(n) - 1.0) * min(b.x, b.y);
        } else {
            d = fx_sd_round_box(q, b, min(fx.p[1].y, min(b.x, b.y)));
        }
        float inside = clamp(0.5 - d, 0.0, 1.0);
        if (fx.p[2].x > 0.5) inside = 1.0 - inside;
        return c * mix(fx.p[1].w, 1.0, inside);
    }
    """ }
}

// MARK: - DropShadow

/// A blurred, offset copy of the layer's alpha behind it (`docs/specs/effects/DropShadow.md`).
struct DropShadowEffect: EffectRenderer {
    enum Spec {
        /// `offset` and `blur` are canvas px [obs, weak: E-thumb fit]; `angle` radians, counter-clockwise
        /// from +x in +y-up canvas space, fixed on the canvas [obs: demo 3π/2 = down; rotation ?].
        static let canvasUnits = true
        /// Gaussian σ = blur / 2 canvas px [inf, fit].
        static let sigmaPerBlur = 0.5
        static let defaultColor = RGBA(0, 0, 0, 1)
    }

    func margin(_ e: EffectInstance, ctx: MarginContext) -> Margin {
        guard e.value("enabled", 1) >= 0.5 else { return .zero }
        let k = Spec.canvasUnits ? 1 / max(ctx.layerScale, 1e-6) : 1
        let reach = (abs(e.value("offset", 0)) + 3 * Spec.sigmaPerBlur * max(e.value("blur", 0), 0) + 2) * k
        return .all(reach)
    }

    func encode(_ e: EffectInstance, input: any MTLTexture, ctx: inout EffectContext) throws -> any MTLTexture {
        guard e.value("enabled", 1) >= 0.5, e.value("opacity", 1) > 0 else { return input }
        let k = (Spec.canvasUnits ? 1 / max(ctx.layerScale, 1e-6) : 1) * ctx.scale   // canvas px → texture px
        // Canvas-space direction → layer space (undo the layer rotation), then y down.
        let a = e.value("angle", 0) - (Spec.canvasUnits ? ctx.rotation : 0)
        let off = e.value("offset", 0) * k
        let dx = cos(a) * off, dy = -sin(a) * off
        let sigma = Spec.sigmaPerBlur * max(e.value("blur", 0), 0) * k
        var fx = ctx.fx(input)
        let blurred = try GaussianBlur.alpha(input, sigma: sigma, ctx: ctx)
        fx.set(0, SIMD4(Float(dx), Float(dy), Float(Conventions.clamp01(e.value("opacity", 1))), 0))
        fx.set(1, e.color("color", Spec.defaultColor))
        return try ctx.gpu.pass("shadow_composite_fs", textures: [input, blurred], fx: fx,
                                commandBuffer: ctx.commandBuffer)
    }

    var source: String { """
    fragment float4 shadow_composite_fs(FSOut in [[stage_in]], constant FX& fx [[buffer(0)]],
                                        texture2d<float> src [[texture(0)]], texture2d<float> blur [[texture(1)]],
                                        sampler smp [[sampler(0)]]) {
        float4 c = src.sample(smp, in.uv);
        float2 uv = in.uv - fx.p[0].xy / fx.size;
        float a = fx_sample(blur, smp, uv).a * fx.p[0].z * fx.p[1].a;
        float4 shadow = float4(fx.p[1].rgb * a, a);
        return c + shadow * (1.0 - c.a);
    }
    """ }
}

/// Separable Gaussian blur of a texture (or of its alpha only), sigma in texture px.
enum GaussianBlur {
    /// Most taps per side per pass; larger sigmas stretch the tap spacing.
    static let maxTaps = 48

    static func alpha(_ input: any MTLTexture, sigma: Double, ctx: EffectContext) throws -> any MTLTexture {
        try run(input, sigma: sigma, alphaOnly: true, ctx: ctx)
    }

    /// Above this sigma (texture px) the blur runs on a box-downsampled copy, `sigma / 4`× smaller
    /// (at most 8×), which keeps large shadows cheap; the result is sampled back bilinearly.
    static let downsampleAbove = 4.0

    static func run(_ input: any MTLTexture, sigma: Double, alphaOnly: Bool, ctx: EffectContext) throws
        -> any MTLTexture {
        let s0 = max(sigma, 0)
        let f = s0 > downsampleAbove ? min(Int((s0 / downsampleAbove).rounded(.up)), 8) : 1
        var src = input
        if f > 1 {
            let size = (max(input.width / f, 1), max(input.height / f, 1))
            var d = ctx.fx(input)
            d.size = SIMD2(Float(size.0), Float(size.1))
            d.set(0, SIMD4(Float(f), alphaOnly ? 1 : 0, 0, 0))
            src = try ctx.gpu.pass("downsample_fs", textures: [input], fx: d, size: size,
                                   commandBuffer: ctx.commandBuffer)
        }
        var fx = ctx.fx(src)
        let s = s0 * Double(src.width) / Double(max(input.width, 1))
        let reach = ceil(3 * s)
        let taps = Float(min(max(reach, 0), Double(maxTaps)))
        let step = taps > 0 ? Float(reach) / taps : 1
        fx.set(0, SIMD4(Float(s), taps, step, alphaOnly ? 1 : 0))
        fx.set(1, SIMD4(1, 0, 0, 0))
        let h = try ctx.gpu.pass("blur_fs", textures: [src], fx: fx, commandBuffer: ctx.commandBuffer)
        fx.set(1, SIMD4(0, 1, 0, 0))
        return try ctx.gpu.pass("blur_fs", textures: [h], fx: fx, commandBuffer: ctx.commandBuffer)
    }

    static let source = """
    // Box-filters f×f input pixels into each output pixel (fx.size = output size).
    fragment float4 downsample_fs(FSOut in [[stage_in]], constant FX& fx [[buffer(0)]],
                                  texture2d<float> src [[texture(0)]], sampler smp [[sampler(0)]]) {
        int f = int(fx.p[0].x);
        float4 acc = float4(0.0);
        for (int j = 0; j < f; j++) {
            for (int i = 0; i < f; i++) {
                float2 o = (float2(i, j) + 0.5) / float(f) - 0.5;
                acc += src.sample(smp, in.uv + o / fx.size);
            }
        }
        float4 c = acc / float(f * f);
        return fx.p[0].y > 0.5 ? float4(0, 0, 0, c.a) : c;
    }

    fragment float4 blur_fs(FSOut in [[stage_in]], constant FX& fx [[buffer(0)]],
                            texture2d<float> src [[texture(0)]], sampler smp [[sampler(0)]]) {
        float sigma = fx.p[0].x;
        int taps = int(fx.p[0].y);
        float stepPx = fx.p[0].z;
        float2 dir = fx.p[1].xy / fx.size;
        if (sigma <= 0.0 || taps == 0) {
            float4 c = fx_sample(src, smp, in.uv);
            return fx.p[0].w > 0.5 ? float4(0, 0, 0, c.a) : c;
        }
        float4 acc = float4(0.0);
        float wsum = 0.0;
        for (int i = -taps; i <= taps; i++) {
            float x = float(i) * stepPx;
            float w = exp(-0.5 * x * x / (sigma * sigma));
            acc += fx_sample(src, smp, in.uv + dir * x) * w;
            wsum += w;
        }
        float4 c = acc / wsum;
        return fx.p[0].w > 0.5 ? float4(0, 0, 0, c.a) : c;
    }
    """
}

// MARK: - ColorAdjustment

/// Brightness / contrast / saturation.
struct ColorAdjustmentEffect: EffectRenderer {
    enum Spec {
        /// Neutral at 0 for all three [?]: brightness adds, contrast scales around 0.5 by (1 + c),
        /// saturation mixes with Rec. 709 luma by (1 + s). Ranges unknown.
        static let neutral = 0.0
    }

    func encode(_ e: EffectInstance, input: any MTLTexture, ctx: inout EffectContext) throws -> any MTLTexture {
        let b = e.value("brightness", Spec.neutral), c = e.value("contrast", Spec.neutral)
        let s = e.value("saturation", Spec.neutral)
        guard b != 0 || c != 0 || s != 0 else { return input }
        var fx = ctx.fx(input)
        fx.set(0, SIMD4(Float(b), Float(1 + c), Float(1 + s), 0))
        return try ctx.gpu.pass("coloradjust_fs", textures: [input], fx: fx, commandBuffer: ctx.commandBuffer)
    }

    var source: String { """
    fragment float4 coloradjust_fs(FSOut in [[stage_in]], constant FX& fx [[buffer(0)]],
                                   texture2d<float> src [[texture(0)]], sampler smp [[sampler(0)]]) {
        float4 c = src.sample(smp, in.uv);
        if (c.a <= 0.0) return c;
        float3 rgb = c.rgb / c.a;
        rgb += fx.p[0].x;
        rgb = (rgb - 0.5) * fx.p[0].y + 0.5;
        float l = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        rgb = mix(float3(l), rgb, fx.p[0].z);
        return float4(clamp(rgb, 0.0, 1.0) * c.a, c.a);
    }
    """ }
}
