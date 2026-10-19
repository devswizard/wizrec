import Foundation
import MetalKit
import QuartzCore
import RenderEngine

/// Draws a `PlaybackEngine`'s current state into an `MTKView` with the RenderEngine
/// `Compositor`. The view is paused and drawn on demand (`view.draw()`) from the
/// player's display link.
@MainActor
public final class CanvasRenderer: NSObject, MTKViewDelegate {
    public let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let compositor: Compositor?
    /// Why the compositor is unavailable (the canvas then shows only the background).
    public private(set) var compositorError: String?
    public weak var engine: PlaybackEngine?

    /// Configures `view` (pixel format, colour space, on-demand drawing). Nil without Metal.
    public init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            compositor = try Compositor(device: device)
        } catch {
            compositor = nil
            compositorError = "\(error)"
        }
        super.init()
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = self
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        engine?.setNeedsDraw()
    }

    public func draw(in view: MTKView) {
        guard let engine, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        let t0 = CACurrentMediaTime()
        let state = engine.drawState()
        do {
            guard let compositor else { throw RenderError.notImplemented }
            try compositor.encode(state.plan, frames: state.frames, into: drawable.texture, commandBuffer: cb)
        } catch {
            if compositorError == nil { compositorError = "\(error)" }
            clear(drawable.texture, to: state.plan.background, cb)
        }
        cb.addCompletedHandler { [weak engine] buffer in
            let ms = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            Task { @MainActor in engine?.recordGPU(ms: ms) }
        }
        cb.present(drawable)
        cb.commit()
        engine.recordDraw(frame: state.frame, cpuMs: (CACurrentMediaTime() - t0) * 1000, stale: state.stale > 0)
    }

    /// Renders the engine's current state offscreen at `size` px (sRGB, 8-bit), synchronously.
    /// For snapshots and diagnostics; nil when the compositor is unavailable.
    public func renderImage(size: CGSize) -> CGImage? {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard let engine, let compositor, w > 0, h > 0 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d), let cb = queue.makeCommandBuffer() else { return nil }
        let state = engine.drawState()
        do { try compositor.encode(state.plan, frames: state.frames, into: tex, commandBuffer: cb) } catch { return nil }
        cb.commit()
        cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                       bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Fallback when the compositor cannot draw: fill with the canvas background.
    private func clear(_ texture: any MTLTexture, to c: RGBA, _ cb: any MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: c.r * c.a, green: c.g * c.a, blue: c.b * c.a, alpha: 1)
        cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }
}
