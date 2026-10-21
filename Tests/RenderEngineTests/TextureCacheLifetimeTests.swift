import CoreGraphics
import CoreVideo
import Foundation
import MediaEngine
import Metal
import os
import Testing
import WizRecTestSupport
@testable import RenderEngine

/// REN12-1: a -O test run crashed on Metal's completion queue while it released the
/// CVMetalTextures a command buffer kept alive (SIGSEGV in
/// `CVMetalTextureCache::bufferBackingNotInUse`). Wrappers now keep their cache alive and every
/// create, flush and final release runs under the cache's lock (`LockedTextureCache`).
@Suite(.serialized, .enabled(if: hasGPU)) struct TextureCacheLifetimeTests {
    @Test func wrapperKeepsItsCacheAlive() throws {
        let device = try #require(gpu)
        var cache = LockedTextureCache(device: device)
        try #require(cache != nil)
        weak let weakCache = cache
        let pb = GPUTest.pixelBuffer(8, 8) { _, _ in .green }
        var wrapped = cache?.texture(pb, format: .bgra8Unorm, width: 8, height: 8)
        #expect(wrapped?.texture.width == 8)
        cache = nil
        #expect(weakCache != nil, "a live wrapper must keep its cache")
        // The last release happens on another thread, as on Metal's completion queue.
        let box = OSAllocatedUnfairLock<CacheTexture?>(uncheckedState: wrapped)
        wrapped = nil
        try Deadline.blocking("release on another thread", seconds: 10) { done in
            // A dedicated thread, not a GCD worker: on a loaded CI runner the global pool can be
            // saturated by blocked workers, and the release would never run (CI run 35).
            let releaser = Thread {
                box.withLockUnchecked { $0 = nil }
                done()
            }
            releaser.start()
        }
        #expect(weakCache == nil)
    }

    /// Many compositors encode in parallel and are freed while their frames are still on the
    /// GPU; a long-lived compositor per thread keeps wrapping frames through its cache while
    /// Metal's completion queue releases the wrappers of its earlier command buffers.
    @Test func compositorsFreedWithFramesInFlight() throws {
        let device = try #require(gpu)
        let threads = 8, rounds = 24
        let canvas = CGSize(width: 96, height: 54)
        let rqA = GPUTest.request("lifetimeA"), rqB = GPUTest.request("lifetimeB")
        let frames: [FrameRequest: VideoFrame] = [
            rqA: GPUTest.frame(GPUTest.pixelBuffer(32, 18) { x, y in Px(r: x * 8, g: y * 14, b: 99, a: 255) }),
            rqB: GPUTest.frame(GPUTest.pixelBuffer(16, 16) { _, _ in .blue }),
        ]
        let plan = RenderPlan(time: 0, canvasSize: canvas, background: RGBA(0, 0, 0), layers: [
            Layer(clipID: 1, content: .video(rqA), size: canvas),
            Layer(clipID: 2, content: .video(rqB), size: CGSize(width: 30, height: 30),
                  transform: CGAffineTransform(translationX: 20, y: 10)),
        ])
        let pending = DispatchGroup()
        let failures = OSAllocatedUnfairLock<[String]>(initialState: [])
        let bad = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            do {
                guard let queue = device.makeCommandQueue() else { throw RenderError.noMetalDevice }
                let longLived = try Compositor(device: device)
                for _ in 0..<rounds {
                    let shortLived = try Compositor(device: device)
                    for comp in [shortLived, longLived] {
                        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 96,
                                                                         height: 54, mipmapped: false)
                        d.usage = [.renderTarget, .shaderRead]
                        d.storageMode = .private
                        guard let target = device.makeTexture(descriptor: d),
                              let cb = queue.makeCommandBuffer() else { throw RenderError.noMetalDevice }
                        try comp.encode(plan, frames: frames, into: target, commandBuffer: cb)
                        pending.enter()
                        cb.addCompletedHandler { buffer in
                            if buffer.status != .completed { bad.withLock { $0 += 1 } }
                            pending.leave()
                        }
                        cb.commit()
                    }
                    // `shortLived` (and its cache) is freed here, frames still in flight.
                }
            } catch {
                failures.withLock { $0.append("\(error)") }
            }
        }
        try Deadline.blocking("\(threads * rounds * 2) command buffers", seconds: 60) { done in
            pending.notify(queue: .global()) { done() }
        }
        #expect(failures.withLock { $0 }.isEmpty)
        #expect(bad.withLock { $0 } == 0)
    }

    /// Overlapping `render(at:into:)` calls on one offline renderer, as export does: each wraps its
    /// target through the render-target cache while earlier buffers' wrappers are released.
    @Test func offlineRenderTargetsReleasedConcurrently() async throws {
        let p = try P.project(tracks: [
            P.track(0, [P.clip("VMFile", id: 10, src: 1, start: 0, duration: P.rate)]),
        ], sources: P.defaultSources)
        let frame = GPUTest.frame(GPUTest.pixelBuffer(64, 36) { x, y in Px(r: x * 4, g: y * 7, b: 99, a: 255) })
        let renderer = OfflineRenderer(scene: P.scene(p), pool: MediaPool()) { _ in frame }
        let work = Task {
            for round in 0..<6 {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for i in 0..<8 {
                        group.addTask {
                            nonisolated(unsafe) let pb = GPUTest.pixelBuffer(160, 90) { _, _ in .black }
                            try await renderer.render(at: Int64(round * 8 + i) * P.rate / 64, into: pb)
                        }
                    }
                    try await group.waitForAll()
                }
            }
        }
        try await Deadline.value(of: work, "overlapping offline renders", seconds: 60)
    }
}
