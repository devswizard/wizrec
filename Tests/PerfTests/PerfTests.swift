import CoreGraphics
import CoreMedia
import Foundation
import MediaEngine
import RenderEngine
import TestGenKit
import Testing
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
        if r == .hd1080 && Perf.enforce { #expect(fps >= 120, "contract: 1080p h264 sequential decode ≥ 120 fps") }
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
        if r == .hd1080 && Perf.enforce { #expect(mean <= 50, "contract: random seek ≤ 50 ms") }
    }
    }

    @Suite struct Composite {
    /// Three layers at canvas resolution: full-frame clip, the same clip at half size and
    /// 70 % opacity, rotated; and a still card. Measures evaluate → decode → composite → CGImage.
    @MainActor
    static func renderer(_ r: Perf.Resolution) throws -> (OfflineRenderer, Int64) {
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
        return (OfflineRenderer(scene: scene, pool: MediaPool()), bundle.project.timebase.editRate)
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
        if Perf.enforce { #expect(evalTime.seconds / Double(evalN) < 0.5e-3, "contract: evaluate < 0.5 ms") }
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
