import CoreGraphics
import CoreVideo
import Foundation
import MediaEngine
import Testing
import TSCProjKit
@testable import RenderEngine

/// Render-side export throughput on a temp copy of the user's demo project (the original is
/// never opened for writing). Runs only with `WIZREC_PERF=1`, ideally in release on an idle machine:
/// `WIZREC_PERF=1 swift test -c release --filter OfflinePerfTests`
enum RenderPerf {
    static let demoBundle = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/demo project.cmproj")
    static let enabled = ProcessInfo.processInfo.environment["WIZREC_PERF"] == "1"
        && FileManager.default.fileExists(atPath: demoBundle.path)

    /// Copies the demo bundle into a fresh temp dir and opens the copy. Caller removes `dir`.
    @MainActor static func demoCopy() throws -> (scene: SceneModel, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-renderperf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent("demo.cmproj")
        try FileManager.default.copyItem(at: demoBundle, to: copy)
        let bundle = try ProjectBundle(url: copy)
        return (SceneModel(project: bundle.project, resolve: bundle.resolve), dir)
    }

    /// Output frame times at `fps` over the whole timeline, ticks (exact for editRate 705600000).
    static func ticks(fps: Int, scene: SceneModel) -> [Int64] {
        let n = Int(scene.timebase.seconds(scene.duration) * Double(fps))
        return (0..<n).map { Int64($0) * scene.timebase.editRate / Int64(fps) }
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    static func report(_ s: String) { print("render perf: \(s)") }
}

// @unchecked: each buffer is used by one render call at a time (the test waits before reuse).
struct PixelBufferBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ b: CVPixelBuffer) { buffer = b }
}

@Suite(.enabled(if: RenderPerf.enabled && hasGPU), .serialized) struct OfflinePerfTests {
    /// Per-stage cost of the sequential path (evaluate → fetch → GPU, one frame at a time).
    @Test func stageBreakdown() async throws {
        let (scene, dir) = try await RenderPerf.demoCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = MediaPool()
        let gpu = try OfflineGPU()
        let ticks = RenderPerf.ticks(fps: 30, scene: scene)
        nonisolated(unsafe) let pb = try Buffers.make(1920, 1080)
        let clock = ContinuousClock()
        var tEval = Duration.zero, tFetch = Duration.zero, tGPU = Duration.zero
        for (n, t) in ticks.enumerated() {
            let t0 = clock.now
            let plan = scene.evaluate(at: t)
            let t1 = clock.now
            let fetched = try await OfflineGPU.fetch(plan.frameRequests) { try await pool.frame($0) }
            let t2 = clock.now
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                do {
                    try gpu.submit(plan, frames: fetched, into: pb) { e in
                        if let e { c.resume(throwing: e) } else { c.resume() }
                    }
                } catch { c.resume(throwing: error) }
            }
            let t3 = clock.now
            if n > 0 { tEval += t1 - t0; tFetch += t2 - t1; tGPU += t3 - t2 }  // frame 0 = warm-up
        }
        let k = Double(ticks.count - 1) / 1000
        RenderPerf.report(String(format: "sequential per frame: evaluate %.2f ms, fetch %.2f ms, GPU %.2f ms (%d frames)",
                                 RenderPerf.seconds(tEval) / k, RenderPerf.seconds(tFetch) / k,
                                 RenderPerf.seconds(tGPU) / k, ticks.count))
    }

    /// Before S3-REN-1 the exporter overlapped up to 6 `render(at:into:)` calls; kept for comparison.
    @Test(arguments: [1, 6]) func overlappedRenderInto(_ depth: Int) async throws {
        let (scene, dir) = try await RenderPerf.demoCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let renderer = OfflineRenderer(scene: scene, pool: MediaPool())
        let ticks = RenderPerf.ticks(fps: 30, scene: scene)
        nonisolated(unsafe) let warm = try Buffers.make(1920, 1080)
        try await renderer.render(at: 0, into: warm)
        let buffers = try (0..<depth).map { _ in PixelBufferBox(try Buffers.make(1920, 1080)) }
        let elapsed = try await ContinuousClock().measure {
            var inFlight: [Task<Void, any Error>] = []
            for (n, t) in ticks.enumerated() {
                if inFlight.count == depth { try await inFlight.removeFirst().value }
                let box = buffers[n % depth]
                inFlight.append(Task {
                    nonisolated(unsafe) let pb = box.buffer
                    try await renderer.render(at: t, into: pb)
                })
            }
            for t in inFlight { try await t.value }
        }
        let fps = Double(ticks.count) / RenderPerf.seconds(elapsed)
        RenderPerf.report(String(format: "render(at:into:) overlapped depth %d: %.1f fps = %.2f× real time",
                                 depth, fps, fps / 30))
    }

    /// `RenderPipeline` throughput at 1080p30 (render only, no encoder).
    @Test(arguments: [2, 4, 6]) func pipeline(_ depth: Int) async throws {
        let (scene, dir) = try await RenderPerf.demoCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let renderer = OfflineRenderer(scene: scene, pool: MediaPool())
        let ticks = RenderPerf.ticks(fps: 30, scene: scene)
        nonisolated(unsafe) let warm = try Buffers.make(1920, 1080)
        try await renderer.render(at: 0, into: warm)
        let buffers = try (0..<(depth + 1)).map { _ in PixelBufferBox(try Buffers.make(1920, 1080)) }
        let elapsed = try await ContinuousClock().measure {
            let pipe = renderer.pipeline(ticks: ticks, maxInFlight: depth) { buffers[$0 % (depth + 1)].buffer }
            var n = 0
            while try await pipe.next() != nil { n += 1 }
            #expect(n == ticks.count)
        }
        let fps = Double(ticks.count) / RenderPerf.seconds(elapsed)
        RenderPerf.report(String(format: "RenderPipeline depth %d: %.1f fps = %.2f× real time", depth, fps, fps / 30))
    }

    /// Real media (screen recording + shader background): pipelined frames equal sequential ones.
    @Test func demoPipelineMatchesSequential() async throws {
        let (scene, dir) = try await RenderPerf.demoCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let all = RenderPerf.ticks(fps: 30, scene: scene)
        let ticks = stride(from: 0, to: all.count, by: 7).map { all[$0] }
        let seq = OfflineRenderer(scene: scene, pool: MediaPool())
        var expected: [[UInt8]] = []
        for t in ticks {
            nonisolated(unsafe) let pb = try Buffers.make(640, 360)
            try await seq.render(at: t, into: pb)
            expected.append(Buffers.bytes(pb))
        }
        let pipe = OfflineRenderer(scene: scene, pool: MediaPool())
            .pipeline(ticks: ticks, maxInFlight: 6) { _ in try Buffers.make(640, 360) }
        var i = 0
        while let f = try await pipe.next() {
            #expect(Buffers.bytes(f.pixelBuffer) == expected[i], "frame \(i)")
            i += 1
        }
        #expect(i == ticks.count)
    }
}
