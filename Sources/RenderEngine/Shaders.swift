import simd

/// Metal source compiled at runtime (`device.makeLibrary(source:)`), so the
/// package builds without the Metal toolchain.
enum Shaders {
    static let source = """
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
}
