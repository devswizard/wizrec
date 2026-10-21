// MED14-1: `LockedTextureCache` makes textures straight from the buffer's IOSurface. These tests
// pin what the `CVMetalTextureCache` it replaced guaranteed: the same texels for every plane
// format in use (read and written), the buffer kept out of its pool while wrapped, and a clean
// refusal (never a crash) for buffers without an IOSurface.

import CFFmpeg
import CoreVideo
import Foundation
import IOSurface
import Metal
import Testing
import WizRecTestSupport
@testable import MediaEngine

/// A pixel buffer format and the Metal formats its planes are wrapped as somewhere in the code.
struct WrapCase: Sendable, CustomStringConvertible {
    let format: OSType, name: String, planes: [[MTLPixelFormat]]
    var description: String { name }
}

private let device = MTLCreateSystemDefaultDevice()

@Suite(.enabled(if: device != nil, "no Metal device"))
struct TextureCacheTests {
    static let cases: [WrapCase] = [
        // RenderEngine frames and render targets, MediaEngine tone-map output.
        WrapCase(format: kCVPixelFormatType_32BGRA, name: "BGRA", planes: [[.bgra8Unorm, .rgba8Uint]]),
        // RenderEngine 4:2:0 output (Unorm), MediaEngine 8-bit HDR sources (Uint).
        WrapCase(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, name: "420v",
                 planes: [[.r8Unorm, .r8Uint], [.rg8Unorm, .rg8Uint]]),
        WrapCase(format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, name: "420f",
                 planes: [[.r8Unorm, .r8Uint], [.rg8Unorm, .rg8Uint]]),
        WrapCase(format: kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, name: "422v",
                 planes: [[.r8Uint], [.rg8Uint]]),
        WrapCase(format: kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, name: "444v",
                 planes: [[.r8Uint], [.rg8Uint]]),
        // MediaEngine 10-bit HDR sources (x420/xf20/x422/x444).
        WrapCase(format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, name: "x420",
                 planes: [[.r16Uint], [.rg16Uint]]),
        WrapCase(format: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, name: "xf20",
                 planes: [[.r16Uint], [.rg16Uint]]),
        WrapCase(format: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, name: "x422",
                 planes: [[.r16Uint], [.rg16Uint]]),
        WrapCase(format: kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, name: "x444",
                 planes: [[.r16Uint], [.rg16Uint]]),
    ]

    /// An IOSurface-backed `format` buffer of `w`×`h` px filled with fixed-seed noise.
    static func noise(_ format: OSType, _ w: Int, _ h: Int, seed: UInt64) throws -> CVPixelBuffer {
        var buf: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
                                      kCVPixelBufferMetalCompatibilityKey: true]
        let rc = CVPixelBufferCreate(nil, w, h, format, attrs as CFDictionary, &buf)
        guard rc == kCVReturnSuccess, let b = buf else { throw MediaError.decodeFailed("CVPixelBufferCreate \(rc)") }
        var state = seed
        CVPixelBufferLockBaseAddress(b, [])
        defer { CVPixelBufferUnlockBaseAddress(b, []) }
        for p in 0..<max(CVPixelBufferGetPlaneCount(b), 1) {
            let (base, rb, ph) = planeBytes(b, p)
            guard let base else { continue }
            for i in 0..<(rb * ph) {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                base.storeBytes(of: UInt8(truncatingIfNeeded: state >> 33), toByteOffset: i, as: UInt8.self)
            }
        }
        return b
    }

    /// Base address, bytes per row and height of `plane` (the whole buffer when not planar).
    static func planeBytes(_ b: CVPixelBuffer, _ plane: Int) -> (UnsafeMutableRawPointer?, Int, Int) {
        if CVPixelBufferIsPlanar(b) {
            return (CVPixelBufferGetBaseAddressOfPlane(b, plane), CVPixelBufferGetBytesPerRowOfPlane(b, plane),
                    CVPixelBufferGetHeightOfPlane(b, plane))
        }
        return (CVPixelBufferGetBaseAddress(b), CVPixelBufferGetBytesPerRow(b), CVPixelBufferGetHeight(b))
    }

    static func planeSize(_ b: CVPixelBuffer, _ plane: Int) -> (Int, Int) {
        CVPixelBufferIsPlanar(b)
            ? (CVPixelBufferGetWidthOfPlane(b, plane), CVPixelBufferGetHeightOfPlane(b, plane))
            : (CVPixelBufferGetWidth(b), CVPixelBufferGetHeight(b))
    }

    /// The texels of `tex` (`rowBytes` per row), copied out by the GPU.
    static func readBack(_ tex: any MTLTexture, rowBytes: Int, on dev: any MTLDevice) throws -> [UInt8] {
        let rowPitch = (rowBytes + 255) / 256 * 256
        guard let queue = dev.makeCommandQueue(), let cb = queue.makeCommandBuffer(),
              let out = dev.makeBuffer(length: rowPitch * tex.height, options: .storageModeShared),
              let blit = cb.makeBlitCommandEncoder() else { throw MediaError.decodeFailed("no GPU") }
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: tex.width, height: tex.height, depth: 1), to: out,
                  destinationOffset: 0, destinationBytesPerRow: rowPitch, destinationBytesPerImage: rowPitch * tex.height)
        blit.endEncoding()
        try GPUWait.commitAndWait(cb, "texture read-back")
        let raw = UnsafeRawBufferPointer(start: out.contents(), count: out.length)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(rowBytes * tex.height)
        for y in 0..<tex.height { bytes += raw[(y * rowPitch)..<(y * rowPitch + rowBytes)] }
        return bytes
    }

    /// The plane's bytes as the CPU sees them (`rowBytes` per row).
    static func cpuBytes(_ b: CVPixelBuffer, _ plane: Int, rowBytes: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let (base, rb, ph) = planeBytes(b, plane)
        guard let base else { return [] }
        var bytes: [UInt8] = []
        for y in 0..<ph { bytes += UnsafeRawBufferPointer(start: base + y * rb, count: rowBytes) }
        return bytes
    }

    /// Every plane, every Metal format used for it: the IOSurface texture reads the same texels as
    /// the CPU and as a `CVMetalTextureCache` texture of the same plane (the old path). Odd sizes
    /// exercise padded rows.
    @Test(arguments: cases)
    func readsTheSameTexelsAsTheOldPath(_ k: WrapCase) throws {
        let dev = try #require(device)
        let cache = try #require(LockedTextureCache(device: dev))
        var raw: CVMetalTextureCache?
        try #require(CVMetalTextureCacheCreate(nil, nil, dev, nil, &raw) == kCVReturnSuccess)
        let old = try #require(raw)
        for (w, h) in [(318, 181), (64, 36)] {
            let pb = try Self.noise(k.format, w, h, seed: UInt64(w))
            for (plane, formats) in k.planes.enumerated() {
                let (pw, ph) = Self.planeSize(pb, plane)
                for f in formats {
                    let bpp = try #require(LockedTextureCache.bytesPerPixel(f))
                    let new = try #require(cache.texture(pb, format: f, width: pw, height: ph, plane: plane),
                                           "\(k) plane \(plane) \(f.rawValue)")
                    var cv: CVMetalTexture?
                    let rc = CVMetalTextureCacheCreateTextureFromImage(nil, old, pb, nil, f, pw, ph, plane, &cv)
                    let oldTex = try #require(cv.flatMap { CVMetalTextureGetTexture($0) }, "old path \(rc)")
                    let cpu = Self.cpuBytes(pb, plane, rowBytes: pw * bpp)
                    let viaNew = try Self.readBack(new.texture, rowBytes: pw * bpp, on: dev)
                    let viaOld = try Self.readBack(oldTex, rowBytes: pw * bpp, on: dev)
                    #expect(viaNew == cpu, "\(k) \(w)x\(h) plane \(plane) format \(f.rawValue)")
                    #expect(viaNew == viaOld, "\(k) \(w)x\(h) plane \(plane) format \(f.rawValue)")
                }
            }
        }
    }

    /// GPU writes through the texture land in the buffer as the CPU sees it (render targets and
    /// tone-map output write through these textures).
    @Test(arguments: [(kCVPixelFormatType_32BGRA, 0, MTLPixelFormat.bgra8Unorm),
                      (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 1, .rg8Unorm),
                      (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 0, .r16Uint)])
    func gpuWritesReachTheBuffer(_ format: OSType, _ plane: Int, _ f: MTLPixelFormat) throws {
        let dev = try #require(device)
        let cache = try #require(LockedTextureCache(device: dev))
        let src = try Self.noise(format, 130, 70, seed: 3), dst = try Self.noise(format, 130, 70, seed: 4)
        let (pw, ph) = Self.planeSize(src, plane)
        let a = try #require(cache.texture(src, format: f, width: pw, height: ph, plane: plane))
        let b = try #require(cache.texture(dst, format: f, width: pw, height: ph, plane: plane))
        let queue = try #require(dev.makeCommandQueue())
        let cb = try #require(queue.makeCommandBuffer()), blit = try #require(cb.makeBlitCommandEncoder())
        blit.copy(from: a.texture, to: b.texture)
        blit.endEncoding()
        try GPUWait.commitAndWait(cb, "texture copy")
        let bpp = try #require(LockedTextureCache.bytesPerPixel(f))
        #expect(Self.cpuBytes(dst, plane, rowBytes: pw * bpp) == Self.cpuBytes(src, plane, rowBytes: pw * bpp))
    }

    /// A wrapped pool buffer stays out of its pool: a decoder drawing ahead from a small pool gets
    /// other surfaces, and the wrapped pixels are unchanged when the GPU reads them.
    @Test func wrappedPoolBufferIsNotRecycled() throws {
        let dev = try #require(device)
        let cache = try #require(LockedTextureCache(device: dev))
        let (w, h) = (96, 54)
        let pool = try BGRAPool(width: w, height: h)
        func fill(_ b: CVPixelBuffer, _ v: UInt8) {
            CVPixelBufferLockBaseAddress(b, [])
            if let base = CVPixelBufferGetBaseAddress(b) { memset(base, Int32(v), CVPixelBufferGetBytesPerRow(b) * h) }
            CVPixelBufferUnlockBaseAddress(b, [])
        }
        var held: CVPixelBuffer? = try pool.make()
        fill(try #require(held), 0x11)
        let heldID = try #require(held.flatMap { CVPixelBufferGetIOSurface($0) }).takeUnretainedValue()
        let wrapped = try #require(held.flatMap { cache.texture($0, format: .bgra8Unorm, width: w, height: h) })
        held = nil // only the wrapper keeps the frame now
        // Decode ahead: a pool that recycles its 2–3 most recent buffers.
        for i in 0..<12 {
            let ahead = try pool.make()
            let id = try #require(CVPixelBufferGetIOSurface(ahead)).takeUnretainedValue()
            #expect(IOSurfaceGetID(id) != IOSurfaceGetID(heldID), "frame \(i) reused the wrapped surface")
            fill(ahead, UInt8(0x20 + i))
        }
        let pixels = try Self.readBack(wrapped.texture, rowBytes: w * 4, on: dev)
        #expect(pixels.allSatisfy { $0 == 0x11 })
    }

    /// Buffers without an IOSurface (CPU-made) are refused with a status, never a crash; the tone
    /// mapper turns that into an error its caller falls back from.
    @Test func refusesBuffersWithoutAnIOSurface() throws {
        let dev = try #require(device)
        let cache = try #require(LockedTextureCache(device: dev))
        for format in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange] {
            var plain: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 32, format, nil, &plain)
            let pb = try #require(plain)
            #expect(CVPixelBufferGetIOSurface(pb) == nil)
            var rc: CVReturn = kCVReturnSuccess
            #expect(cache.texture(pb, format: .r16Uint, width: 64, height: 32, status: &rc) == nil)
            #expect(rc == kCVReturnPixelBufferNotMetalCompatible)
        }
        // Mismatched pixel size, missing plane, oversized view: refused too.
        let p010 = try Self.noise(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 64, 32, seed: 9)
        var rc: CVReturn = kCVReturnSuccess
        #expect(cache.texture(p010, format: .r8Uint, width: 64, height: 32, plane: 0, status: &rc) == nil)
        #expect(rc == kCVReturnInvalidPixelFormat)
        #expect(cache.texture(p010, format: .r16Uint, width: 64, height: 32, plane: 2, status: &rc) == nil)
        #expect(cache.texture(p010, format: .rg16Uint, width: 64, height: 32, plane: 1, status: &rc) == nil)
        #expect(rc == kCVReturnInvalidSize)

        let gpu = try #require(MetalToneMapper(ToneMapper(transfer: .pq, colorSpace: AVCOL_SPC_BT2020_NCL,
                                                          primaries: AVCOL_PRI_BT2020, fullRange: false)))
        var cpuSrc: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, nil, &cpuSrc)
        let dst = try BGRAPool(width: 64, height: 32).make()
        #expect(throws: MediaError.self) { try gpu.convert(try #require(cpuSrc), into: dst) }
    }
}
