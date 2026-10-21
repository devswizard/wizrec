// MED14-1: the Metal tone mapper's zero-copy textures are released on Metal's completion queue
// while other threads keep wrapping new planes through the same cache. With a raw
// `CVMetalTextureCache` that races inside CoreVideo (REN12-1 crashed RenderEngine under -O in
// `CVMetalTextureCache::bufferBackingNotInUse`); `LockedTextureCache` serialises it. These tests
// would crash (or trip Thread Sanitizer) if the mapper went back to an unlocked cache.
//
// Default sizes run in well under a second; `WIZREC_STRESS=1` runs the heavy variant.

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

    static let current: StressLoad = ProcessInfo.processInfo.environment["WIZREC_STRESS"] == "1"
        ? StressLoad(threads: 8, rounds: 400, width: 320, height: 180)
        : StressLoad(threads: 4, rounds: 16, width: 64, height: 36)
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
                var last: CVPixelBuffer?
                for _ in 0..<load.rounds {
                    let dst = try pool.make() // fresh pool buffers: new backings to wrap
                    try mapper.convert(src, into: dst)
                    last = dst
                }
                let ref = try pool.make()
                try mapper.reference.convert(src, into: ref)
                if let last, HDRPicture.compare(ref, last).maxDiff > 1 {
                    failures.withLock { $0.append("thread \(i): output differs from the CPU reference") }
                }
            } catch {
                failures.withLock { $0.append("thread \(i): \(error)") }
            }
        }
        #expect(failures.withLock { $0 }.isEmpty)
    }

    /// Mappers freed with their frames still on the GPU: each thread encodes on a short-lived
    /// mapper and a long-lived one without waiting, so wrappers (and the short-lived caches they
    /// keep alive) are released on the completion queue while the long-lived cache keeps wrapping.
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
                        let src = try HDRPicture.make(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, load.width,
                                                      load.height, seed: UInt64(i + 11))
                        let pool = try BGRAPool(width: load.width, height: load.height)
                        guard let queue = gpu.device.makeCommandQueue(),
                              let longLived = makeMapper(.hlg) else { throw MediaError.decodeFailed("no GPU") }
                        for _ in 0..<load.rounds {
                            guard let shortLived = makeMapper() else { throw MediaError.decodeFailed("no mapper") }
                            for m in [shortLived, longLived] {
                                guard let cb = queue.makeCommandBuffer() else { throw MediaError.decodeFailed("no cb") }
                                try m.encode(src, into: try pool.make(), commandBuffer: cb)
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

    /// The cache directly: one thread wraps planes and hands every wrapper to releaser threads,
    /// which drop them while the producer keeps creating and flushing.
    @Test func wrappersReleasedOnOtherThreads() throws {
        let load = StressLoad.current
        let device = try #require(MetalToneMapper.shared?.device)
        let cache = try #require(LockedTextureCache(device: device))
        let handOff = OSAllocatedUnfairLock<[CacheTexture]>(initialState: [])
        let producing = OSAllocatedUnfairLock(initialState: true)
        let made = OSAllocatedUnfairLock(initialState: 0)
        let count = load.threads * load.rounds * 4
        try onThreads(load.threads + 1, "\(count) wrappers released on \(load.threads) threads") { i in
            if i == 0 {
                defer { producing.withLock { $0 = false } }
                guard let pool = try? BGRAPool(width: load.width, height: load.height) else { return }
                for n in 0..<count {
                    guard let pb = try? pool.make(),
                          let t = cache.texture(pb, format: .bgra8Unorm, width: load.width, height: load.height)
                    else { continue }
                    made.withLock { $0 += 1 }
                    handOff.withLockUnchecked { $0.append(t) }
                    if n % 8 == 0 { cache.flush() }
                }
            } else {
                while true {
                    let batch = handOff.withLockUnchecked { q -> [CacheTexture] in
                        defer { q.removeAll() }
                        return q
                    }
                    if batch.isEmpty {
                        if !producing.withLock({ $0 }) && handOff.withLockUnchecked({ $0.isEmpty }) { return }
                        Thread.sleep(forTimeInterval: 0.0001)
                    }
                    // `batch` (the last references) is released here, on this thread.
                }
            }
        }
        #expect(made.withLock { $0 } == count)
        #expect(handOff.withLockUnchecked { $0.isEmpty })
    }

    /// A wrapper released on another thread after its mapper and cache are gone still finds the
    /// cache it came from: wrappers keep their cache alive.
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
