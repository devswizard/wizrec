// Decoded pixels are a pure function of (source, frame): the VideoToolbox lane and the
// software lane of a stream return byte-identical BGRA, so seeks, lane switches and
// decode history never change a frame.

import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import MediaEngine

/// Visible BGRA bytes of a 32BGRA buffer (row padding dropped).
private func bgra(_ pb: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return [] }
    let rb = CVPixelBufferGetBytesPerRow(pb), w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    var out: [UInt8] = []
    out.reserveCapacity(w * h * 4)
    for y in 0..<h { out.append(contentsOf: UnsafeRawBufferPointer(start: base + y * rb, count: w * 4)) }
    return out
}

/// Pixels that differ and the largest channel difference.
private func diff(_ a: [UInt8], _ b: [UInt8]) -> (pixels: Int, maxDelta: Int) {
    guard a.count == b.count else { return (Int.max, 255) }
    // Fast path (QA11-2): identical buffers need no per-pixel loop, which is slow in debug builds.
    let same = a.withUnsafeBytes { (pa: UnsafeRawBufferPointer) -> Bool in
        b.withUnsafeBytes { (pb: UnsafeRawBufferPointer) -> Bool in
            guard let x = pa.baseAddress, let y = pb.baseAddress else { return pa.count == pb.count }
            return memcmp(x, y, pa.count) == 0
        }
    }
    if same { return (0, 0) }
    var px = 0, m = 0
    for i in stride(from: 0, to: a.count, by: 4) {
        var d = 0
        for c in 0..<3 { d = max(d, abs(Int(a[i + c]) - Int(b[i + c]))) }
        if d > 0 { px += 1; m = max(m, d) }
    }
    return (px, m)
}

/// One synthetic stream: name and ffmpeg encoder arguments.
struct LaneCase: CustomTestStringConvertible, Sendable {
    let name: String
    let args: [String]
    var ext = "mp4"
    var testDescription: String { name }

    static let all: [LaneCase] = [
        LaneCase(name: "h264 160x90 untagged", args: [
            "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=30", "-frames:v", "45",
            "-c:v", "libx264", "-g", "30", "-pix_fmt", "yuv420p"]),
        LaneCase(name: "h264 640x360 bt709", args: [
            "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30", "-frames:v", "45",
            "-c:v", "libx264", "-g", "30", "-pix_fmt", "yuv420p", "-color_range", "tv",
            "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"]),
        LaneCase(name: "h264 1280x720 full range", args: [
            "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30", "-frames:v", "20",
            "-c:v", "libx264", "-g", "30", "-pix_fmt", "yuvj420p", "-color_range", "pc"]),
        LaneCase(name: "hevc 10-bit 320x180", args: [
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30", "-frames:v", "30",
            "-c:v", "libx265", "-x265-params", "log-level=error", "-tag:v", "hvc1", "-pix_fmt", "yuv420p10le",
            "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"]),
        LaneCase(name: "hevc 10-bit 320x180 HDR10 PQ", args: [
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30", "-frames:v", "30",
            "-c:v", "libx265", "-x265-params", "log-level=error", "-tag:v", "hvc1", "-pix_fmt", "yuv420p10le",
            "-vf", "setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=smpte2084"]),
        LaneCase(name: "hevc 10-bit 320x180 HLG", args: [
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30", "-frames:v", "30",
            "-c:v", "libx265", "-x265-params", "log-level=error", "-tag:v", "hvc1", "-pix_fmt", "yuv420p10le",
            "-vf", "setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=arib-std-b67"]),
        LaneCase(name: "hevc 12-bit 320x180 HDR10 PQ", args: [
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30", "-frames:v", "20",
            "-c:v", "libx265", "-x265-params", "log-level=error", "-tag:v", "hvc1", "-pix_fmt", "yuv420p12le",
            "-vf", "setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=smpte2084"]),
        LaneCase(name: "prores 422 10-bit 320x180 HDR10 PQ", args: [
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30", "-frames:v", "20",
            "-c:v", "prores_ks", "-profile:v", "2", "-pix_fmt", "yuv422p10le",
            "-vf", "setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=smpte2084"], ext: "mov"),
    ]
}

@Suite(.serialized, .enabled(if: Synth.ffmpegPath != nil, "needs ffmpeg"))
struct LaneParityTests {
    private func make(_ c: LaneCase, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("lane.\(c.ext)")
        try Synth.ffmpeg(c.args + [url.path])
        return url
    }

    /// Every frame decoded on the VideoToolbox lane equals the software lane's, byte for byte.
    @Test(arguments: LaneCase.all)
    func hardwareAndSoftwareLanesAreIdentical(_ c: LaneCase) async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try make(c, in: dir)
        let hw = try VideoDecoder(url: url, streamIndex: 0, allowHardware: true)
        let sw = try VideoDecoder(url: url, streamIndex: 0, allowHardware: false)
        guard hw.isHardwareCapable else { return } // no hardware decoder for this codec here
        var frames = 0
        var t = CMTime.zero
        while true {
            let a = try await hw.frame(at: t), b = try await sw.frame(at: t)
            #expect(a.presentationTime == b.presentationTime)
            let d = diff(bgra(a.pixelBuffer), bgra(b.pixelBuffer))
            #expect(d.pixels == 0, "\(c.name) frame \(frames): \(d.pixels) px differ, max Δ \(d.maxDelta)")
            frames += 1
            guard a.duration.isValid else { break }
            t = a.presentationTime + a.duration
        }
        #expect(frames > 10)
        #expect(await hw.isHardwareAccelerated) // the hardware lane really ran in hardware
    }

    /// Frame N reached by a seek on a fresh stream decoder equals frame N decoded forward,
    /// whatever lane serves it.
    @Test func seekEqualsSequentialThroughStreamDecoder() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try make(LaneCase.all[0], in: dir)
        let seq = try VideoStreamDecoder(url: url, streamIndex: 0)
        var sequential: [[UInt8]] = []
        for n in 0..<45 { sequential.append(bgra(try await seq.frame(at: CMTime(value: Int64(n), timescale: 30)).pixelBuffer)) }
        var differing: [Int] = []
        for n in 0..<45 {
            let fresh = try VideoStreamDecoder(url: url, streamIndex: 0)
            let f = bgra(try await fresh.frame(at: CMTime(value: Int64(n), timescale: 30)).pixelBuffer)
            if f != sequential[n] { differing.append(n) }
        }
        // Backward seeks on one decoder, too.
        for n in stride(from: 44, through: 0, by: -3) {
            let f = bgra(try await seq.frame(at: CMTime(value: Int64(n), timescale: 30)).pixelBuffer)
            if f != sequential[n] { differing.append(n) }
        }
        #expect(differing.isEmpty, "seek vs sequential differs at frames \(differing)")
    }
}
