// MED14-1: the Metal tone mapper's zero-copy textures are released on Metal's completion queue
// (or any other thread) while other threads keep wrapping new planes, and pools are freed with
// their buffers still wrapped. `poolFreedWhileWrapped` crashed every run while the textures came
// from a `CVMetalTextureCache`, locked or not (see `LockedTextureCache`); they now come straight
// from the IOSurface. The other tests pin the concurrent create/release patterns of the tone
// mapper, RenderEngine and export.
//
// Default sizes run in about a second (debug); `WIZREC_STRESS=1` runs the heavy variant.

import CFFmpeg
import CoreVideo
import Foundation
import Metal
import os
import Testing
import WizRecTestSupport
@testable import MediaEngine

/// Bounds of one stress run: worker threads, rounds per thread and picture size in pixels.
private struct StressLoad {
    let threads: Int, rounds: Int, width: Int, height: Int
    /// Texture caches created and freed by the cache-level test.
    let generations: Int

    static let current: StressLoad = ProcessInfo.processInfo.environment["WIZREC_STRESS"] == "1"
        ? StressLoad(threads: 8, rounds: 400, width: 64, height: 36, generations: 2000)
        : StressLoad(threads: 4, rounds: 16, width: 64, height: 36, generations: 120)
}

/// Runs `body(index)` on `count` dedicated threads and waits (bounded) until all have returned.
/// Dedicated `Thread`s, not GCD workers: a saturated global pool on a loaded CI runner could
/// leave a hand-off unscheduled (CI run 35).
private func onThreads(_ count: Int, _ what: String, seconds: Double = 120,
                       _ body: @escaping @Sendable (Int) -> Void) throws {
    let left = OSAllocatedUnfairLock(initialState: count)
    try Deadline.blocking(what, seconds: seconds) { done in
        for i in 0..<count {
            let t = Thread {
                body(i)
                if left.withLock({ $0 -= 1; return $0 == 0 }) { done() }
            }
            t.stackSize = 1 << 20
            t.start()
        }
    }
}

private func makeMapper(_ t: HDRTransfer = .pq) -> MetalToneMapper? {
    MetalToneMapper(ToneMapper(transfer: t, colorSpace: AVCOL_SPC_BT2020_NCL, primaries: AVCOL_PRI_BT2020,
                               fullRange: false))
}

/// A new, unfilled IOSurface-backed `format` buffer: every one is a new backing for the texture
/// cache to track (pool buffers would be recycled and mostly hit existing backings).
private func freshBuffer(_ format: OSType, _ w: Int, _ h: Int) throws -> CVPixelBuffer {
    var buf: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
                                  kCVPixelBufferMetalCompatibilityKey: true]
    let rc = CVPixelBufferCreate(nil, w, h, format, attrs as CFDictionary, &buf)
    guard rc == kCVReturnSuccess, let buf else { throw MediaError.decodeFailed("CVPixelBufferCreate \(rc)") }
    return buf
}

private let p010 = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
private let bgra = kCVPixelFormatType_32BGRA

@Suite(.serialized, .enabled(if: MetalToneMapper.shared != nil, "no Metal device"))
struct ToneMapMetalStressTests {
    /// One mapper shared by several threads, each converting its own frames: every `convert`
    /// wraps planes while the completion queue releases the wrappers of earlier frames. The
    /// output stays the CPU reference's.
    @Test func sharedMapperConcurrentConverts() throws {
        let load = StressLoad.current
        nonisolated(unsafe) let mapper = try #require(makeMapper())
        let failures = OSAllocatedUnfairLock<[String]>(initialState: [])
        try onThreads(load.threads, "\(load.threads)×\(load.rounds) shared converts") { i in
            do {
                let src = try HDRPicture.make(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, load.width,
                                              load.height, seed: UInt64(i + 1))
                let pool = try BGRAPool(width: load.width, height: load.height)
                for _ in 0..<load.rounds {
                    try mapper.convert(try freshBuffer(p010, load.width, load.height),
                                       into: try freshBuffer(bgra, load.width, load.height))
                }
                let last = try pool.make(), ref = try pool.make()
                try mapper.convert(src, into: last)
                try mapper.reference.convert(src, into: ref)
                if HDRPicture.compare(ref, last).maxDiff > 1 {
                    failures.withLock { $0.append("thread \(i): output differs from the CPU reference") }
                }
            } catch {
                failures.withLock { $0.append("thread \(i): \(error)") }
            }
        }
        #expect(failures.withLock { $0 }.isEmpty)
    }

    /// Mappers freed with their frames still on the GPU: each thread encodes on a short-lived
    /// mapper and a long-lived one without waiting, so wrappers (and the short-lived factories
    /// they keep alive) are released on the completion queue while the long-lived one keeps wrapping.
    @Test func mappersFreedWithFramesInFlight() throws {
        let load = StressLoad.current
        let gpu = try #require(MetalToneMapper.shared)
        let total = load.threads * load.rounds * 2
        let pending = OSAllocatedUnfairLock(initialState: total)
        let bad = OSAllocatedUnfairLock(initialState: 0)
        let failures = OSAllocatedUnfairLock<[String]>(initialState: [])
        try Deadline.blocking("\(total) tone-map command buffers", seconds: 120) { allDone in
            let finish: @Sendable (Int) -> Void = { n in
                if pending.withLock({ $0 -= n; return $0 == 0 }) { allDone() }
            }
            for i in 0..<load.threads {
                let t = Thread {
                    var encoded = 0
                    do {
                        guard let queue = gpu.device.makeCommandQueue(),
                              let longLived = makeMapper(.hlg) else { throw MediaError.decodeFailed("no GPU") }
                        let reference = longLived.reference // CPU LUTs built once; each mapper uploads its own
                        for _ in 0..<load.rounds {
                            guard let shortLived = MetalToneMapper(reference) else {
                                throw MediaError.decodeFailed("no mapper")
                            }
                            for m in [shortLived, longLived] {
                                guard let cb = queue.makeCommandBuffer() else { throw MediaError.decodeFailed("no cb") }
                                try m.encode(try freshBuffer(p010, load.width, load.height),
                                             into: try freshBuffer(bgra, load.width, load.height), commandBuffer: cb)
                                cb.addCompletedHandler { b in
                                    if b.status != .completed { bad.withLock { $0 += 1 } }
                                    finish(1)
                                }
                                cb.commit()
                                encoded += 1
                            }
                            // `shortLived` is freed here with its frame still in flight.
                        }
                    } catch {
                        failures.withLock { $0.append("thread \(i): \(error)") }
                    }
                    finish(load.rounds * 2 - encoded) // count what was never committed
                }
                t.start()
            }
        }
        #expect(failures.withLock { $0 }.isEmpty)
        #expect(bad.withLock { $0 } == 0)
    }

    /// The factory directly: one thread wraps pool buffers and hands each wrapper to releaser
    /// threads, which drop them one by one while the producer keeps creating and flushing. Each
    /// generation ends with the factory freed by whichever thread drops its last wrapper.
    @Test func wrappersReleasedOnOtherThreads() throws {
        let load = StressLoad.current
        let device = try #require(MetalToneMapper.shared?.device)
        let perGeneration = load.threads * 32
        let made = OSAllocatedUnfairLock(initialState: 0)
        for _ in 0..<load.generations {
            // Created and freed on this thread once every wrapper of its buffers is gone (the
            // pool-teardown case is `poolFreedWhileWrapped`).
            let pool = try BGRAPool(width: load.width, height: load.height)
            weak var weakCache: LockedTextureCache?
            try { () throws -> Void in
                let cache = try #require(LockedTextureCache(device: device))
                weakCache = cache
                try releasedConcurrently(cache, pool: pool, count: perGeneration, load: load, made: made)
            }()
            #expect(weakCache == nil, "the last wrapper frees its cache")
        }
        #expect(made.withLock { $0 } == perGeneration * load.generations)
    }

    /// One generation: a producer thread wraps `count` buffers of `sharedPool` through `cache`,
    /// `load.threads` threads release them. The pool outlives the generation.
    private func releasedConcurrently(_ cache: LockedTextureCache, pool sharedPool: BGRAPool, count: Int,
                                      load: StressLoad, made: OSAllocatedUnfairLock<Int>) throws {
        let handOff = OSAllocatedUnfairLock<[CacheTexture]>(initialState: [])
        let producing = OSAllocatedUnfairLock(initialState: true)
        nonisolated(unsafe) var producer: LockedTextureCache? = cache
        nonisolated(unsafe) let pool = sharedPool
        try onThreads(load.threads + 1, "\(count) wrappers released on \(load.threads) threads") { i in
            if i == 0 {
                defer { producing.withLock { $0 = false } }
                guard let c = producer else { return }
                producer = nil // from here on only the wrappers keep the cache alive
                for n in 0..<count {
                    guard let pb = try? pool.make(),
                          let t = c.texture(pb, format: .bgra8Unorm, width: load.width, height: load.height)
                    else { continue }
                    made.withLock { $0 += 1 }
                    handOff.withLockUnchecked { $0.append(t) }
                    if n % 4 == 0 { c.flush() }
                }
            } else {
                while true {
                    let one = handOff.withLockUnchecked { $0.popLast() }
                    if one == nil {
                        if !producing.withLock({ $0 }) && handOff.withLockUnchecked({ $0.isEmpty }) { return }
                        Thread.sleep(forTimeInterval: 0.00005)
                    }
                    // `one` (the last reference) is released here, on this thread.
                }
            }
        }
    }

    /// Pool teardown (the REN12-1 reading): the producer thread owns the pool and frees it on exit
    /// while its buffers are still wrapped and being released on other threads, as a decoder freed
    /// with frames in flight does. With `CVMetalTextureCache` textures this crashed in
    /// `CVMetalTextureCache::finalize` (`CVMetalTextureBacking::finalize`) in 12/12 debug runs,
    /// with the lock; same pool and threads without a cache: 0/4 (2026-10-21).
    @Test func poolFreedWhileWrapped() throws {
        let load = StressLoad.current
        let device = try #require(MetalToneMapper.shared?.device)
        for _ in 0..<load.generations {
            let cache = try #require(LockedTextureCache(device: device))
            let handOff = OSAllocatedUnfairLock<[CacheTexture]>(initialState: [])
            let producing = OSAllocatedUnfairLock(initialState: true)
            try onThreads(load.threads + 1, "pool freed while wrapped") { i in
                if i == 0 {
                    defer { producing.withLock { $0 = false } }
                    guard let pool = try? BGRAPool(width: load.width, height: load.height) else { return }
                    for n in 0..<(load.threads * 32) {
                        guard let pb = try? pool.make(),
                              let t = cache.texture(pb, format: .bgra8Unorm, width: load.width, height: load.height)
                        else { continue }
                        handOff.withLockUnchecked { $0.append(t) }
                        if n % 4 == 0 { cache.flush() }
                    }
                    // `pool` is freed here, on this thread, with wrapped buffers outstanding.
                } else {
                    while true {
                        let one = handOff.withLockUnchecked { $0.popLast() }
                        if one == nil {
                            if !producing.withLock({ $0 }) && handOff.withLockUnchecked({ $0.isEmpty }) { return }
                            Thread.sleep(forTimeInterval: 0.00005)
                        }
                    }
                }
            }
        }
    }

    /// A wrapper released on another thread after its mapper and factory are gone: wrappers keep
    /// their factory alive (as they kept the old cache alive).
    @Test func wrapperOutlivesItsCache() throws {
        let device = try #require(MetalToneMapper.shared?.device)
        var cache = LockedTextureCache(device: device)
        weak let weakCache = cache
        let pb = try BGRAPool(width: 16, height: 16).make()
        var wrapped = cache?.texture(pb, format: .bgra8Unorm, width: 16, height: 16)
        #expect(wrapped?.texture.width == 16)
        cache = nil
        #expect(weakCache != nil, "a live wrapper must keep its cache")
        let box = OSAllocatedUnfairLock<CacheTexture?>(uncheckedState: wrapped)
        wrapped = nil
        try onThreads(1, "release on another thread", seconds: 10) { _ in
            box.withLockUnchecked { $0 = nil }
        }
        #expect(weakCache == nil)
    }
}
