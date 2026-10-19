import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import MediaEngine

private func secs(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600_000) }

@Suite struct MediaPoolTests {
    @Test func requestsInsideOneFrameShareAnEntry() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("m.mp4")
        try await Synth.writeMovie(to: url, times: [0, 0.5, 1.0, 2.0])
        let pool = MediaPool()
        let a = try await pool.frame(FrameRequest(url: url, stream: 0, time: secs(0.6)))
        let b = try await pool.frame(FrameRequest(url: url, stream: 0, time: secs(0.99)))
        let c = try await pool.frame(FrameRequest(url: url, stream: 0, time: secs(0.5)))
        #expect(a.pixelBuffer === b.pixelBuffer)
        #expect(a.pixelBuffer === c.pixelBuffer)
        #expect(await pool.cachedFrameCount == 1)
        let d = try await pool.frame(FrameRequest(url: url, stream: 0, time: secs(1.0)))
        #expect(d.pixelBuffer !== a.pixelBuffer)
        #expect(Synth.index(of: d.pixelBuffer) == 2)
        // Last frame covers everything after it, and negative times clamp to the first.
        let e = try await pool.frame(FrameRequest(url: url, stream: 0, time: secs(50)))
        let f = try await pool.frame(FrameRequest(url: url, stream: 0, time: secs(3)))
        #expect(e.pixelBuffer === f.pixelBuffer)
        #expect(Synth.index(of: e.pixelBuffer) == 3)
        let g = try await pool.frame(FrameRequest(url: url, stream: 0, time: secs(-1)))
        #expect(Synth.index(of: g.pixelBuffer) == 0)
        #expect(await pool.cachedFrameCount == 4)
    }

    @Test func lruEvictsWithinBudget() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("m.mp4")
        try await Synth.writeMovie(to: url, times: (0..<30).map { Double($0) / 30 })
        let frameBytes = 320 * 64 * 4
        let pool = MediaPool(cacheLimitBytes: frameBytes * 5 + frameBytes / 2)
        for i in 0..<30 {
            _ = try await pool.frame(FrameRequest(url: url, stream: 0, time: secs(Double(i) / 30)))
            #expect(await pool.cachedBytes <= pool.cacheLimitBytes)
        }
        #expect(await pool.cachedFrameCount == 5)
        // Recently used frames survive; touching frame 25 keeps it over 26..29 + new ones.
        let keep = try await pool.frame(FrameRequest(url: url, stream: 0, time: secs(25.0 / 30)))
        _ = try await pool.frame(FrameRequest(url: url, stream: 0, time: secs(0)))
        let again = try await pool.frame(FrameRequest(url: url, stream: 0, time: secs(25.0 / 30)))
        #expect(keep.pixelBuffer === again.pixelBuffer)
    }

    @Test func prefetchFillsCache() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("m.mp4")
        try await Synth.writeMovie(to: url, times: (0..<60).map { Double($0) / 30 })
        let pool = MediaPool()
        let reqs = (10..<40).map { FrameRequest(url: url, stream: 0, time: secs((Double($0) + 0.5) / 30)) }
        await pool.prefetch(reqs)
        // Wait (bounded) until pre-roll lands in the cache.
        for _ in 0..<500 where await pool.cachedFrameCount < 30 { try await Task.sleep(nanoseconds: 5_000_000) }
        let prefetched = await pool.cachedFrameCount
        let intervals = await pool.cachedIntervals(url: url, stream: 0)
        #expect(prefetched == 30, "\(intervals)")
        for (i, r) in reqs.enumerated() {
            #expect(Synth.index(of: try await pool.frame(r).pixelBuffer) == i + 10)
        }
        #expect(await pool.cachedFrameCount == 30)
        await pool.purge()
        #expect(await pool.cachedFrameCount == 0)
    }

    /// A new prefetch batch replaces the stream's unstarted requests instead of interleaving.
    @Test func newPrefetchBatchReplacesOld() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("m.mp4")
        try await Synth.writeMovie(to: url, times: (0..<90).map { Double($0) / 30 })
        let pool = MediaPool()
        func reqs(_ r: Range<Int>) -> [FrameRequest] {
            r.map { FrameRequest(url: url, stream: 0, time: secs((Double($0) + 0.5) / 30)) }
        }
        await pool.prefetch(reqs(0..<60))
        await pool.prefetch(reqs(60..<70))
        for _ in 0..<500 where await pool.isPrefetching { try await Task.sleep(nanoseconds: 5_000_000) }
        let starts = await pool.cachedIntervals(url: url, stream: 0).map { Int(($0.start.seconds * 30).rounded()) }
        #expect(Set(60..<70).isSubset(of: Set(starts)))
        #expect(starts.count < 30, "old batch should have been dropped, cached \(starts.count)")
        for (i, r) in reqs(60..<70).enumerated() {
            #expect(Synth.index(of: try await pool.frame(r).pixelBuffer) == 60 + i)
        }
    }

    @Test func sameSourceReused() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("m.mp4")
        try await Synth.writeMovie(to: url, times: [0])
        let pool = MediaPool()
        async let a = pool.source(for: url)
        async let b = pool.source(for: url)
        let (sa, sb) = try await (a, b)
        #expect(sa === sb)
    }
}

/// Throughput targets from CONTRACTS.md. Opt-in (`WIZREC_PERF=1`) so shared CI runners don't flake;
/// run with `-c release` for representative numbers.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WIZREC_PERF"] == "1" && Synth.ffmpegPath != nil,
                "set WIZREC_PERF=1 (needs ffmpeg)"),
       .serialized)
struct DecodePerfTests {
    /// A 10 s test-card clip.
    struct Clip: Sendable, CustomStringConvertible {
        let name: String
        let size: String
        let fps: Int
        let codecArgs: [String]
        /// Contract applies (1080p h264); others are reported only.
        let enforced: Bool
        var description: String { name }
    }

    static let clips: [Clip] = [
        Clip(name: "1080p60 h264 GOP60 B2", size: "1920x1080", fps: 60,
             codecArgs: ["-c:v", "libx264", "-preset", "veryfast", "-g", "60", "-bf", "2"], enforced: true),
        Clip(name: "1080p30 h264 GOP30 noB", size: "1920x1080", fps: 30,
             codecArgs: ["-c:v", "libx264", "-preset", "veryfast", "-g", "30", "-bf", "0"], enforced: true),
        Clip(name: "1080p60 hevc GOP60", size: "1920x1080", fps: 60,
             codecArgs: ["-c:v", "libx265", "-preset", "veryfast", "-x265-params", "keyint=60:log-level=none", "-tag:v", "hvc1"], enforced: false),
        Clip(name: "2160p30 h264 GOP30", size: "3840x2160", fps: 30,
             codecArgs: ["-c:v", "libx264", "-preset", "ultrafast", "-g", "30"], enforced: false),
    ]

    static func makeClip(_ dir: URL, _ clip: Clip = clips[0]) throws -> URL {
        let url = dir.appendingPathComponent("perf.mp4")
        try Synth.ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=\(clip.size):rate=\(clip.fps)", "-t", "10"]
                         + clip.codecArgs + ["-pix_fmt", "yuv420p", url.path])
        return url
    }

    /// The user's 2688×1512 10-bit HEVC camera footage (local only): cold seek, playback, scrub.
    @Test(.enabled(if: Vlog.sample != nil)) func djiFootage() async throws {
        let url = try #require(Vlog.sample)
        let pool = MediaPool(cacheLimitBytes: 1)
        let src = try await pool.source(for: url)
        let dur = src.info.streams[0].duration.seconds
        var s = Date()
        _ = try await src.frame(stream: 0, at: CMTime(seconds: min(22.28, dur * 0.8), preferredTimescale: 600))
        let cold = Date().timeIntervalSince(s) * 1000
        let start = min(22.3, dur * 0.8)
        s = Date()
        for i in 0..<240 { _ = try await src.frame(stream: 0, at: CMTime(seconds: start + Double(i) * 1001 / 60000, preferredTimescale: 60000)) }
        let fps = 240 / Date().timeIntervalSince(s)
        var lat: [Double] = []
        for _ in 0..<20 {
            let t = Double.random(in: 0..<(dur - 1))
            s = Date()
            _ = try await src.frame(stream: 0, at: CMTime(seconds: t, preferredTimescale: 600))
            lat.append(Date().timeIntervalSince(s) * 1000)
        }
        let lanes = try await (src as? FFMediaSource)?.laneCounts(stream: 0)
        print("PERF DJI 2688x1512 hevc10: cold seek \(Int(cold)) ms, sequential \(Int(fps)) fps, random seek mean \(Int(lat.reduce(0, +) / Double(lat.count))) ms max \(Int(lat.max() ?? 0)) ms, lanes \(String(describing: lanes))")
    }

    @Test(arguments: clips)
    func sequentialAndRandomSeek(clip: Clip) async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Self.makeClip(dir, clip)
        let src = try await MediaPool().source(for: url)
        _ = try await src.frame(stream: 0, at: .zero)

        let n = clip.fps * 10
        let t0 = Date()
        for i in 0..<n { _ = try await src.frame(stream: 0, at: CMTime(value: Int64(i), timescale: Int32(clip.fps))) }
        let fps = Double(n) / Date().timeIntervalSince(t0)

        var rng = SystemRandomNumberGenerator()
        var lat: [Double] = []
        for _ in 0..<40 {
            let t = Double.random(in: 0..<10, using: &rng)
            let s = Date()
            _ = try await src.frame(stream: 0, at: CMTime(seconds: t, preferredTimescale: 600))
            lat.append(Date().timeIntervalSince(s) * 1000)
        }
        let mean = lat.reduce(0, +) / Double(lat.count)
        let hw = try await (src as? FFMediaSource)?.isHardwareAccelerated(stream: 0) ?? false
        print("PERF \(clip.name) (\(hw ? "VideoToolbox" : "software")): sequential \(Int(fps)) fps, random seek mean \(String(format: "%.1f", mean)) ms, max \(String(format: "%.1f", lat.max() ?? 0)) ms")
        if clip.enforced {
            #expect(fps >= 120)
            #expect(mean <= 50)
        }
    }
}
