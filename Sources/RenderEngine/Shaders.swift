import simd

/// Metal source compiled at runtime (`device.makeLibrary(source:)`), so the
/// package builds without the Metal toolchain.
enum Shaders {
    /// Declarations shared by every library (core, effects, translated shader backgrounds).
    static let common = """
    #include <metal_stdlib>
    using namespace metal;

    struct Quad {
        float3x3 m;      // layer-local px -> pass NDC
        float4 rect;     // visible local rect: minX, minY, maxX, maxY (+y up)
        float4 uv;       // texture coords at (minX, minY) and (maxX, maxY)
        float4 full;     // full local rect, for gradients
        float opacity;
        float pad0, pad1, pad2;
        float4 c0, c1, c2, c3;   // gradient corners: top-left, top-right, bottom-left, bottom-right
    };

    struct VOut {
        float4 pos [[position]];
        float2 uv;
        float2 g;   // 0..1 across the full layer, +y up
    };

    // Full-texture pass (effects, transitions): uv and px have a top-left origin, y down.
    struct FSOut {
        float4 pos [[position]];
        float2 uv;
    };

    // Uniforms of a full-texture effect pass. Units: texture px unless noted.
    struct FX {
        float4 rect;      // content (visible layer) rect in the input: x0, y0, x1, y1
        float2 size;      // texture size
        float scale;      // texture px per layer px
        float rotation;   // layer -> canvas rotation, radians (counter-clockwise, +y up)
        float4 p[8];      // effect parameters (per effect)
    };

    // Samples outside [0,1] read transparent.
    inline float4 fx_sample(texture2d<float> t, sampler s, float2 uv) {
        if (any(uv < 0.0) || any(uv > 1.0)) return float4(0.0);
        return t.sample(s, uv);
    }

    // Signed distance to a rounded box centred at 0 with half-size b and corner radius r.
    inline float fx_sd_round_box(float2 p, float2 b, float r) {
        float2 q = abs(p) - b + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }
    """

    static let source = common + """

    vertex VOut quad_vs(uint vid [[vertex_id]], constant Quad& q [[buffer(0)]]) {
        float2 corner = float2(float(vid & 1u), float(vid >> 1u));
        float2 p = mix(q.rect.xy, q.rect.zw, corner);
        float3 n = q.m * float3(p, 1.0);
        VOut o;
        o.pos = float4(n.xy, 0.0, 1.0);
        o.uv = mix(q.uv.xy, q.uv.zw, corner);
        float2 span = max(q.full.zw - q.full.xy, float2(1e-6));
        o.g = (p - q.full.xy) / span;
        return o;
    }

    // Texture content is premultiplied BGRA (Metal swizzles to RGBA on sample).
    fragment float4 texture_fs(VOut in [[stage_in]], constant Quad& q [[buffer(0)]],
                               texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
        return tex.sample(smp, in.uv) * q.opacity;
    }

    fragment float4 gradient_fs(VOut in [[stage_in]], constant Quad& q [[buffer(0)]]) {
        float2 g = clamp(in.g, 0.0, 1.0);
        float4 top = mix(q.c0, q.c1, g.x);
        float4 bottom = mix(q.c2, q.c3, g.x);
        float4 c = mix(bottom, top, g.y);
        return float4(c.rgb * c.a, c.a) * q.opacity;
    }

    vertex FSOut fullscreen_vs(uint vid [[vertex_id]]) {
        float2 corner = float2(float(vid & 1u), float(vid >> 1u));
        FSOut o;
        o.pos = float4(corner * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(corner.x, 1.0 - corner.y);
        return o;
    }

    // MARK: Screen-space passes (backdrop effects). Textures sampled at the fragment's pixel position
    // are the same size as the pass target. Parameters ride in q.c0.

    // q.c1.xy = the pass target's size in px (set by the compositor for screen passes).
    inline float2 screen_uv(VOut in, constant Quad& q) {
        return in.pos.xy / max(q.c1.xy, float2(1.0));
    }

    fragment float4 screen_fs(VOut in [[stage_in]], constant Quad& q [[buffer(0)]],
                              texture2d<float> t [[texture(0)]], sampler smp [[sampler(0)]]) {
        return t.sample(smp, screen_uv(in, q)) * q.opacity;
    }

    // Blocks of q.c0.x target px, each showing the colour at its centre.
    fragment float4 pixelate_fs(VOut in [[stage_in]], constant Quad& q [[buffer(0)]],
                                texture2d<float> t [[texture(0)]], sampler smp [[sampler(0)]]) {
        float b = max(q.c0.x, 1.0);
        float2 px = (floor(in.pos.xy / b) + 0.5) * b;
        return t.sample(smp, px / max(q.c1.xy, float2(1.0))) * q.opacity;
    }

    inline float3 unpremul(float4 c) { return c.a > 0.0 ? c.rgb / c.a : float3(0.0); }
    inline float wz_luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
    inline float3 wz_setlum(float3 c, float l) {
        c += l - wz_luma(c);
        float n = min(c.r, min(c.g, c.b)), x = max(c.r, max(c.g, c.b)), L = wz_luma(c);
        if (n < 0.0) c = L + (c - L) * L / max(L - n, 1e-6);
        if (x > 1.0) c = L + (c - L) * (1.0 - L) / max(x - L, 1e-6);
        return c;
    }
    inline float wz_sat(float3 c) { return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b)); }
    inline float3 wz_setsat(float3 c, float s) {
        float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
        return mx > mn ? (c - mn) * s / (mx - mn) : float3(0.0);
    }
    inline float3 wz_softlight(float3 b, float3 s) {
        float3 d = select(sqrt(b), ((16.0 * b - 12.0) * b + 4.0) * b, b <= 0.25);
        return select(b + (2.0 * s - 1.0) * (d - b), b - (1.0 - 2.0 * s) * b * (1.0 - b), s <= 0.5);
    }
    // Separable and non-separable blend functions (PDF / W3C compositing definitions).
    // b = backdrop, s = source, straight colour 0-1. Mode ids are WizRec's own (BlendModeEffect.Mode).
    inline float3 blend_fn(int mode, float3 b, float3 s) {
        switch (mode) {
        case 1: return b * s;                                                     // multiply
        case 2: return b + s - b * s;                                             // screen
        case 3: return select(b * 2.0 * s, 1.0 - 2.0 * (1.0 - b) * (1.0 - s), b > 0.5);   // overlay
        case 4: return min(b, s);                                                 // darken
        case 5: return max(b, s);                                                 // lighten
        case 6: return select(min(1.0, b / max(1.0 - s, 1e-6)), float3(1.0), s >= 1.0);    // colour dodge
        case 7: return select(1.0 - min(1.0, (1.0 - b) / max(s, 1e-6)), float3(0.0), s <= 0.0); // colour burn
        case 8: return select(b * 2.0 * s, 1.0 - 2.0 * (1.0 - b) * (1.0 - s), s > 0.5);   // hard light
        case 9: return wz_softlight(b, s);                                        // soft light
        case 10: return abs(b - s);                                               // difference
        case 11: return b + s - 2.0 * b * s;                                      // exclusion
        case 12: return wz_setlum(wz_setsat(s, wz_sat(b)), wz_luma(b));           // hue
        case 13: return wz_setlum(wz_setsat(b, wz_sat(s)), wz_luma(b));           // saturation
        case 14: return wz_setlum(s, wz_luma(b));                                 // colour
        case 15: return wz_setlum(b, wz_luma(s));                                 // luminosity
        case 16: return min(b + s, 1.0);                                          // add (linear dodge)
        case 17: return max(b + s - 1.0, 0.0);                                    // linear burn
        case 18: return max(b - s, 0.0);                                          // subtract
        default: return s;                                                        // normal
        }
    }

    // Layer (texture 0, layer uv) over backdrop (texture 1, screen). q.c0 = (mode, intensity).
    // Source-over of mix(L, blend(B, L), intensity) with the layer's alpha.
    fragment float4 blend_fs(VOut in [[stage_in]], constant Quad& q [[buffer(0)]],
                             texture2d<float> L [[texture(0)]], texture2d<float> B [[texture(1)]],
                             sampler smp [[sampler(0)]]) {
        float4 l = L.sample(smp, in.uv);
        float4 b = B.sample(smp, screen_uv(in, q));
        float3 s = unpremul(l);
        float3 c = mix(s, clamp(blend_fn(int(q.c0.x), unpremul(b), s), 0.0, 1.0), q.c0.y);
        float a = l.a * q.opacity;
        return float4(c * a, a);
    }

    // Content (texture 0) masked by a matte (texture 1), both screen-space. q.c0 = (luminosity?, invert?, intensity).
    fragment float4 matte_fs(VOut in [[stage_in]], constant Quad& q [[buffer(0)]],
                             texture2d<float> C [[texture(0)]], texture2d<float> M [[texture(1)]],
                             sampler smp [[sampler(0)]]) {
        float4 c = C.sample(smp, screen_uv(in, q));
        float4 m = M.sample(smp, screen_uv(in, q));
        float v = q.c0.x > 0.5 ? wz_luma(unpremul(m)) * m.a : m.a;
        if (q.c0.y > 0.5) v = 1.0 - v;
        return c * mix(1.0, v, q.c0.z) * q.opacity;
    }

    // Backdrop (texture 0) darkened by q.c0.x outside the mask (texture 1 alpha), both screen-space.
    fragment float4 spotlight_fs(VOut in [[stage_in]], constant Quad& q [[buffer(0)]],
                                 texture2d<float> B [[texture(0)]], texture2d<float> M [[texture(1)]],
                                 sampler smp [[sampler(0)]]) {
        float4 b = B.sample(smp, screen_uv(in, q));
        float m = M.sample(smp, screen_uv(in, q)).a;
        float k = mix(1.0 - q.c0.x, 1.0, m);
        return float4(b.rgb * k, b.a);
    }

    // Copies the input unchanged (pass-through, tests).
    fragment float4 copy_fs(FSOut in [[stage_in]], constant FX& fx [[buffer(0)]],
                            texture2d<float> src [[texture(0)]], sampler smp [[sampler(0)]]) {
        return src.sample(smp, in.uv);
    }
    """

    /// Mirrors `struct Quad` above (simd types share Metal's alignment).
    struct Quad {
        var m: simd_float3x3
        var rect: SIMD4<Float>
        var uv: SIMD4<Float>
        var full: SIMD4<Float>
        var opacity: Float
        var pad0: Float = 0, pad1: Float = 0, pad2: Float = 0
        var c0 = SIMD4<Float>(repeating: 0), c1 = SIMD4<Float>(repeating: 0)
        var c2 = SIMD4<Float>(repeating: 0), c3 = SIMD4<Float>(repeating: 0)
    }

    /// Mirrors `struct FX`.
    struct FX {
        var rect: SIMD4<Float>
        var size: SIMD2<Float>
        var scale: Float
        var rotation: Float
        var p: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero,
                                                                           .zero, .zero, .zero, .zero)

        /// Sets parameter slot `i` (0–7).
        mutating func set(_ i: Int, _ v: SIMD4<Float>) {
            switch i {
            case 0: p.0 = v
            case 1: p.1 = v
            case 2: p.2 = v
            case 3: p.3 = v
            case 4: p.4 = v
            case 5: p.5 = v
            case 6: p.6 = v
            default: p.7 = v
            }
        }
    }
}
