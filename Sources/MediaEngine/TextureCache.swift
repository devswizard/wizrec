import CoreVideo
import Metal
import os

/// A `CVMetalTextureCache` that is safe to use from the encoding thread while other threads
/// (Metal's completion queue, a later caller) release earlier wrappers (REN12-1, MED14-1).
///
/// The cache is not thread-safe, and a wrapper's final release calls back into it
/// (`CVMetalTextureCache::bufferBackingNotInUse`). So every create, flush and final wrapper
/// release runs under one lock, and every wrapper keeps its cache alive: the owner of a cache
/// may be freed while its frames are still on the GPU.
// @unchecked Sendable: `cache` is only touched under `lock`; the lock itself is Sendable.
final class LockedTextureCache: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private let cache: CVMetalTextureCache

    /// Nil when CoreVideo cannot make a cache for `device`.
    init?(device: any MTLDevice) {
        var c: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &c) == kCVReturnSuccess, let c else { return nil }
        cache = c
    }

    /// Wraps `plane` of the IOSurface-backed `buffer` (`width`×`height` px) as a `format` texture,
    /// zero-copy. The texture stays valid while the returned wrapper lives: drop the wrapper only
    /// once the GPU work that uses it has finished. Nil on failure (`status` gets the CoreVideo
    /// return code when given).
    func texture(_ buffer: CVPixelBuffer, format: MTLPixelFormat, width: Int, height: Int,
                 plane: Int = 0, status: UnsafeMutablePointer<CVReturn>? = nil) -> CacheTexture? {
        let made: (Unmanaged<CVMetalTexture>, any MTLTexture)? = lock.withLockUnchecked {
            var cv: CVMetalTexture?
            let rc = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format, width, height,
                                                               plane, &cv)
            status?.pointee = rc
            guard rc == kCVReturnSuccess, let cv, let tex = CVMetalTextureGetTexture(cv) else { return nil }
            // The wrapper's own +1, given back in `release` under the lock. The local `cv`
            // reference dropped after this closure is never the last one.
            return (Unmanaged.passRetained(cv), tex)
        }
        guard let made else { return nil }
        return CacheTexture(texture: made.1, owner: self, wrapper: made.0)
    }

    /// Lets the cache recycle the backings of wrappers already released.
    func flush() {
        lock.withLockUnchecked { CVMetalTextureCacheFlush(cache, 0) }
    }

    /// Drops a wrapper's last reference under the lock (its finalizer updates the cache).
    fileprivate func release(_ wrapper: Unmanaged<CVMetalTexture>) {
        lock.withLockUnchecked { wrapper.release() }
    }
}

/// One cache-backed Metal texture. Releasing it, on any thread, is safe; the texture must not be
/// used by the GPU after that.
// @unchecked Sendable: immutable after init; `wrapper` is released exactly once, in deinit,
// through the owner's lock. `MTLTexture` is thread-safe to retain and release.
final class CacheTexture: @unchecked Sendable {
    /// The Metal view of the wrapped pixel buffer plane.
    let texture: any MTLTexture
    private let owner: LockedTextureCache
    private let wrapper: Unmanaged<CVMetalTexture>

    fileprivate init(texture: any MTLTexture, owner: LockedTextureCache, wrapper: Unmanaged<CVMetalTexture>) {
        self.texture = texture
        self.owner = owner
        self.wrapper = wrapper
    }

    deinit { owner.release(wrapper) }
}
