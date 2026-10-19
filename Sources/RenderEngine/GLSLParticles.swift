import Foundation

/// Particle (`vertexCode`) backgrounds: the vertex and fragment GLSL become one MSL source
/// with `glsl_particle_vs` / `glsl_particle_fs` [shader-backgrounds.md §5].
///
/// Host inputs [WizRec where the spec says inf/?]:
/// - Vertex stage: `gl_VertexID` (0 ‥ vertex count − 1; no vertex buffers), `_Time` (s),
///   `_OutputSize` and `_ImageSize` (the file's natural size, px, e.g. 1920×1080, so a particle's
///   size does not depend on the output resolution), `_ToRenderTarget` (maps that pixel space,
///   origin top-left and +y down like `_TexCoord`, to clip space as `vec4(p, 0, 1) * M`, see
///   `ShaderBackgrounds.particleUniformBytes`). `gl_Position` is GL clip space; z is remapped to
///   Metal's 0…w range.
/// - Fragment stage: the vertex stage's outputs (integers flat), `_Time`, `_OutputSize`,
///   `_ImageSize`, `gl_FragCoord` (natural px, +y up, as in GL), output `_FragColor` /
///   `gl_FragColor` / its own `out vec4`, straight alpha, premultiplied on return.
/// Uniforms of both stages share one `GLUniforms` block in buffer 1 of both stages.
extension GLSLTranslator {
    struct ParticleOutput: Sendable {
        var source: String
        /// Union of both stages' uniforms, vertex stage first, by name.
        var uniforms: [Uniform]
        static let vertexName = "glsl_particle_vs"
        static let fragmentName = "glsl_particle_fs"
    }

    static let particleVertexImplicit: Set<String> = [
        "_Time", "_OutputSize", "_ImageSize", "_ToRenderTarget", "gl_VertexID", "gl_InstanceID",
        "gl_Position", "gl_PointSize",
    ]
    static let particleFragmentImplicit: Set<String> = [
        "_Time", "_OutputSize", "_ImageSize", "_FragColor", "gl_FragColor", "gl_FragCoord",
    ]

    static func translateParticles(vertex: String, fragment: String) throws -> ParticleOutput {
        let v = try parse(vertex, implicit: particleVertexImplicit, stage: .particleVertex)
        // `in vec2 _TexCoord;` and other vertex outputs are fragment members, not implicit names.
        let f = try parse(fragment, implicit: particleFragmentImplicit, stage: .particleFragment)
        var uniforms = v.uniforms
        for u in f.uniforms where !uniforms.contains(where: { $0.name == u.name }) { uniforms.append(u) }
        let varyings = v.varyings
        let (members, fill) = uniformCode(uniforms)
        let varyingMembers = varyings.map { "    \($0.type) \($0.name);\n" }.joined()
        let outFields = varyings.map { "    \($0.type) \($0.name)\($0.flat ? " [[flat]]" : "");\n" }.joined()
        let copyOut = varyings.map { "    wz_o.\($0.name) = wz_p.\($0.name);\n" }.joined()
        let copyIn = varyings.map { "    wz_p.\($0.name) = wz_in.\($0.name);\n" }.joined()
        let zero = varyings.map { "    wz_p.\($0.name) = {};\n" }.joined()
        // Vertex macros must not leak into the fragment program.
        let undefs = Set(v.macros).sorted().map { "#undef \($0)\n" }.joined()
        let source = """
        \(Shaders.common)
        \(prelude)

        struct GLUniforms {
            float4 sys;   // time s, natural w, h px, 0
            float4 dst;   // target w, h px, 0, 0
            float4x4 toTarget;
            float4 v[\(max(uniforms.count, 1))];
        };

        struct GLVOut {
            float4 wz_pos [[position]];
        \(outFields)
        };

        struct GLVertexProgram {
            float _Time;
            float2 _OutputSize;
            float2 _ImageSize;
            float4x4 _ToRenderTarget;
            int gl_VertexID;
            int gl_InstanceID;
            float4 gl_Position;
            float gl_PointSize;
        \(varyingMembers)
        \(members)
        \(v.body)
        };
        \(undefs)

        struct GLProgram {
            float _Time;
            float2 _OutputSize;
            float2 _ImageSize;
            float4 _FragColor;
            float4 gl_FragCoord;
        \(varyingMembers)
        \(members)
        \(f.body)
        };

        vertex GLVOut \(ParticleOutput.vertexName)(uint wz_vid [[vertex_id]], constant GLUniforms& wz_u [[buffer(1)]]) {
            GLVertexProgram wz_p;
            wz_p._Time = wz_u.sys.x;
            wz_p._OutputSize = wz_u.sys.yz;
            wz_p._ImageSize = wz_u.sys.yz;
            wz_p._ToRenderTarget = wz_u.toTarget;
            wz_p.gl_VertexID = int(wz_vid);
            wz_p.gl_InstanceID = 0;
            wz_p.gl_Position = float4(0.0, 0.0, 0.0, 1.0);
            wz_p.gl_PointSize = 1.0;
        \(zero)\(fill)
            wz_p.glsl_main();
            GLVOut wz_o;
            wz_o.wz_pos = wz_p.gl_Position;
            wz_o.wz_pos.z = (wz_o.wz_pos.z + wz_o.wz_pos.w) * 0.5;
        \(copyOut)
            return wz_o;
        }

        fragment float4 \(ParticleOutput.fragmentName)(GLVOut wz_in [[stage_in]], constant GLUniforms& wz_u [[buffer(1)]]) {
            GLProgram wz_p;
            wz_p._Time = wz_u.sys.x;
            wz_p._OutputSize = wz_u.sys.yz;
            wz_p._ImageSize = wz_u.sys.yz;
            float2 wz_k = wz_u.sys.yz / max(wz_u.dst.xy, float2(1.0));
            wz_p.gl_FragCoord = float4(wz_in.wz_pos.x * wz_k.x, (wz_u.dst.y - wz_in.wz_pos.y) * wz_k.y,
                                       wz_in.wz_pos.z, 1.0);
            wz_p._FragColor = float4(0.0, 0.0, 0.0, 1.0);
        \(copyIn)\(fill)
            wz_p.glsl_main();
            float4 wz_c = clamp(wz_p._FragColor, 0.0, 1.0);
            return float4(wz_c.rgb * wz_c.a, wz_c.a);
        }
        """
        return ParticleOutput(source: source, uniforms: uniforms)
    }
}
