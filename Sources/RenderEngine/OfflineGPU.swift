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
    /// Wraps caller-owned pixel buffers as render targets (zero-copy, straight from their
    /// IOSurfaces); wrappers may be released on Metal's completion queue.
    private let targetCache: LockedTextureCache?
    /// BT.709 4:2:0 conversion, built on first use.
    private var yuv: YUVOutput?
    /// Intermediate BGRA canvases for 4:2:0 output.
    private let rgbPool: TexturePool

    init() throws {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else {
            throw RenderError.noMetalDevice
        }
        device = d; queue = q
        compositor = try Compositor(device: d)
        rgbPool = TexturePool(device: d)
        targetCache = LockedTextureCache(device: d)
    }

    /// Encodes `plan` into `pixelBuffer`, commits, and calls `done` from the GPU completion
    /// handler (nil = success). Returns before the GPU finishes. The buffer must be IOSurface-backed
    /// and either 32BGRA (drawn straight into, zero-copy) or BT.709 4:2:0 bi-planar `420v`/`420f`
    /// (composited into a pooled BGRA texture, then converted by `YUVOutput`).
    func submit(_ plan: RenderPlan, frames: [FrameRequest: VideoFrame], into pixelBuffer: CVPixelBuffer,
                done: @escaping @Sendable ((any Error)?) -> Void) throws {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_32BGRA || YUVOutput.formats.contains(format),
              CVPixelBufferGetIOSurface(pixelBuffer) != nil, let cache = targetCache else {
            throw RenderError.notImplemented
        }
        func wrap(_ plane: Int, _ f: MTLPixelFormat) throws -> (CacheTexture, any MTLTexture) {
            let planar = CVPixelBufferIsPlanar(pixelBuffer)
            let w = planar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, plane) : CVPixelBufferGetWidth(pixelBuffer)
            let h = planar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, plane) : CVPixelBufferGetHeight(pixelBuffer)
            guard let cv = cache.texture(pixelBuffer, format: f, width: w, height: h, plane: plane) else {
                throw RenderError.noMetalDevice
            }
            return (cv, cv.texture)
        }
        guard let cb = queue.makeCommandBuffer() else { throw RenderError.noMetalDevice }
        var keep: [AnyObject] = [pixelBuffer]
        if format == kCVPixelFormatType_32BGRA {
            let (cv, target) = try wrap(0, .bgra8Unorm)
            keep.append(cv)
            try compositor.encode(plan, frames: frames, into: target, commandBuffer: cb)
        } else {
            if yuv == nil { yuv = try YUVOutput(device: device) }
            guard let yuv else { throw RenderError.noMetalDevice }
            let (cvY, luma) = try wrap(0, .r8Unorm)
            let (cvC, chroma) = try wrap(1, .rg8Unorm)
            keep += [cvY, cvC]
            let rgb = try rgbPool.take(width: luma.width, height: luma.height, format: .bgra8Unorm, commandBuffer: cb)
            try compositor.encode(plan, frames: frames, into: rgb, commandBuffer: cb)
            try yuv.encode(from: rgb, luma: luma, chroma: chroma,
                           fullRange: format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, commandBuffer: cb)
        }
        let retained = GPURetainer(keep)
        cb.addCompletedHandler { finished in
            withExtendedLifetime(retained) { done(finished.error) }
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
