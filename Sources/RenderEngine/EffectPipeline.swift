import CoreGraphics
import Foundation
import Metal
import os

/// Extra room around a layer's visible rect that an effect draws into, layer px.
struct Margin: Equatable, Sendable {
    var left = 0.0, top = 0.0, right = 0.0, bottom = 0.0
    static let zero = Margin()
    static func + (a: Margin, b: Margin) -> Margin {
        Margin(left: a.left + b.left, top: a.top + b.top, right: a.right + b.right, bottom: a.bottom + b.bottom)
    }
    static func all(_ v: Double) -> Margin { Margin(left: v, top: v, right: v, bottom: v) }
}

/// What an effect pass gets besides its parameters.
struct EffectContext {
    let gpu: EffectGPU
    let commandBuffer: any MTLCommandBuffer
    /// Visible layer rect inside the input texture, texture px (top-left origin): x0, y0, x1, y1.
    var contentRect: SIMD4<Float>
    /// Texture px per layer px.
    let scale: Double
    /// Layer px per canvas px (the layer transform's scale, groups included); 1 = unscaled.
    let layerScale: Double
    /// Layer → canvas rotation, radians, counter-clockwise (+y up).
    let rotation: Double
    /// The layer's natural size, layer px.
    let layerSize: CGSize
    /// The layer's local origin (its centre) in the input texture, texture px (top-left origin, y down).
    let layerOrigin: CGPoint

    /// Uniform block for a full-texture pass over `input`.
    func fx(_ input: any MTLTexture) -> Shaders.FX {
        Shaders.FX(rect: contentRect, size: SIMD2(Float(input.width), Float(input.height)),
                   scale: Float(scale), rotation: Float(rotation))
    }
}

/// Draws one effect type. Implementations are stateless; GPU state lives in `EffectGPU`.
protocol EffectRenderer: Sendable {
    /// MSL for this effect's fragment functions (compiled together with `Shaders.common`).
    var source: String { get }
    /// Room the effect needs around the visible rect, layer px.
    func margin(_ e: EffectInstance, ctx: MarginContext) -> Margin
    /// Encodes the effect; returns the output texture (`input` itself for a no-op).
    func encode(_ e: EffectInstance, input: any MTLTexture, ctx: inout EffectContext) throws -> any MTLTexture
}

/// Inputs to `EffectRenderer.margin`.
struct MarginContext {
    /// Layer px per canvas px.
    let layerScale: Double
    let rotation: Double
    let contentSize: CGSize
}

extension EffectRenderer {
    func margin(_ e: EffectInstance, ctx: MarginContext) -> Margin { .zero }
}

/// All effects the compositor can draw, keyed by `effectName`.
enum EffectRegistry {
    static let renderers: [String: any EffectRenderer] = [
        "RoundCorners": RoundCornersEffect(),
        "DropShadow": DropShadowEffect(),
        "Mask": MaskEffect(),
        "ColorAdjustment": ColorAdjustmentEffect(),
    ]

    /// Layer-pass effects plus the compositing ones the compositor draws itself.
    static var names: Set<String> {
        Set(renderers.keys).union([BlendModeSpec.name, MediaMatteSpec.name, "MotionBlur"])
    }

    static func renderer(_ name: String) -> (any EffectRenderer)? { renderers[name] }

    /// The effects to draw: renderable and not bypassed, in array order [effects/README.md §1].
    static func active(_ effects: [EffectInstance]) -> [(EffectInstance, any EffectRenderer)] {
        effects.compactMap { e -> (EffectInstance, any EffectRenderer)? in
            guard !e.bypassed, let r = renderers[e.name] else { return nil }
            return (e, r)
        }
    }

    /// Every effect and transition fragment function, compiled as one library on first use.
    static var source: String {
        Shaders.common + GaussianBlur.source
            + renderers.keys.sorted().compactMap { renderers[$0]?.source }.joined(separator: "\n")
            + TransitionRegistry.source
    }
}

/// GPU resources for effect and transition passes: the lazily compiled effect library,
/// no-blend pipelines, a sampler and the texture pool.
final class EffectGPU {
    let device: any MTLDevice
    let pool: TexturePool
    let sampler: any MTLSamplerState
    private let core: any MTLLibrary
    private var effectLibrary: (any MTLLibrary)?
    private var pipelines: [String: any MTLRenderPipelineState] = [:]

    /// Intermediate format for effect chains: half float avoids banding in blurs and shadows.
    static let format: MTLPixelFormat = .rgba16Float

    /// 1×1 transparent texture bound for absent inputs (Metal must not sample unbound slots).
    let clear: any MTLTexture

    init(device: any MTLDevice, core: any MTLLibrary, sampler: any MTLSamplerState) throws {
        self.device = device; self.core = core; self.sampler = sampler
        pool = TexturePool(device: device)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { throw RenderError.noMetalDevice }
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 0, count: 4),
                  bytesPerRow: 4)
        clear = t
    }

    private func library(for function: String) throws -> any MTLLibrary {
        if core.functionNames.contains(function) { return core }
        if let l = effectLibrary { return l }
        do {
            let l = try device.makeLibrary(source: EffectRegistry.source, options: nil)
            effectLibrary = l
            return l
        } catch {
            throw RenderError.shaderCompile(String(describing: error))
        }
    }

    /// Full-texture pipeline writing `format` without blending (or premultiplied source-over).
    func pipeline(_ fragment: String, format: MTLPixelFormat = EffectGPU.format, blend: Bool = false) throws
        -> any MTLRenderPipelineState {
        let key = "\(fragment)|\(format.rawValue)|\(blend)"
        if let p = pipelines[key] { return p }
        let lib = try library(for: fragment)
        guard let f = lib.makeFunction(name: fragment), let v = core.makeFunction(name: "fullscreen_vs") else {
            throw RenderError.shaderCompile("missing function \(fragment)")
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = v
        d.fragmentFunction = f
        let a = d.colorAttachments[0]!
        a.pixelFormat = format
        if blend {
            a.isBlendingEnabled = true
            a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        do {
            let p = try device.makeRenderPipelineState(descriptor: d)
            pipelines[key] = p
            return p
        } catch {
            throw RenderError.shaderCompile(String(describing: error))
        }
    }

    /// One full-texture pass: `fragment(textures, fx)` → a new pooled texture of `size`
    /// (default: the first texture's size). Texture slots follow `textures` order; nil = unbound.
    func pass(_ fragment: String, textures: [(any MTLTexture)?], fx: Shaders.FX,
              size: (Int, Int)? = nil, commandBuffer: any MTLCommandBuffer) throws -> any MTLTexture {
        let w = size?.0 ?? textures.compactMap { $0 }.first?.width ?? 1
        let h = size?.1 ?? textures.compactMap { $0 }.first?.height ?? 1
        let out = try pool.take(width: w, height: h, format: EffectGPU.format, commandBuffer: commandBuffer)
        try draw(fragment, into: out, textures: textures, fx: fx, commandBuffer: commandBuffer)
        return out
    }

    /// Draws a full-texture pass into `target` (cleared first).
    func draw(_ fragment: String, into target: any MTLTexture, textures: [(any MTLTexture)?], fx: Shaders.FX,
              commandBuffer: any MTLCommandBuffer) throws {
        let p = try pipeline(fragment, format: target.pixelFormat)
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(p)
        var fx = fx
        enc.setFragmentBytes(&fx, length: MemoryLayout<Shaders.FX>.stride, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        for (i, t) in textures.enumerated() { enc.setFragmentTexture(t ?? clear, index: i) }
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }
}

/// Recycles private render-target textures. A texture taken for a command buffer goes
/// back to the pool when that command buffer completes, so reuse never races the GPU.
/// Entries idle for more than `maxIdleFrames` releases are dropped.
// @unchecked: all mutable state is guarded by `lock`; completion handlers run on Metal's thread.
final class TexturePool: @unchecked Sendable {
    private struct Key: Hashable { var w: Int; var h: Int; var format: UInt }
    private struct Entry { var texture: any MTLTexture; var age: Int }
    private let device: any MTLDevice
    private let lock = OSAllocatedUnfairLock()
    private var free: [Key: [Entry]] = [:]
    private var generation = 0
    static let maxIdleFrames = 8

    init(device: any MTLDevice) { self.device = device }

    func take(width: Int, height: Int, format: MTLPixelFormat,
              commandBuffer: any MTLCommandBuffer) throws -> any MTLTexture {
        let key = Key(w: max(width, 1), h: max(height, 1), format: format.rawValue)
        let reused: (any MTLTexture)? = lock.withLockUnchecked {
            guard var list = free[key], !list.isEmpty else { return nil }
            let e = list.removeLast()
            free[key] = list
            return e.texture
        }
        let tex: any MTLTexture
        if let reused { tex = reused } else {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: key.w, height: key.h,
                                                             mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RenderError.noMetalDevice }
            tex = t
        }
        let box = GPURetainer([tex])
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self, let t = box.objects.first as? any MTLTexture else { return }
            self.giveBack(t, key: key)
        }
        return tex
    }

    private func giveBack(_ t: any MTLTexture, key: Key) {
        lock.withLockUnchecked {
            generation += 1
            free[key, default: []].append(Entry(texture: t, age: generation))
            let horizon = generation - Self.maxIdleFrames * 16
            for (k, list) in free {
                let kept = list.filter { $0.age >= horizon }
                free[k] = kept.isEmpty ? nil : kept
            }
        }
    }

    /// Textures currently idle in the pool (tests, diagnostics).
    var idleCount: Int { lock.withLock { free.values.reduce(0) { $0 + $1.count } } }
}
