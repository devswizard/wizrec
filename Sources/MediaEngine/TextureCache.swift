import CoreVideo
import IOSurface
import Metal

/// Zero-copy Metal views of IOSurface-backed `CVPixelBuffer` planes, safe to create on one thread
/// and release on any other (Metal's completion queue, a later caller). Shared by MediaEngine's
/// GPU tone mapper and RenderEngine's compositor and offline renderer (REN12-1, MED14-1).
///
/// Each texture is made straight from the buffer's IOSurface
/// (`MTLDevice.makeTexture(descriptor:iosurface:plane:)`); there is no `CVMetalTextureCache`.
/// Why: a `CVMetalTextureCache` keeps a table of backings that is updated when a wrapper is
/// released and when a pool-owned buffer's backing goes out of use. Freeing a
/// `CVPixelBufferPool` while its buffers are still wrapped and being released on other threads
/// crashed inside CoreVideo (`CVMetalTextureCache::finalize` → `CVMetalTextureBacking::finalize`)
/// even with every create, flush and release serialised under one lock (measured 2026-10-21:
/// 12/12 runs with the lock, 0/4 with the same pool and threads but no cache; repro
/// `ToneMapMetalStressTests.poolFreedWhileWrapped`, heavy with `WIZREC_STRESS=1`). A lock
/// cannot cover that: the pool's teardown runs on the pool owner's thread, outside it. Reading of
/// REN12-1 (the -O crash on Metal's completion queue in `bufferBackingNotInUse`, fixed in
/// session 9 with a lock): decoders and their pools are freed while their frames are still
/// wrapped for in-flight command buffers, which is this race; an unlocked cache whose pools
/// outlive their wrappers did not crash in 10 -O runs of the same stress tests. Textures made
/// from the IOSurface share no state, so there is nothing to race on.
///
/// Cost (MED15-1, M3 Pro, release, `TextureCachePerfTests`, 2026-10-21): 5–7 µs of CPU per
/// texture; a 4K HDR playback frame (Y, CbCr, tone-map output, compositor input) spends
/// 0.04–0.11 ms more CPU than with textures reused per IOSurface, and its wall and GPU times are
/// the same within noise (≈ 1.9–3.3 ms/frame for tone map + composite). So there is no reuse
/// cache: it would save under 1 % of the 16.6 ms 4K60 budget.
///
/// The type keeps its name and API from the cache it replaced; `flush()` is now a no-op.
// @unchecked Sendable: immutable after init; `MTLDevice` is thread-safe.
public final class LockedTextureCache: @unchecked Sendable {
    private let device: any MTLDevice
    private let storage: MTLStorageMode

    /// Textures for `device`. Never nil (the initialiser stays failable for source compatibility).
    public init?(device: any MTLDevice) {
        self.device = device
        storage = device.hasUnifiedMemory ? .shared : .managed
    }

    /// Wraps `plane` of the IOSurface-backed `buffer` (`width`×`height` px) as a `format` texture,
    /// zero-copy. The texture stays valid, and the buffer is kept out of its pool, while the
    /// returned wrapper lives: drop the wrapper only once the GPU work that uses it has finished.
    /// Nil when the buffer has no IOSurface, the plane does not exist, the size exceeds the
    /// plane or the format's pixel size does not match the plane's (`status` gets a CoreVideo
    /// return code when given).
    public func texture(_ buffer: CVPixelBuffer, format: MTLPixelFormat, width: Int, height: Int,
                        plane: Int = 0, status: UnsafeMutablePointer<CVReturn>? = nil) -> CacheTexture? {
        status?.pointee = kCVReturnSuccess
        func fail(_ rc: CVReturn) -> CacheTexture? {
            status?.pointee = rc
            return nil
        }
        guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else {
            return fail(kCVReturnPixelBufferNotMetalCompatible)
        }
        let planes = IOSurfaceGetPlaneCount(surface)
        guard width > 0, height > 0, plane >= 0, plane < max(planes, 1) else { return fail(kCVReturnInvalidArgument) }
        let planeW = planes == 0 ? IOSurfaceGetWidth(surface) : IOSurfaceGetWidthOfPlane(surface, plane)
        let planeH = planes == 0 ? IOSurfaceGetHeight(surface) : IOSurfaceGetHeightOfPlane(surface, plane)
        let element = planes == 0 ? IOSurfaceGetBytesPerElement(surface)
            : IOSurfaceGetBytesPerElementOfPlane(surface, plane)
        guard width <= planeW, height <= planeH else { return fail(kCVReturnInvalidSize) }
        if let size = Self.bytesPerPixel(format), size != element { return fail(kCVReturnInvalidPixelFormat) }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                         mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = storage
        guard let tex = device.makeTexture(descriptor: d, iosurface: surface, plane: plane) else {
            return fail(kCVReturnPixelBufferNotMetalCompatible)
        }
        return CacheTexture(texture: tex, buffer: buffer, owner: self)
    }

    /// No-op, kept for source compatibility (there is no cache to flush).
    public func flush() {}

    /// Bytes per pixel of the uncompressed formats wrapped in this codebase; nil = not checked.
    static func bytesPerPixel(_ f: MTLPixelFormat) -> Int? {
        switch f {
        case .r8Unorm, .r8Uint: 1
        case .rg8Unorm, .rg8Uint, .r16Unorm, .r16Uint, .r16Float: 2
        case .bgra8Unorm, .bgra8Unorm_srgb, .rgba8Unorm, .rgba8Uint, .rg16Unorm, .rg16Uint, .rg16Float: 4
        case .rgba16Unorm, .rgba16Uint, .rgba16Float: 8
        default: nil
        }
    }
}

/// One zero-copy Metal texture of a pixel buffer plane (in the plane's pixels). Holds the buffer
/// itself, so a pool cannot recycle its IOSurface into a new frame while the GPU still reads it.
/// Releasing it, on any thread, is safe; the texture must not be used by the GPU after that.
// @unchecked Sendable: immutable after init; `MTLTexture` and `CVPixelBuffer` are thread-safe to
// retain and release.
public final class CacheTexture: @unchecked Sendable {
    /// The Metal view of the wrapped pixel buffer plane.
    public let texture: any MTLTexture
    private let buffer: CVPixelBuffer
    /// Kept as before the move to IOSurface textures: the factory lives as long as its textures.
    private let owner: LockedTextureCache

    fileprivate init(texture: any MTLTexture, buffer: CVPixelBuffer, owner: LockedTextureCache) {
        self.texture = texture
        self.buffer = buffer
        self.owner = owner
    }
}
