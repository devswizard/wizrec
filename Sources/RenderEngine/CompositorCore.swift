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
final class CompositorCore {
    let device: any MTLDevice
    private let library: any MTLLibrary
    private var pipelines: [MTLPixelFormat: (texture: any MTLRenderPipelineState,
                                             gradient: any MTLRenderPipelineState)] = [:]
    private let sampler: any MTLSamplerState
    private var textureCache: CVMetalTextureCache?
    private var images: [URL: any MTLTexture] = [:]
    private var failedImages: Set<URL> = []

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
        _ = try pipeline(for: .bgra8Unorm)
    }

    // MARK: Pipelines

    private func pipeline(for format: MTLPixelFormat) throws
        -> (texture: any MTLRenderPipelineState, gradient: any MTLRenderPipelineState) {
        if let p = pipelines[format] { return p }
        func make(_ fragment: String) throws -> any MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "quad_vs")
            d.fragmentFunction = library.makeFunction(name: fragment)
            let a = d.colorAttachments[0]!
            a.pixelFormat = format
            // Premultiplied source-over.
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            do { return try device.makeRenderPipelineState(descriptor: d) } catch {
                throw RenderError.shaderCompile(String(describing: error))
            }
        }
        let p = (texture: try make("texture_fs"), gradient: try make("gradient_fs"))
        pipelines[format] = p
        return p
    }

    // MARK: Encode

    private enum Fill {
        case texture(any MTLTexture)
        case gradient([SIMD4<Float>])
    }

    private struct Item {
        var fill: Fill
        var quad: Shaders.Quad
    }

    /// Per-encode state: CoreVideo textures to keep alive.
    private final class Pass {
        var retained: [AnyObject] = []
    }

    func encode(_ plan: RenderPlan, frames: [FrameRequest: VideoFrame], into target: any MTLTexture,
                commandBuffer: any MTLCommandBuffer) throws {
        let pass = Pass()
        let W = Double(target.width), H = Double(target.height)
        let cw = max(plan.canvasSize.width, 1), ch = max(plan.canvasSize.height, 1)
        let fit = min(W / cw, H / ch)
        // Canvas px (origin centre, +y up) → target NDC.
        let toNDC = CGAffineTransform(scaleX: fit / (W / 2), y: fit / (H / 2))
        let items = try collect(plan.layers, parent: .identity, toNDC: toNDC, pxPerUnit: fit,
                                frames: frames, format: target.pixelFormat, commandBuffer: commandBuffer, pass: pass)

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        let bg = plan.background
        // Letterbox and canvas share the background; premultiplied.
        rp.colorAttachments[0].clearColor = MTLClearColor(red: bg.r * bg.a, green: bg.g * bg.a,
                                                          blue: bg.b * bg.a, alpha: bg.a)
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { return }
        // Layers never draw outside the canvas.
        let sw = min(Int((cw * fit).rounded()), target.width), sh = min(Int((ch * fit).rounded()), target.height)
        enc.setScissorRect(MTLScissorRect(x: (target.width - sw) / 2, y: (target.height - sh) / 2,
                                          width: max(sw, 1), height: max(sh, 1)))
        try draw(items, encoder: enc, format: target.pixelFormat)
        enc.endEncoding()

        if !pass.retained.isEmpty {
            let keep = GPURetainer(pass.retained)
            commandBuffer.addCompletedHandler { _ in _ = keep }
        }
    }

    private func draw(_ items: [Item], encoder enc: any MTLRenderCommandEncoder, format: MTLPixelFormat) throws {
        let p = try pipeline(for: format)
        enc.setFragmentSamplerState(sampler, index: 0)
        for var item in items {
            switch item.fill {
            case .texture(let tex):
                enc.setRenderPipelineState(p.texture)
                enc.setFragmentTexture(tex, index: 0)
            case .gradient(let c):
                enc.setRenderPipelineState(p.gradient)
                item.quad.c0 = c[0]; item.quad.c1 = c[1]; item.quad.c2 = c[2]; item.quad.c3 = c[3]
            }
            let size = MemoryLayout<Shaders.Quad>.stride
            enc.setVertexBytes(&item.quad, length: size, index: 0)
            enc.setFragmentBytes(&item.quad, length: size, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    /// Flattens `layers` into draw items for one pass. Groups that need isolation
    /// (crop or opacity < 1) are rendered to their own texture first.
    /// - `parent`: parent-local px → pass space px (canvas or offscreen group).
    /// - `toNDC`: pass space px → NDC. `pxPerUnit`: target pixels per pass-space px.
    private func collect(_ layers: [Layer], parent: CGAffineTransform, toNDC: CGAffineTransform, pxPerUnit: Double,
                         frames: [FrameRequest: VideoFrame], format: MTLPixelFormat,
                         commandBuffer: any MTLCommandBuffer, pass: Pass) throws -> [Item] {
        var items: [Item] = []
        for layer in layers {
            let m = layer.transform.concatenating(parent)
            switch layer.content {
            case .group(let children):
                if layer.geometryCrop == .zero && layer.sourceCrop == .zero && layer.opacity >= 1 {
                    items += try collect(children, parent: m, toNDC: toNDC, pxPerUnit: pxPerUnit, frames: frames,
                                         format: format, commandBuffer: commandBuffer, pass: pass)
                } else if let tex = try offscreen(layer, children: children, scale: pxPerUnit * Self.scale(of: m),
                                                  frames: frames, format: format,
                                                  commandBuffer: commandBuffer, pass: pass) {
                    if let q = quad(layer, m: m.concatenating(toNDC)) { items.append(Item(fill: .texture(tex), quad: q)) }
                }
            case .video(let req):
                guard let frame = frames[req], let tex = texture(for: frame.pixelBuffer, pass: pass),
                      let q = quad(layer, m: m.concatenating(toNDC)) else { continue }
                items.append(Item(fill: .texture(tex), quad: q))
            case .image(let url):
                guard let tex = image(url), let q = quad(layer, m: m.concatenating(toNDC)) else { continue }
                items.append(Item(fill: .texture(tex), quad: q))
            case .shader(_, let params):
                guard let q = quad(layer, m: m.concatenating(toNDC)) else { continue }
                items.append(Item(fill: .gradient(Self.gradientColors(params)), quad: q))
            case .unsupported:
                continue
            }
        }
        return items
    }

    /// Renders a group's children into a transparent texture of the group's size × `scale`.
    private func offscreen(_ group: Layer, children: [Layer], scale: Double, frames: [FrameRequest: VideoFrame],
                           format: MTLPixelFormat, commandBuffer: any MTLCommandBuffer,
                           pass: Pass) throws -> (any MTLTexture)? {
        let gw = group.size.width, gh = group.size.height
        guard gw > 0, gh > 0 else { return nil }
        let limit = 8192.0
        let s = min(max(scale, 1e-3), limit / gw, limit / gh)
        let pw = max(Int((gw * s).rounded(.up)), 1), ph = max(Int((gh * s).rounded(.up)), 1)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: pw, height: ph, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        let toNDC = CGAffineTransform(scaleX: 2 / gw, y: 2 / gh)
        let items = try collect(children, parent: .identity, toNDC: toNDC, pxPerUnit: Double(pw) / gw,
                                frames: frames, format: format, commandBuffer: commandBuffer, pass: pass)
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = tex
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { return nil }
        try draw(items, encoder: enc, format: format)
        enc.endEncoding()
        return tex
    }

    // MARK: Geometry

    private func quad(_ layer: Layer, m: CGAffineTransform) -> Shaders.Quad? {
        guard let region = Conventions.visibleRegion(size: layer.size, sourceCrop: layer.sourceCrop,
                                                     geometryCrop: layer.geometryCrop),
              layer.opacity > 0 else { return nil }
        let r = region.rect, w = layer.size.width, h = layer.size.height
        let mat = simd_float3x3(columns: (SIMD3(Float(m.a), Float(m.b), 0),
                                          SIMD3(Float(m.c), Float(m.d), 0),
                                          SIMD3(Float(m.tx), Float(m.ty), 1)))
        return Shaders.Quad(
            m: mat,
            rect: SIMD4(Float(r.minX), Float(r.minY), Float(r.maxX), Float(r.maxY)),
            uv: SIMD4(Float(region.uv.u0), Float(region.uv.vBottom), Float(region.uv.u1), Float(region.uv.vTop)),
            full: SIMD4(Float(-w / 2), Float(-h / 2), Float(w / 2), Float(h / 2)),
            opacity: Float(layer.opacity))
    }

    /// Linear scale factor of an affine map (geometric mean of the axis scales).
    static func scale(of m: CGAffineTransform) -> Double {
        let det = abs(m.a * m.d - m.b * m.c)
        return det > 0 ? det.squareRoot() : 1
    }

    /// M1 shader fallback: corners from `Color0..3` (top-left, top-right, bottom-left, bottom-right) [inf].
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
