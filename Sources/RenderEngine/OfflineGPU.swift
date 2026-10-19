import CoreGraphics
import CoreVideo
import Foundation
import MediaEngine
import Metal

/// GPU state for `OfflineRenderer`: device, queue and compositor. Owned by the actor.
final class OfflineGPU {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let compositor: Compositor
    /// Wraps caller-owned pixel buffers as render targets (zero-copy).
    private var targetCache: CVMetalTextureCache?

    init() throws {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else {
            throw RenderError.noMetalDevice
        }
        device = d; queue = q
        compositor = try Compositor(device: d)
        CVMetalTextureCacheCreate(nil, nil, d, nil, &targetCache)
    }

    /// Encodes `plan` straight into `pixelBuffer` (32BGRA, IOSurface-backed), commits, and calls
    /// `done` from the GPU completion handler (nil = success). Returns before the GPU finishes.
    func submit(_ plan: RenderPlan, frames: [FrameRequest: VideoFrame], into pixelBuffer: CVPixelBuffer,
                done: @escaping @Sendable ((any Error)?) -> Void) throws {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetIOSurface(pixelBuffer) != nil, let cache = targetCache else {
            throw RenderError.notImplemented
        }
        CVMetalTextureCacheFlush(cache, 0)  // drop wrappers of buffers already released
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .bgra8Unorm, w, h, 0, &cvTexture)
        guard let cvTexture, let target = CVMetalTextureGetTexture(cvTexture),
              let cb = queue.makeCommandBuffer() else { throw RenderError.noMetalDevice }
        try compositor.encode(plan, frames: frames, into: target, commandBuffer: cb)
        let keep = GPURetainer([cvTexture, pixelBuffer])
        cb.addCompletedHandler { finished in
            withExtendedLifetime(keep) { done(finished.error) }
        }
        cb.commit()
    }

    /// Fetches every distinct request concurrently. Missing or unsupported files are left out.
    static func fetch(_ requests: [FrameRequest],
                      using frame: @escaping @Sendable (FrameRequest) async throws -> VideoFrame)
        async throws -> [FrameRequest: VideoFrame] {
        let unique = Array(Set(requests))
        return try await withThrowingTaskGroup(of: (FrameRequest, VideoFrame?).self) { group in
            for r in unique {
                group.addTask {
                    do { return (r, try await frame(r)) } catch let e as MediaError {
                        switch e {
                        case .fileNotFound, .unsupported: return (r, nil)
                        default: throw e
                        }
                    }
                }
            }
            var out: [FrameRequest: VideoFrame] = [:]
            for try await (r, f) in group { if let f { out[r] = f } }
            return out
        }
    }

    /// Composites `plan` into a `width`×`height` texture and returns it as an 8-bit sRGB image.
    /// Blocks the caller until the GPU finishes (a few ms at 1080p).
    func render(_ plan: RenderPlan, frames: [FrameRequest: VideoFrame], width: Int, height: Int)
        throws -> CGImage {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                         mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d), let cb = queue.makeCommandBuffer() else {
            throw RenderError.noMetalDevice
        }
        try compositor.encode(plan, frames: frames, into: target, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw error }
        let rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        target.getBytes(&bytes, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: rowBytes, space: cs,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                           | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw RenderError.noMetalDevice }
        return image
    }
}
