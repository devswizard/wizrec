import Foundation
import Metal

/// A transition written in GLSL (WizRec's own library, `WizRecAssets`), translated to MSL at
/// first use with `GLSLTranslator` in `.transition` mode. `_Progress` = `t.progress`
/// (1 − progress when `t.reverse`); `textureA` = outgoing, `textureB` = incoming; uniforms
/// `_<name>` come from `t.parameters` (`float`: `name`; `vec3`/`vec4`:
/// `name-red/-green/-blue/-alpha`), else 0 (alpha 1). If the program cannot be built, the
/// transition cross-fades instead (the failure is remembered by `EffectGPU`).
struct GLSLTransition: TransitionRenderer {
    let name: String
    let glsl: String

    /// Compiled into its own library, not the shared effect library.
    var source: String { "" }

    func encode(_ t: TransitionInstance, from: (any MTLTexture)?, to: (any MTLTexture)?, size: (Int, Int),
                gpu: EffectGPU, commandBuffer: any MTLCommandBuffer) throws -> any MTLTexture {
        let uniforms: [GLSLTranslator.Uniform]
        let pipeline: any MTLRenderPipelineState
        do {
            let out = try GLSLTranslator.translate(glsl, mode: .transition)
            uniforms = out.uniforms
            pipeline = try gpu.customPipeline(key: "transition:\(name)",
                                              fragment: GLSLTranslator.Output.transitionFragmentName,
                                              format: EffectGPU.format) { out.source }
        } catch {
            return try FadeTransition().encode(t, from: from, to: to, size: size, gpu: gpu, commandBuffer: commandBuffer)
        }
        let p = Conventions.clamp01(t.progress)
        var bytes: [SIMD4<Float>] = [SIMD4(Float(t.reverse ? 1 - p : p), Float(size.0), Float(size.1), 0)]
        bytes += uniforms.map { Self.value($0, t.parameters) }
        if uniforms.isEmpty { bytes.append(.zero) }
        return try gpu.customPass(pipeline, textures: [from, to], uniforms: bytes, size: size,
                                  commandBuffer: commandBuffer)
    }

    /// The `float4` slot for uniform `u` from the transition's parameters.
    static func value(_ u: GLSLTranslator.Uniform, _ p: [String: Double]) -> SIMD4<Float> {
        let key = u.name.hasPrefix("_") ? String(u.name.dropFirst()) : u.name
        switch u.type {
        case "vec3", "vec4":
            var c = SIMD4<Float>(0, 0, 0, 1)
            for (i, ch) in ["red", "green", "blue", "alpha"].enumerated() {
                if let v = p["\(key)-\(ch)"] { c[i] = Float(v) }
            }
            return c
        default:
            return SIMD4(Float(p[key] ?? 0), 0, 0, 0)
        }
    }
}
