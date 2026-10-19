import Foundation
import Metal

/// Draws one transition type from the outgoing (`from`) and incoming (`to`) images, both
/// rendered over the transition layer's full rect. A nil side is transparent
/// [transitions.md §6]. Built-in transitions are WizRec's own shaders.
protocol TransitionRenderer: Sendable {
    /// MSL fragment functions (compiled with the effect library).
    var source: String { get }
    func encode(_ t: TransitionInstance, from: (any MTLTexture)?, to: (any MTLTexture)?, size: (Int, Int),
                gpu: EffectGPU, commandBuffer: any MTLCommandBuffer) throws -> any MTLTexture
}

enum TransitionRegistry {
    static let renderers: [String: any TransitionRenderer] = [
        "Fade": FadeTransition(),
        "Dissolve": FadeTransition(),
        "FadeThroughBlack": FadeThroughBlackTransition(),
    ]

    /// Unknown names (classic transitions without a spec yet, `.tsceffect` names) cross-fade, so
    /// the cut is at least soft and both clips stay visible for the window [inf; placeholder].
    static let fallback: any TransitionRenderer = FadeTransition()

    static func renderer(_ name: String) -> any TransitionRenderer { renderers[name] ?? fallback }

    static var names: Set<String> { Set(renderers.keys) }

    static var source: String {
        [FadeTransition().source, FadeThroughBlackTransition().source].joined(separator: "\n")
    }
}

/// Fade / Dissolve: `mix(A, B, p)` on premultiplied colour [transitions.md §6, inf].
struct FadeTransition: TransitionRenderer {
    func encode(_ t: TransitionInstance, from: (any MTLTexture)?, to: (any MTLTexture)?, size: (Int, Int),
                gpu: EffectGPU, commandBuffer: any MTLCommandBuffer) throws -> any MTLTexture {
        var fx = Shaders.FX(rect: SIMD4(0, 0, Float(size.0), Float(size.1)), size: SIMD2(Float(size.0), Float(size.1)),
                            scale: 1, rotation: 0)
        fx.set(0, SIMD4(Float(Conventions.clamp01(t.progress)), 0, 0, 0))
        return try gpu.pass("transition_fade_fs", textures: [from, to], fx: fx, size: size, commandBuffer: commandBuffer)
    }

    var source: String { """
    fragment float4 transition_fade_fs(FSOut in [[stage_in]], constant FX& fx [[buffer(0)]],
                                       texture2d<float> a [[texture(0)]], texture2d<float> b [[texture(1)]],
                                       sampler smp [[sampler(0)]]) {
        return mix(a.sample(smp, in.uv), b.sample(smp, in.uv), fx.p[0].x);
    }
    """ }
}

/// FadeThroughBlack: A → black over the first half, black → B over the second
/// [transitions.md §6, inf weak]. Black is opaque only where a side has content.
struct FadeThroughBlackTransition: TransitionRenderer {
    func encode(_ t: TransitionInstance, from: (any MTLTexture)?, to: (any MTLTexture)?, size: (Int, Int),
                gpu: EffectGPU, commandBuffer: any MTLCommandBuffer) throws -> any MTLTexture {
        var fx = Shaders.FX(rect: SIMD4(0, 0, Float(size.0), Float(size.1)), size: SIMD2(Float(size.0), Float(size.1)),
                            scale: 1, rotation: 0)
        fx.set(0, SIMD4(Float(Conventions.clamp01(t.progress)), 0, 0, 0))
        return try gpu.pass("transition_ftb_fs", textures: [from, to], fx: fx, size: size, commandBuffer: commandBuffer)
    }

    var source: String { """
    fragment float4 transition_ftb_fs(FSOut in [[stage_in]], constant FX& fx [[buffer(0)]],
                                      texture2d<float> a [[texture(0)]], texture2d<float> b [[texture(1)]],
                                      sampler smp [[sampler(0)]]) {
        float p = fx.p[0].x;
        float4 c = p < 0.5 ? a.sample(smp, in.uv) : b.sample(smp, in.uv);
        float k = p < 0.5 ? 1.0 - p * 2.0 : p * 2.0 - 1.0;   // colour weight
        return float4(c.rgb * k, c.a);
    }
    """ }
}
