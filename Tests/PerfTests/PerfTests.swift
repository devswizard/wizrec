import CoreGraphics
import CoreMedia
import Foundation
import MediaEngine
import Metal
import RenderEngine
import TestGenKit
import Testing
import WizRecTestSupport
import TSCProjKit

/// Throughput tests for decode and composite at 1080p and 4K.
///
/// Off by default so CI never flakes on shared runners. Run on an idle machine, in release:
/// ```
/// WIZREC_PERF=1 swift test -c release --filter PerfTests
/// ```
/// Each test prints a `perf:` line; thresholds come from coordination/CONTRACTS.md where
/// one exists (1080p sequential decode ≥ 120 fps, random seek ≤ 50 ms, evaluate < 0.5 ms),
/// enforced in release builds only; everything else is reported.
enum Perf {
    static let enabled = ProcessInfo.processInfo.environment["WIZREC_PERF"] == "1"
    static let frames = 120
    static let fps = 30

    enum Resolution: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case hd1080 = "1080p", uhd4k = "4K"
        var size: (w: Int, h: Int) { self == .hd1080 ? (1920, 1080) : (3840, 2160) }
        var testDescription: String { rawValue }
    }

    #if DEBUG
    static let buildConfig = "debug (numbers are pessimistic; use -c release)"
    #else
    static let buildConfig = "release"
    #endif

    /// One synthesised H.264 test-card movie per resolution, shared by all tests in the process.
    static func movie(_ r: Resolution) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-perf", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("card-\(r.rawValue)-\(frames).mp4")
        if !FileManager.default.fileExists(atPath: url.path) {
            let (w, h) = r.size
            let card = TestCard(width: w, height: h, label: r.rawValue)
            let tmp = dir.appendingPathComponent("tmp-\(UUID().uuidString).mp4")
            try MediaWriter.writeH264(to: tmp, width: w, height: h, fps: fps, frameCount: frames) { n, ctx in
                card.draw(frame: n, fps: fps, in: ctx)
            }
            try? FileManager.default.moveItem(at: tmp, to: url)
        }
        return url
    }

    static func time(_ n: Int) -> CMTime { CMTime(value: CMTimeValue(n), timescale: CMTimeScale(fps)) }

    static func report(_ s: String) { print("perf: \(s)  [\(buildConfig)]") }

    /// Contract thresholds are enforced only in release builds; debug numbers are reported.
    #if DEBUG
    static let enforce = false
    #else
    static let enforce = true
    #endif
}

/// One serialized suite so measurements never overlap.
@Suite(.enabled(if: Perf.enabled, "set WIZREC_PERF=1 to run throughput tests"), .serialized)
struct PerfTests {
    @Suite struct Decode {
    @Test("sequential decode throughput", arguments: Perf.Resolution.allCases)
    func sequentialDecode(_ r: Perf.Resolution) async throws {
        let url = try Perf.movie(r)
        let pool = MediaPool()
        _ = try await pool.source(for: url)  // open outside the timed loop
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            for n in 0..<Perf.frames { _ = try await pool.frame(FrameRequest(url: url, stream: 0, time: Perf.time(n))) }
        }
        let fps = Double(Perf.frames) / elapsed.seconds
        Perf.report(String(format: "decode %@ sequential %.1f fps (%d frames in %.3f s)", r.rawValue, fps, Perf.frames, elapsed.seconds))
        if r == .hd1080 && Perf.enforce { LoadGate.expect(fps >= 120, String(format: "contract: 1080p h264 sequential decode ≥ 120 fps, got %.1f fps", fps)) }
    }

    @Test("random seek latency", arguments: Perf.Resolution.allCases)
    func randomSeek(_ r: Perf.Resolution) async throws {
        let url = try Perf.movie(r)
        let pool = MediaPool(cacheLimitBytes: 1)  // every request decodes
        _ = try await pool.source(for: url)
        var rng = SystemRandomNumberGenerator()
        let picks = (0..<20).map { _ in Int.random(in: 0..<Perf.frames, using: &rng) }
        let clock = ContinuousClock()
        var worst = Duration.zero
        let total = try await clock.measure {
            for n in picks {
                let d = try await clock.measure { _ = try await pool.frame(FrameRequest(url: url, stream: 0, time: Perf.time(n))) }
                worst = max(worst, d)
            }
        }
        let mean = total.seconds / Double(picks.count) * 1000
        Perf.report(String(format: "decode %@ random seek mean %.1f ms, worst %.1f ms", r.rawValue, mean, worst.seconds * 1000))
        if r == .hd1080 && Perf.enforce { LoadGate.expect(mean <= 50, String(format: "contract: random seek ≤ 50 ms, got %.1f ms", mean)) }
    }
    }

    @Suite struct Composite {
    /// Three layers at canvas resolution: full-frame clip, the same clip at half size and
    /// 70 % opacity, rotated; and a still card. Measures evaluate → decode → composite → CGImage.
    @MainActor
    static func renderer(_ r: Perf.Resolution) throws -> (OfflineRenderer, Int64) {
        let (scene, editRate) = try Self.scene(r)
        return (OfflineRenderer(scene: scene, pool: MediaPool()), editRate)
    }

    /// The scene of `renderer(_:)` and the project's edit rate.
    @MainActor
    static func scene(_ r: Perf.Resolution) throws -> (SceneModel, Int64) {
        let (w, h) = r.size
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wizrec-perf/project-\(r.rawValue)-\(UUID().uuidString).cmproj", isDirectory: true)
        let mediaDir = dir.appendingPathComponent("media/1", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try Perf.movie(r), to: mediaDir.appendingPathComponent("card.mp4"))
        try MediaWriter.writePNG(to: mediaDir.appendingPathComponent("still.png"), width: w / 2, height: h / 2) {
            TestImages.card(width: w / 2, height: h / 2, in: $0)
        }
        let b = ProjectBuilder(title: "perf-\(r.rawValue)", width: w, height: h, fps: Int64(Perf.fps))
        let movie = MediaWriter.MovieInfo(width: w, height: h, fps: Perf.fps, frameCount: Perf.frames,
                                          timescale: Int32(Perf.fps * 1000))
        let clip = b.addVideoSource(src: "./media/1/card.mp4", movie: movie)
        let still = b.addImageSource(src: "./media/1/still.png", width: w / 2, height: h / 2)
        let length = b.frames(Int64(Perf.frames))
        b.tracks = [
            [b.video(clip, start: 0, duration: length)],
            [b.video(clip, start: 0, duration: length, params: [
                "translation0": .constant(Double(w) / 5), "rotation2": .constant(0.2),
                "scale0": .constant(0.5), "scale1": .constant(0.5), "opacity": .constant(0.7),
            ])],
            [b.image(still, start: 0, duration: length, params: ["translation0": .constant(-Double(w) / 4)])],
        ]
        try b.build().serialized().write(to: dir.appendingPathComponent("project.tscproj"))
        let bundle = try ProjectBundle(url: dir)
        let scene = SceneModel(project: bundle.project, resolve: bundle.resolve)
        return (scene, bundle.project.timebase.editRate)
    }

    @Test("render throughput (decode + composite + readback)", arguments: Perf.Resolution.allCases)
    @MainActor
    func renderThroughput(_ r: Perf.Resolution) async throws {
        let (renderer, editRate) = try Self.renderer(r)
        let size = CGSize(width: r.size.w, height: r.size.h)
        let ticksPerFrame = editRate / Int64(Perf.fps)
        _ = try await renderer.image(at: 0, size: size)  // warm up: pipelines, sources
        let clock = ContinuousClock()
        let n = 60
        let sequential = try await clock.measure {
            for i in 1...n { _ = try await renderer.image(at: Int64(i) * ticksPerFrame, size: size) }
        }
        // Same frame again and again: decode is a cache hit, so this is composite + readback.
        let repeated = try await clock.measure {
            for _ in 0..<n { _ = try await renderer.image(at: 30 * ticksPerFrame, size: size) }
        }
        Perf.report(String(format: "render %@ 3 layers: sequential %.1f fps, cached-frame %.1f fps (%.2f ms/frame)",
                           r.rawValue, Double(n) / sequential.seconds, Double(n) / repeated.seconds,
                           repeated.seconds / Double(n) * 1000))
        #expect(sequential > .zero)
    }

    /// The playback path's GPU cost: `Compositor.encode` of the 3-layer plan into a
    /// canvas-size texture (what `CanvasRenderer` draws per display frame), frames already
    /// decoded, timed with command-buffer GPU timestamps. No readback.
    @Test("playback composite GPU time", arguments: Perf.Resolution.allCases)
    @MainActor
    func playbackCompositeGPU(_ r: Perf.Resolution) async throws {
        let (scene, editRate) = try Self.scene(r)
        let pool = MediaPool()
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
        let compositor = try Compositor(device: device)
        let plan = scene.evaluate(at: 30 * (editRate / Int64(Perf.fps)))
        var frames: [FrameRequest: VideoFrame] = [:]
        for req in plan.frameRequests { frames[req] = try await pool.frame(req) }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: r.size.w, height: r.size.h,
                                                         mipmapped: false)
        d.usage = [.renderTarget, .shaderRead, .shaderWrite]
        d.storageMode = .private
        let target = try #require(device.makeTexture(descriptor: d))
        func once() throws -> (gpu: Double, wall: Double) {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let cb = try #require(queue.makeCommandBuffer())
            try compositor.encode(plan, frames: frames, into: target, commandBuffer: cb)
            try GPUWait.commitAndWait(cb, "composite frame")
            return ((cb.gpuEndTime - cb.gpuStartTime) * 1000, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        for _ in 0..<5 { _ = try once() } // warm: pipelines, texture pool, image cache
        let n = 60
        var gpu: [Double] = [], wall: [Double] = []
        for _ in 0..<n { let t = try once(); gpu.append(t.gpu); wall.append(t.wall) }
        gpu.sort(); wall.sort()
        Perf.report(String(format: "playback composite %@ 3 layers: GPU median %.2f ms (p95 %.2f), encode+GPU wall median %.2f ms, load %.1f",
                           r.rawValue, gpu[n / 2], gpu[n * 95 / 100], wall[n / 2], LoadGate.loadAverage))
        if Perf.enforce {
            LoadGate.expect(wall[n / 2] < 16.7,
                            String(format: "60 fps playback: composite %@ median %.2f ms ≥ 16.7 ms", r.rawValue, wall[n / 2]))
        }
    }

    static let demoProject = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/demo project.cmproj")

    /// The user's demo project (read-only): shader background, tscc2 screen recording and
    /// camera in a group. Skips when the project is not on this machine.
    @Test("render throughput, demo project",
          .enabled(if: FileManager.default.fileExists(atPath: demoProject.path), "demo project not on this machine"))
    @MainActor
    func demoProjectThroughput() async throws {
        let bundle = try ProjectBundle(url: Self.demoProject)
        let scene = SceneModel(project: bundle.project, resolve: bundle.resolve)
        let renderer = OfflineRenderer(scene: scene, pool: MediaPool())
        let fps = Int64(bundle.project.frameRate.double.rounded())
        let ticksPerFrame = bundle.project.timebase.editRate / max(fps, 1)
        let size = CGSize(width: 1920, height: 1080)
        let clock = ContinuousClock()
        let evalN = 1000
        let evalTime = clock.measure {
            for i in 0..<evalN { _ = scene.evaluate(at: Int64(i % 700) * ticksPerFrame) }
        }
        _ = try await renderer.image(at: 0, size: size)
        let n = 90
        let start = 30 * ticksPerFrame  // from 1 s in, 3 s of playback
        let elapsed = try await clock.measure {
            for i in 0..<n { _ = try await renderer.image(at: start + Int64(i) * ticksPerFrame, size: size) }
        }
        Perf.report(String(format: "demo project 1080p: evaluate %.3f ms, render sequential %.1f fps (%d frames in %.2f s)",
                           evalTime.seconds / Double(evalN) * 1000, Double(n) / elapsed.seconds, n, elapsed.seconds))
        if Perf.enforce {
            let ms = evalTime.seconds / Double(evalN) * 1000
            LoadGate.expect(ms < 0.5, String(format: "contract: evaluate < 0.5 ms, got %.3f ms", ms))
        }
    }
    }
}

extension Duration {
    /// Seconds as a Double.
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) * 1e-18
    }
}
