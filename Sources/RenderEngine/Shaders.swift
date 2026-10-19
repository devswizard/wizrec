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
