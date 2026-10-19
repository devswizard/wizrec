import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import MediaEngine
import Metal
import simd

/// Keeps CoreVideo textures alive until the GPU has finished with them.
// @unchecked: the box is written once before it is handed to the completion
// handler and only released there; nothing reads or mutates it concurrently.
final class GPURetainer: @unchecked Sendable {
    let objects: [AnyObject]
    init(_ objects: [AnyObject]) { self.objects = objects }
}

/// Metal implementation behind `Compositor`. Not thread-safe.
///
/// Per layer: plain content draws straight into the pass; a layer with drawable effects is
/// first rendered alone, in its own local space, into an offscreen texture sized to its
/// visible rect plus the effects' margins at target resolution, then the effect passes run
/// in order, then the result is composited with the layer's transform and opacity.
/// Transitions render both sides offscreen over the parent's rect, then combine them.
final class CompositorCore {
    let device: any MTLDevice
    private let library: any MTLLibrary
    private var pipelines: [String: any MTLRenderPipelineState] = [:]
    private let sampler: any MTLSamplerState
    private var textureCache: CVMetalTextureCache?
    private var images: [URL: any MTLTexture] = [:]
    private var failedImages: Set<URL> = []
    let fx: EffectGPU
    let shaders: ShaderBackgrounds
    let callouts = CalloutRasterizer()

    init(device: any MTLDevice) throws {
        self.device = device
        do {
            library = try device.makeLibrary(source: Shaders.source, options: nil)
        } catch {
            throw RenderError.shaderCompile(String(describing: error))
        }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        guard let s = device.makeSamplerState(descriptor: sd) else { throw RenderError.noMetalDevice }
        sampler = s
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache
        fx = try EffectGPU(device: device, core: library, sampler: s)
        shaders = ShaderBackgrounds(device: device)
        _ = try pipeline("texture_fs", format: .bgra8Unorm)
        _ = try pipeline("gradient_fs", format: .bgra8Unorm)
    }

    // MARK: Pipelines

    /// Quad pipeline (premultiplied source-over) for a core fragment function or a given one.
    private func pipeline(_ name: String, function: (any MTLFunction)? = nil, format: MTLPixelFormat) throws
        -> any MTLRenderPipelineState {
        let key = "\(name)|\(format.rawValue)"
        if let p = pipelines[key] { return p }
        guard let frag = function ?? library.makeFunction(name: name) else {
            throw RenderError.shaderCompile("missing function \(name)")
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "quad_vs")
        d.fragmentFunction = frag
        let a = d.colorAttachments[0]!
        a.pixelFormat = format
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = .oneMinusSourceAlpha
        a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            let p = try device.makeRenderPipelineState(descriptor: d)
            pipelines[key] = p
            return p
        } catch {
            throw RenderError.shaderCompile(String(describing: error))
        }
    }

    // MARK: Encode

    private enum Fill {
        case texture(any MTLTexture)
        case gradient([SIMD4<Float>])
        /// A translated shader background: its program and `GLUniforms` bytes.
        case shader(URL, ShaderBackgrounds.Program, [SIMD4<Float>])
        /// A core fragment function with textures and parameters in `quad.c0`.
        case pass(String, [any MTLTexture], SIMD4<Float>)
    }

    private struct Item {
        var fill: Fill
        var quad: Shaders.Quad
    }

    /// Per-encode state.
    private final class Pass {
        let commandBuffer: any MTLCommandBuffer
        var retained: [AnyObject] = []
        init(_ cb: any MTLCommandBuffer) { commandBuffer = cb }
    }

    /// Where a pass draws: `toNDC` maps pass px → NDC, `pxPerUnit` = target px per pass px,
    /// `canvas` maps pass px → canvas px (for effect units and rotation).
    private struct Space {
        var toNDC: CGAffineTransform
        var pxPerUnit: Double
        var canvas: CGAffineTransform
        /// The pass target's size, px, and its clear colour (backdrops start from it).
        var size: (Int, Int)
        var clear: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    }

    func encode(_ plan: RenderPlan, frames: [FrameRequest: VideoFrame], into target: any MTLTexture,
                commandBuffer: any MTLCommandBuffer) throws {
        let pass = Pass(commandBuffer)
        let W = Double(target.width), H = Double(target.height)
        let cw = max(plan.canvasSize.width, 1), ch = max(plan.canvasSize.height, 1)
        let fit = min(W / cw, H / ch)
        // Canvas px (origin centre, +y up) → target NDC.
        let bg = plan.background
        // Letterbox and canvas share the background; premultiplied.
        let clear = MTLClearColor(red: bg.r * bg.a, green: bg.g * bg.a, blue: bg.b * bg.a, alpha: bg.a)
        let space = Space(toNDC: CGAffineTransform(scaleX: fit / (W / 2), y: fit / (H / 2)), pxPerUnit: fit,
                          canvas: .identity, size: (target.width, target.height), clear: clear)
        let items = try collect(plan.layers, parent: .identity, space: space, frames: frames, pass: pass)

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = clear
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { return }
        // Layers never draw outside the canvas.
        let sw = min(Int((cw * fit).rounded()), target.width), sh = min(Int((ch * fit).rounded()), target.height)
        enc.setScissorRect(MTLScissorRect(x: (target.width - sw) / 2, y: (target.height - sh) / 2,
                                          width: max(sw, 1), height: max(sh, 1)))
        try draw(items, encoder: enc, format: target.pixelFormat, size: (target.width, target.height))
        enc.endEncoding()

        if !pass.retained.isEmpty {
            let keep = GPURetainer(pass.retained)
            commandBuffer.addCompletedHandler { _ in _ = keep }
        }
    }

    private func draw(_ items: [Item], encoder enc: any MTLRenderCommandEncoder, format: MTLPixelFormat,
                      size: (Int, Int)) throws {
        enc.setFragmentSamplerState(sampler, index: 0)
        for var item in items {
            switch item.fill {
            case .texture(let tex):
                enc.setRenderPipelineState(try pipeline("texture_fs", format: format))
                enc.setFragmentTexture(tex, index: 0)
            case .gradient(let c):
                enc.setRenderPipelineState(try pipeline("gradient_fs", format: format))
                item.quad.c0 = c[0]; item.quad.c1 = c[1]; item.quad.c2 = c[2]; item.quad.c3 = c[3]
            case .shader(let url, let program, var bytes):
                enc.setRenderPipelineState(try pipeline("shader:\(url.path)", function: program.function,
                                                        format: format))
                enc.setFragmentBytes(&bytes, length: bytes.count * MemoryLayout<SIMD4<Float>>.stride, index: 1)
            case .pass(let fragment, let textures, let params):
                enc.setRenderPipelineState(try pipeline(fragment, format: format))
                for (i, t) in textures.enumerated() { enc.setFragmentTexture(t, index: i) }
                item.quad.c0 = params
                item.quad.c1 = SIMD4(Float(size.0), Float(size.1), 0, 0)
            }
            let size = MemoryLayout<Shaders.Quad>.stride
            enc.setVertexBytes(&item.quad, length: size, index: 0)
            enc.setFragmentBytes(&item.quad, length: size, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    /// Flattens `layers` into draw items for one pass. Groups that need isolation
    /// (crop or opacity < 1), layers with effects and transitions are rendered offscreen first.
    /// - `parent`: parent-local px → pass px.
    private func collect(_ layers: [Layer], parent: CGAffineTransform, space: Space,
                         frames: [FrameRequest: VideoFrame], pass: Pass) throws -> [Item] {
        var items: [Item] = []
        /// Items of the previous layer (the track directly below), for mattes.
        var below: Range<Int> = 0..<0
        for layer in layers {
            let start = items.count
            // Passes that rebuild the item list (backdrops) leave only their own last item as "the layer".
            defer { below = start <= items.count ? start..<items.count : max(items.count - 1, 0)..<items.count }
            let m = layer.transform.concatenating(parent)
            let toNDC = m.concatenating(space.toNDC)

            if let matte = layer.effects.first(where: { $0.name == MediaMatteSpec.name && !$0.bypassed }) {
                // The matte masks the track below and is not drawn itself [MediaMatte.md].
                guard !below.isEmpty else { continue }
                let content = Array(items[below])
                items.removeSubrange(below)
                var matteLayer = layer
                matteLayer.effects.removeAll { $0.name == MediaMatteSpec.name }
                matteLayer.opacity = 1
                let c = try backdropTexture(content, space: space, clear: false, pass: pass)
                let mt = try backdropTexture(try collect([matteLayer], parent: parent, space: space, frames: frames,
                                                         pass: pass), space: space, clear: false, pass: pass)
                let mode = MediaMatteSpec.mode(matte)
                items.append(Item(fill: .pass("matte_fs", [c, mt], SIMD4(mode.luminosity ? 1 : 0, mode.inverted ? 1 : 0,
                                                                         Float(MediaMatteSpec.intensity(matte)), 0)),
                                  quad: Self.fullPassQuad))
                continue
            }
            if let blend = layer.effects.first(where: { $0.name == BlendModeSpec.name && !$0.bypassed }),
               BlendModeSpec.mode(blend) != .normal, BlendModeSpec.intensity(blend) > 0, layer.opacity > 0 {
                var plain = layer
                plain.effects.removeAll { $0.name == BlendModeSpec.name }
                if let r = try effectLayer(plain, EffectRegistry.active(plain.effects), m: m, space: space,
                                           frames: frames, pass: pass) {
                    let b = try backdropTexture(items, space: space, clear: true, pass: pass)
                    items = [Item(fill: .texture(b), quad: Self.fullPassQuad)]
                    items.append(Item(fill: .pass("blend_fs", [r.texture, b],
                                                  SIMD4(Float(BlendModeSpec.mode(blend).rawValue),
                                                        Float(BlendModeSpec.intensity(blend)), 0, 0)),
                                      quad: Self.rectQuad(r.rect, m: toNDC, opacity: layer.opacity)))
                }
                continue
            }

            let active = EffectRegistry.active(layer.effects)
            if !active.isEmpty {
                if case .transition = layer.content {} else {
                    if let r = try effectLayer(layer, active, m: m, space: space, frames: frames, pass: pass) {
                        items.append(Item(fill: .texture(r.texture),
                                          quad: Self.rectQuad(r.rect, m: toNDC, opacity: layer.opacity)))
                    }
                    continue
                }
            }
            switch layer.content {
            case .group(let children):
                if layer.geometryCrop == .zero && layer.sourceCrop == .zero && layer.opacity >= 1 {
                    items += try collect(children, parent: m, space: space, frames: frames, pass: pass)
                } else if let tex = try offscreen(children, size: layer.size, layerToCanvas: m.concatenating(space.canvas),
                                                  scale: space.pxPerUnit * Self.scale(of: m), frames: frames,
                                                  pass: pass) {
                    if let q = quad(layer, m: toNDC) { items.append(Item(fill: .texture(tex), quad: q)) }
                }
            case .video(let req):
                guard let frame = frames[req], let tex = texture(for: frame.pixelBuffer, pass: pass),
                      let q = quad(layer, m: toNDC) else { continue }
                items.append(Item(fill: .texture(tex), quad: q))
                if let c = layer.cursor, let item = cursorItem(c, layer: layer, m: toNDC) { items.append(item) }
            case .image(let url):
                guard let tex = image(url), let q = quad(layer, m: toNDC) else { continue }
                items.append(Item(fill: .texture(tex), quad: q))
            case .shader(let url, let params, let time):
                guard let q = quad(layer, m: toNDC) else { continue }
                if let program = shaders.program(url) {
                    let k = space.pxPerUnit * Self.scale(of: m)
                    let image = SIMD2(Float(layer.size.width * k), Float(layer.size.height * k))
                    let bytes = ShaderBackgrounds.uniformBytes(program, parameters: params, time: time, imageSize: image)
                    items.append(Item(fill: .shader(url, program, bytes), quad: q))
                } else {
                    items.append(Item(fill: .gradient(Self.gradientColors(params)), quad: q))
                }
            case .transition(let t, let from, let to):
                let k = space.pxPerUnit * Self.scale(of: m)
                let toCanvas = m.concatenating(space.canvas)
                let a = try from.flatMap { try offscreen([$0], size: layer.size, layerToCanvas: toCanvas, scale: k,
                                                         frames: frames, pass: pass) }
                let b = try to.flatMap { try offscreen([$0], size: layer.size, layerToCanvas: toCanvas, scale: k,
                                                       frames: frames, pass: pass) }
                guard let ref = a ?? b else { continue }
                let out = try TransitionRegistry.renderer(t.name).encode(t, from: a, to: b, size: (ref.width, ref.height),
                                                                         gpu: fx, commandBuffer: pass.commandBuffer)
                let rect = CGRect(x: -layer.size.width / 2, y: -layer.size.height / 2,
                                  width: layer.size.width, height: layer.size.height)
                items.append(Item(fill: .texture(out), quad: Self.rectQuad(rect, m: toNDC, opacity: layer.opacity)))
            case .callout(let c) where !Self.drawsItself(c):
                guard layer.opacity > 0 else { continue }
                items = try regionCallout(c, layer: layer, m: m, items: items, space: space, pass: pass)
            case .callout(let c):
                guard layer.opacity > 0,
                      let r = callouts.texture(c, scale: space.pxPerUnit * Self.scale(of: m), device: device) else { continue }
                items.append(Item(fill: .texture(r.texture), quad: Self.rectQuad(r.rect, m: toNDC, opacity: layer.opacity)))
            case .unsupported:
                continue
            }
        }
        return items
    }

    /// Covers the whole pass target (NDC −1…1), texture right side up.
    private static let fullPassQuad = Shaders.Quad(
        m: matrix(.identity), rect: SIMD4(-1, -1, 1, 1), uv: SIMD4(0, 1, 1, 0), full: SIMD4(-1, -1, 1, 1), opacity: 1)

    /// Renders `items` into a pass-sized pooled texture: what the pass target holds so far. `clear`: start
    /// from the pass's clear colour (the background) instead of transparent.
    private func backdropTexture(_ items: [Item], space: Space, clear: Bool, pass: Pass) throws -> any MTLTexture {
        let t = try fx.pool.take(width: space.size.0, height: space.size.1, format: EffectGPU.format,
                                 commandBuffer: pass.commandBuffer)
        try render(items, into: t, clear: clear ? space.clear : MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0),
                   pass: pass)
        return t
    }

    /// Blur, pixelate or spotlight the pixels below a region callout's box. Returns the pass's new items.
    private func regionCallout(_ c: CalloutContent, layer: Layer, m: CGAffineTransform, items: [Item], space: Space,
                               pass: Pass) throws -> [Item] {
        let toNDC = m.concatenating(space.toNDC)
        let k = space.pxPerUnit * Self.scale(of: m)   // target px per callout px
        let b = try backdropTexture(items, space: space, clear: true, pass: pass)
        let box = Self.rectQuad(CalloutGeometry.box(c), m: toNDC, opacity: layer.opacity)
        var out = [Item(fill: .texture(b), quad: Self.fullPassQuad)]
        let intensity = Float(Conventions.clamp01(c.intensity))
        switch c.kind {
        case "TypeWinBlur":
            let ctx = EffectContext(gpu: fx, commandBuffer: pass.commandBuffer,
                                    contentRect: SIMD4(0, 0, Float(b.width), Float(b.height)), scale: 1, layerScale: 1,
                                    rotation: 0, layerSize: .zero, layerOrigin: .zero)
            let blurred = try GaussianBlur.run(b, sigma: Double(intensity) * RegionCalloutSpec.blurSigmaAtFull * k,
                                               alphaOnly: false, ctx: ctx)
            if c.invert {
                // Blur everything except the box [inf from `blur-invert`].
                out = [Item(fill: .texture(blurred), quad: Self.fullPassQuad),
                       Item(fill: .pass("screen_fs", [b], .zero), quad: box)]
            } else {
                out.append(Item(fill: .pass("screen_fs", [blurred], .zero), quad: box))
            }
        case "TypeWinPixelate":
            let block = max(Float(Double(intensity) * RegionCalloutSpec.pixelBlockAtFull * k), 1)
            out.append(Item(fill: .pass("pixelate_fs", [b], SIMD4(block, 0, 0, 0)), quad: box))
        case "TypeWinSpotlight":
            var mask = box
            mask.opacity = 1
            let white = [SIMD4<Float>](repeating: SIMD4(1, 1, 1, 1), count: 4)
            let mt = try backdropTexture([Item(fill: .gradient(white), quad: mask)], space: space, clear: false, pass: pass)
            out = [Item(fill: .pass("spotlight_fs", [b, mt], SIMD4(intensity * Float(layer.opacity), 0, 0, 0)),
                        quad: Self.fullPassQuad)]
        default:
            break
        }
        return out
    }

    /// Renders `children` (in a `size` space, origin at its centre) into a pooled transparent
    /// texture at `scale` texture px per unit.
    private func offscreen(_ children: [Layer], size: CGSize, layerToCanvas: CGAffineTransform, scale: Double,
                           frames: [FrameRequest: VideoFrame], pass: Pass) throws -> (any MTLTexture)? {
        let gw = size.width, gh = size.height
        guard gw > 0, gh > 0 else { return nil }
        let (pw, ph) = Self.textureSize(gw, gh, scale: scale)
        let tex = try fx.pool.take(width: pw, height: ph, format: EffectGPU.format, commandBuffer: pass.commandBuffer)
        let space = Space(toNDC: CGAffineTransform(scaleX: 2 / gw, y: 2 / gh), pxPerUnit: Double(pw) / gw,
                          canvas: layerToCanvas, size: (pw, ph))
        let items = try collect(children, parent: .identity, space: space, frames: frames, pass: pass)
        try render(items, into: tex, pass: pass)
        return tex
    }

    private func render(_ items: [Item], into tex: any MTLTexture,
                        clear: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0), pass: Pass) throws {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = tex
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = clear
        guard let enc = pass.commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { return }
        try draw(items, encoder: enc, format: tex.pixelFormat, size: (tex.width, tex.height))
        enc.endEncoding()
    }

    /// Texture px for a `w`×`h` unit rect at `scale`, capped at 8192 per side.
    private static func textureSize(_ w: Double, _ h: Double, scale: Double) -> (Int, Int) {
        let limit = 8192.0
        let s = min(max(scale, 1e-3), limit / w, limit / h)
        return (max(Int((w * s).rounded(.up)), 1), max(Int((h * s).rounded(.up)), 1))
    }

    /// Renders `layer` alone in its local space (visible rect + effect margins), runs `effects`,
    /// and returns the texture with the local rect it covers.
    private func effectLayer(_ layer: Layer, _ effects: [(EffectInstance, any EffectRenderer)], m: CGAffineTransform,
                             space: Space, frames: [FrameRequest: VideoFrame], pass: Pass)
        throws -> (texture: any MTLTexture, rect: CGRect)? {
        guard layer.opacity > 0,
              let region = Conventions.visibleRegion(size: layer.size, sourceCrop: layer.sourceCrop,
                                                     geometryCrop: layer.geometryCrop) else { return nil }
        let toCanvas = m.concatenating(space.canvas)
        let layerScale = Self.scale(of: toCanvas)
        let rotation = atan2(toCanvas.b, toCanvas.a)
        var content = region.rect
        if case .callout(let c) = layer.content { content = CalloutGeometry.bounds(c) }
        let mctx = MarginContext(layerScale: layerScale, rotation: rotation, contentSize: content.size)
        let margin = effects.reduce(Margin.zero) { $0 + $1.1.margin($1.0, ctx: mctx) }
        let r = CGRect(x: content.minX - margin.left, y: content.minY - margin.bottom,
                       width: content.width + margin.left + margin.right,
                       height: content.height + margin.top + margin.bottom)
        let (pw, ph) = Self.textureSize(r.width, r.height, scale: space.pxPerUnit * Self.scale(of: m))
        let sx = Double(pw) / r.width, sy = Double(ph) / r.height
        let base = try fx.pool.take(width: pw, height: ph, format: EffectGPU.format, commandBuffer: pass.commandBuffer)
        var inner = layer
        inner.transform = .identity; inner.opacity = 1; inner.effects = []
        let localSpace = Space(toNDC: CGAffineTransform(scaleX: 2 / r.width, y: 2 / r.height), pxPerUnit: sx,
                               canvas: CGAffineTransform(translationX: r.midX, y: r.midY).concatenating(toCanvas),
                               size: (pw, ph))
        let items = try collect([inner], parent: CGAffineTransform(translationX: -r.midX, y: -r.midY),
                                space: localSpace, frames: frames, pass: pass)
        try render(items, into: base, pass: pass)

        var ctx = EffectContext(
            gpu: fx, commandBuffer: pass.commandBuffer,
            contentRect: SIMD4(Float((content.minX - r.minX) * sx), Float((r.maxY - content.maxY) * sy),
                               Float((content.maxX - r.minX) * sx), Float((r.maxY - content.minY) * sy)),
            scale: (sx * sy).squareRoot(), layerScale: layerScale, rotation: rotation, layerSize: layer.size,
            layerOrigin: CGPoint(x: -r.minX * sx, y: r.maxY * sy))
        var tex: any MTLTexture = base
        for (e, renderer) in effects { tex = try renderer.encode(e, input: tex, ctx: &ctx) }
        return (tex, r)
    }

    /// Region callouts (blur, pixelate, spotlight) work on the pixels below and are drawn by the
    /// backdrop pass; the rest rasterise themselves. Crops do not apply to callouts [?].
    static func drawsItself(_ c: CalloutContent) -> Bool {
        !["TypeWinBlur", "TypeWinPixelate", "TypeWinSpotlight"].contains(c.kind)
    }

    // MARK: Geometry

    private func quad(_ layer: Layer, m: CGAffineTransform) -> Shaders.Quad? {
        guard let region = Conventions.visibleRegion(size: layer.size, sourceCrop: layer.sourceCrop,
                                                     geometryCrop: layer.geometryCrop),
              layer.opacity > 0 else { return nil }
        let r = region.rect, w = layer.size.width, h = layer.size.height
        return Shaders.Quad(
            m: Self.matrix(m),
            rect: SIMD4(Float(r.minX), Float(r.minY), Float(r.maxX), Float(r.maxY)),
            uv: SIMD4(Float(region.uv.u0), Float(region.uv.vBottom), Float(region.uv.u1), Float(region.uv.vTop)),
            full: SIMD4(Float(-w / 2), Float(-h / 2), Float(w / 2), Float(h / 2)),
            opacity: Float(layer.opacity))
    }

    /// The cursor image over `layer`, in its local space, clipped to the layer's visible rect.
    private func cursorItem(_ c: CursorOverlay, layer: Layer, m: CGAffineTransform) -> Item? {
        guard c.opacity > 0, c.sourceSize.width > 0, c.sourceSize.height > 0, let tex = image(c.image),
              let region = Conventions.visibleRegion(size: layer.size, sourceCrop: layer.sourceCrop,
                                                     geometryCrop: layer.geometryCrop) else { return nil }
        let kx = layer.size.width / c.sourceSize.width, ky = layer.size.height / c.sourceSize.height
        let left = c.position.x - c.hotspot.x * c.scale, top = c.position.y - c.hotspot.y * c.scale
        let w = c.imageSize.width * c.scale, h = c.imageSize.height * c.scale
        // Source px (top-left, y down) → layer local px (centre, y up).
        let full = CGRect(x: left * kx - layer.size.width / 2, y: layer.size.height / 2 - (top + h) * ky,
                          width: w * kx, height: h * ky)
        let r = full.intersection(region.rect)
        guard !r.isNull, r.width > 0, r.height > 0, full.width > 0, full.height > 0 else { return nil }
        let u0 = (r.minX - full.minX) / full.width, u1 = (r.maxX - full.minX) / full.width
        let vTop = (full.maxY - r.maxY) / full.height, vBottom = (full.maxY - r.minY) / full.height
        let q = Shaders.Quad(m: Self.matrix(m), rect: SIMD4(Float(r.minX), Float(r.minY), Float(r.maxX), Float(r.maxY)),
                             uv: SIMD4(Float(u0), Float(vBottom), Float(u1), Float(vTop)),
                             full: SIMD4(Float(full.minX), Float(full.minY), Float(full.maxX), Float(full.maxY)),
                             opacity: Float(Conventions.clamp01(c.opacity * layer.opacity)))
        return Item(fill: .texture(tex), quad: q)
    }

    /// A quad showing a whole texture over local `rect`.
    private static func rectQuad(_ r: CGRect, m: CGAffineTransform, opacity: Double) -> Shaders.Quad {
        Shaders.Quad(m: matrix(m), rect: SIMD4(Float(r.minX), Float(r.minY), Float(r.maxX), Float(r.maxY)),
                     uv: SIMD4(0, 1, 1, 0), full: SIMD4(Float(r.minX), Float(r.minY), Float(r.maxX), Float(r.maxY)),
                     opacity: Float(Conventions.clamp01(opacity)))
    }

    private static func matrix(_ m: CGAffineTransform) -> simd_float3x3 {
        simd_float3x3(columns: (SIMD3(Float(m.a), Float(m.b), 0), SIMD3(Float(m.c), Float(m.d), 0),
                                SIMD3(Float(m.tx), Float(m.ty), 1)))
    }

    /// Linear scale factor of an affine map (geometric mean of the axis scales).
    static func scale(of m: CGAffineTransform) -> Double {
        let det = abs(m.a * m.d - m.b * m.c)
        return det > 0 ? det.squareRoot() : 1
    }

    /// Shader fallback (unreadable or untranslatable file): corners from `Color0..3`
    /// (top-left, top-right, bottom-left, bottom-right), matching where the demo shader puts them
    /// [shader-backgrounds.md §2: `_TexCoord` (0, 0) = top-left].
    static func gradientColors(_ p: [String: Double]) -> [SIMD4<Float>] {
        (0..<4).map { i in
            func c(_ k: String, _ d: Double) -> Float { Float(Conventions.clamp01(p["Color\(i)-\(k)"] ?? d)) }
            return SIMD4(c("red", 0.5), c("green", 0.5), c("blue", 0.5), c("alpha", 1))
        }
    }

    // MARK: Textures

    private func texture(for pb: CVPixelBuffer, pass: Pass) -> (any MTLTexture)? {
        guard let cache = textureCache else { return nil }
        var cvTex: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex)
        guard status == kCVReturnSuccess, let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return nil }
        pass.retained.append(cvTex)
        return tex
    }

    /// Loads (once) a still image as a premultiplied BGRA texture.
    private func image(_ url: URL) -> (any MTLTexture)? {
        if let t = images[url] { return t }
        if failedImages.contains(url) { return nil }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let tex = Self.makeTexture(img, device: device) else {
            failedImages.insert(url)
            return nil
        }
        images[url] = tex
        return tex
    }

    static func makeTexture(_ img: CGImage, device: any MTLDevice) -> (any MTLTexture)? {
        let w = img.width, h = img.height
        guard w > 0, h > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: cs, bitmapInfo: info) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
        return tex
    }
}
