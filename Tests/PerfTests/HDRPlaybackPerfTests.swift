import CoreMedia
import CoreVideo
import Foundation
import MediaEngine
import Testing
import WizRecTestSupport

/// 4K60 HDR playback: sequential decode + tone map through `MediaPool`, CPU reference vs
/// Metal (`HDRToneMapping.gpu`). Release builds enforce ≥ 60 fps for `.gpu` (LoadGate).
/// ```
/// WIZREC_PERF=1 swift test -c release -Xswiftc -enable-testing --filter HDRPlaybackPerf
/// ```
@Suite(.enabled(if: Perf.enabled && HDRMovie.ffmpeg != nil, "set WIZREC_PERF=1 (needs ffmpeg)"), .serialized)
struct HDRPlaybackPerfTests {
    @Test("4K60 HDR decode + tone map", arguments: ["smpte2084", "arib-std-b67"])
    func uhd60(_ trc: String) async throws {
        let url = try HDRMovie.make(trc: trc)
        let n = 120
        var fps: [HDRToneMapping: Double] = [:]
        var firstFrames: [HDRToneMapping: CVPixelBuffer] = [:]
        for mode in [HDRToneMapping.cpu, .gpu] {
            let pool = MediaPool(cacheLimitBytes: 1, diskCacheDirectory: nil, hdrToneMapping: mode) // every request decodes
            _ = try await pool.source(for: url)
            let first = try await pool.frame(FrameRequest(url: url, stream: 0, time: .zero)) // warm: decoder, Metal
            firstFrames[mode] = first.pixelBuffer
            let clock = ContinuousClock()
            let elapsed = try await clock.measure {
                for i in 1...n {
                    _ = try await pool.frame(FrameRequest(url: url, stream: 0, time: CMTime(value: CMTimeValue(i), timescale: 60)))
                }
            }
            fps[mode] = Double(n) / elapsed.seconds
        }
        let cpu = fps[.cpu] ?? 0, gpu = fps[.gpu] ?? 0
        let (maxDiff, exact) = Self.compare(try #require(firstFrames[.cpu]), try #require(firstFrames[.gpu]))
        Perf.report(String(format: "HDR 4K60 %@ decode+tone map: cpu %.1f fps, gpu %.1f fps; frame 0 max |Δ| %d, exact %.3f %%; load %.1f",
                           trc, cpu, gpu, maxDiff, exact * 100, LoadGate.loadAverage))
        #expect(maxDiff <= 1)
        if Perf.enforce { LoadGate.expect(gpu >= 60, String(format: "4K60 HDR playback: gpu %.1f fps < 60", gpu)) }
    }

    /// (max |Δ|, fraction identical) over B, G, R of two same-size BGRA buffers.
    static func compare(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> (Int, Double) {
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        guard let pa = CVPixelBufferGetBaseAddress(a), let pb = CVPixelBufferGetBaseAddress(b),
              CVPixelBufferGetWidth(a) == CVPixelBufferGetWidth(b), CVPixelBufferGetHeight(a) == CVPixelBufferGetHeight(b)
        else { return (255, 0) }
        let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
        let ra = CVPixelBufferGetBytesPerRow(a), rb = CVPixelBufferGetBytesPerRow(b)
        var m = 0, same = 0
        for y in 0..<h {
            let p = (pa + y * ra).assumingMemoryBound(to: UInt8.self), q = (pb + y * rb).assumingMemoryBound(to: UInt8.self)
            for i in 0..<(w * 4) where i % 4 != 3 {
                let d = abs(Int(p[i]) - Int(q[i]))
                m = max(m, d)
                if d == 0 { same += 1 }
            }
        }
        return (m, Double(same) / Double(w * h * 3))
    }
}

/// A synthesised 4K60 10-bit HEVC test movie tagged HDR (BT.2020, PQ or HLG), cached in tmp.
enum HDRMovie {
    static var ffmpeg: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func make(trc: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-perf", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("hdr-4k60-\(trc).mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let path = ffmpeg else { throw MediaError.unsupported("ffmpeg missing") }
        let tmp = dir.appendingPathComponent("tmp-\(UUID().uuidString).mp4")
        let args: [String] = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                              "-f", "lavfi", "-i", "testsrc2=size=3840x2160:rate=60", "-frames:v", "125", "-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-b:v", "40M",
                              "-tag:v", "hvc1", "-pix_fmt", "p010le",
                              "-vf", "setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=\(trc)",
                              "-color_primaries", "bt2020", "-color_trc", trc, "-colorspace", "bt2020nc", tmp.path]
        let r = try TestProcess.run(path, args, seconds: 300)
        guard r.status == 0 else { throw MediaError.decodeFailed("ffmpeg exit \(r.status): \(r.stderrText)") }
        try? FileManager.default.moveItem(at: tmp, to: url)
        return url
    }
}
