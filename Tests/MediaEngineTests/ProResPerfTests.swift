// 4K ProRes decode throughput (software lane only since session 4). Opt-in: `WIZREC_PERF=1`,
// release build: `WIZREC_PERF=1 swift test -c release -Xswiftc -enable-testing --filter ProResPerf`.

import CoreMedia
import CoreVideo
import Foundation
import Testing
import WizRecTestSupport
@testable import MediaEngine

@Suite(.enabled(if: ProcessInfo.processInfo.environment["WIZREC_PERF"] == "1" && Synth.ffmpegPath != nil,
                "set WIZREC_PERF=1 (needs ffmpeg)"),
       .serialized)
struct ProResPerfTests {
    /// A synthesized 4K ProRes clip (2 s of test card at 60 fps).
    struct Clip: Sendable, CustomStringConvertible {
        let name: String
        let profile: Int
        let pixFmt: String
        var description: String { name }
    }

    static let clips: [Clip] = [
        Clip(name: "prores422hq", profile: 3, pixFmt: "yuv422p10le"),
        Clip(name: "prores4444", profile: 4, pixFmt: "yuva444p10le"),
    ]

    /// Clips are cached between runs (encoding 4K ProRes takes far longer than decoding it).
    static func clipURL(_ clip: Clip) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-prores-perf")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(clip.name)-2160p60.mov")
        if !FileManager.default.fileExists(atPath: url.path) {
            let tmp = dir.appendingPathComponent("\(clip.name)-tmp.mov")
            try Synth.ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=3840x2160:rate=60", "-t", "2",
                              "-c:v", "prores_ks", "-profile:v", "\(clip.profile)", "-pix_fmt", clip.pixFmt, tmp.path])
            try FileManager.default.moveItem(at: tmp, to: url)
        }
        return url
    }

    static var loadAverage: String {
        var l = [Double](repeating: 0, count: 3)
        _ = getloadavg(&l, 3)
        return l.map { String(format: "%.2f", $0) }.joined(separator: " ")
    }

    /// Sequential playback through `MediaPool` (decode + BGRA conversion), as the player asks.
    @Test(arguments: clips)
    func sequential(clip: Clip) async throws {
        let url = try Self.clipURL(clip)
        let src = try await MediaPool(cacheLimitBytes: 1).source(for: url)
        _ = try await src.frame(stream: 0, at: .zero)
        let n = 119
        var ru0 = rusage(); getrusage(RUSAGE_SELF, &ru0)
        let t0 = DispatchTime.now().uptimeNanoseconds
        for i in 1...n { _ = try await src.frame(stream: 0, at: CMTime(value: Int64(i), timescale: 60)) }
        let secs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        var ru1 = rusage(); getrusage(RUSAGE_SELF, &ru1)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        let cpu = (s(ru1.ru_utime) - s(ru0.ru_utime)) + (s(ru1.ru_stime) - s(ru0.ru_stime))
        let fps = Double(n) / secs
        print("PERF 4K \(clip.name): \(String(format: "%.1f", fps)) fps sequential (\(String(format: "%.1f", secs / Double(n) * 1000)) ms/frame, \(String(format: "%.1f", cpu / secs)) cores busy), load avg \(Self.loadAverage)")
        LoadGate.expect(fps >= 30, "4K30 \(clip.name): ≥ 30 fps, got \(String(format: "%.1f", fps))")
    }

    /// Where the time goes: libav decode only vs the full pipeline, per picture.
    @Test(arguments: clips)
    func decodeVsConvert(clip: Clip) throws {
        let url = try Self.clipURL(clip)
        let core = try VideoDecodeCore(url: url, streamIndex: 0, allowHardware: false)
        _ = try core.frame(at: .zero)
        let n = 60
        let t0 = DispatchTime.now().uptimeNanoseconds
        for i in 1...n { _ = try core.frame(at: CMTime(value: Int64(i), timescale: 60)) }
        let full = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / Double(n)
        print("PERF 4K \(clip.name) core: \(String(format: "%.1f", full)) ms/frame decode+convert, load avg \(Self.loadAverage)")
    }
}
