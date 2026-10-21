import CoreGraphics
import CoreVideo
import Foundation
import MediaEngine
import Testing
import TSCProjKit
@testable import RenderEngine

private let s = P.rate

/// QA12-1 finding: a parallel RenderEngineTests run (built -O) crashed on Metal's completion
/// queue releasing the CVMetalTextures a command buffer kept alive (`GPURetainer`): SIGSEGV in
/// `CVMetalTextureCache::bufferBackingNotInUse`. Many renderers, each wrapping video frames
/// through its texture cache and then freed at once, exercise exactly that release. Opt-in
/// (`WIZREC_STRESS=1`); `WIZREC_STRESS_ROUNDS` sets the renderers per task (default 40).
@Suite(.enabled(if: hasGPU && ProcessInfo.processInfo.environment["WIZREC_STRESS"] == "1",
                "set WIZREC_STRESS=1 to run"))
struct TextureLifetimeStressTests {
    @Test func renderersFreedRightAfterTheirFrames() async throws {
        let rounds = Int(ProcessInfo.processInfo.environment["WIZREC_STRESS_ROUNDS"] ?? "") ?? 40
        let p = try P.project(tracks: [
            P.track(0, [P.clip("VMFile", id: 10, src: 1, start: 0, duration: s)]),
            P.track(1, [P.clip("VMFile", id: 11, src: 1, start: 0, duration: s, parameters: [
                "scale0": 0.5, "scale1": 0.5, "translation0": 200.0,
            ])]),
        ], sources: P.defaultSources)
        let scene = P.scene(p)
        let frame = GPUTest.frame(GPUTest.pixelBuffer(64, 36) { x, y in Px(r: x * 4, g: y * 7, b: 99, a: 255) })
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    var drawn = 0
                    for _ in 0..<rounds {
                        let renderer = OfflineRenderer(scene: scene, pool: MediaPool()) { _ in frame }
                        let img = try await renderer.image(at: 0, size: CGSize(width: 96, height: 54))
                        if img.width == 96 { drawn += 1 }
                    }
                    return drawn
                }
            }
            var total = 0
            for try await n in group { total += n }
            #expect(total == 8 * rounds)
        }
    }

    /// Overlapping `render(at:into:)` calls on one renderer (as export does): each call wraps
    /// its target and the source frames through the renderer's texture caches while earlier
    /// command buffers complete and release their wrappers on Metal's completion queue.
    @Test func overlappingRendersIntoBuffers() async throws {
        let rounds = Int(ProcessInfo.processInfo.environment["WIZREC_STRESS_ROUNDS"] ?? "") ?? 40
        let p = try P.project(tracks: [
            P.track(0, [P.clip("VMFile", id: 10, src: 1, start: 0, duration: s)]),
        ], sources: P.defaultSources)
        let frame = GPUTest.frame(GPUTest.pixelBuffer(64, 36) { x, y in Px(r: x * 4, g: y * 7, b: 99, a: 255) })
        let renderer = OfflineRenderer(scene: P.scene(p), pool: MediaPool()) { _ in frame }
        for _ in 0..<rounds {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<8 {
                    group.addTask {
                        var out: CVPixelBuffer?
                        let attrs: [String: Any] = [
                            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                            kCVPixelBufferMetalCompatibilityKey as String: true,
                        ]
                        CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out)
                        nonisolated(unsafe) let pb = try #require(out)
                        try await renderer.render(at: Int64(i) * s / 8, into: pb)
                    }
                }
                try await group.waitForAll()
            }
        }
    }
}
