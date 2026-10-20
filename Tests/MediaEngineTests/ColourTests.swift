import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import MediaEngine

/// ffmpeg's own RGB rendering of the frame presented at `seconds` (an exact frame PTS).
private func ffmpegRGB(_ url: URL, videoStream: Int, seconds: Double, dir: URL) throws -> [UInt8] {
    let out = dir.appendingPathComponent("ref-\(videoStream)-\(seconds).raw")
    try Synth.ffmpeg(["-ss", String(format: "%.6f", seconds), "-i", url.path, "-map", "0:v:\(videoStream)",
                      "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", out.path])
    return [UInt8](try Data(contentsOf: out))
}

/// Mean absolute error per channel between our BGRA frame and an RGB24 reference, plus the
/// number of distinct green levels in each (a posterization check).
private func compare(_ buf: CVPixelBuffer, _ rgb: [UInt8]) -> (mae: Double, ourLevels: Int, refLevels: Int) {
    CVPixelBufferLockBaseAddress(buf, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buf) else { return (255, 0, 0) }
    let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf), bpr = CVPixelBufferGetBytesPerRow(buf)
    guard rgb.count == w * h * 3 else { return (255, 0, 0) }
    let p = base.assumingMemoryBound(to: UInt8.self)
    var sum = 0.0, n = 0
    var ours = Set<UInt8>(), refs = Set<UInt8>()
    for y in stride(from: 0, to: h, by: 2) {
        for x in stride(from: 0, to: w, by: 2) {
            let o = y * bpr + x * 4, r = (y * w + x) * 3
            sum += Double(abs(Int(p[o + 2]) - Int(rgb[r]))) + Double(abs(Int(p[o + 1]) - Int(rgb[r + 1])))
                + Double(abs(Int(p[o]) - Int(rgb[r + 2])))
            n += 3
            ours.insert(p[o + 1]); refs.insert(rgb[r + 1])
        }
    }
    return (sum / Double(n), ours.count, refs.count)
}

@Suite(.enabled(if: Synth.ffmpegPath != nil, "needs ffmpeg"))
struct ColourTests {
    /// Software (swscale) and VideoToolbox lanes both match ffmpeg's conversion of a
    /// tagged bt709 stream.
    @Test(arguments: [false, true])
    func taggedBT709MatchesFFmpeg(hardware: Bool) async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("c.mp4")
        try Synth.ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30", "-t", "2",
                          "-c:v", "libx264", "-pix_fmt", "yuv420p", "-color_range", "tv",
                          "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", url.path])
        let dec = try VideoDecoder(url: url, streamIndex: 0, allowHardware: hardware)
        let f = try await dec.frame(at: CMTime(value: 1, timescale: 1))
        let ref = try ffmpegRGB(url, videoStream: 0, seconds: 1, dir: dir)
        let c = compare(f.pixelBuffer, ref)
        let hw = await dec.isHardwareAccelerated
        // < 2.5: the reference is whatever FFmpeg build is installed (2.12 with the CI runner's Homebrew build).
        #expect(c.mae < 2.5, "mean abs error \(c.mae) (hardware: \(hw))")
    }

    /// The user's DJI footage (10-bit HEVC bt709): no posterization vs ffmpeg. Local only.
    @Test(.enabled(if: Vlog.sample != nil, "vlog project not installed"), arguments: [false, true])
    func djiTenBitMatchesFFmpeg(hardware: Bool) async throws {
        let url = try #require(Vlog.sample)
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = 1001.0 * 150 / 60000 // frame 150
        let dec = try VideoDecoder(url: url, streamIndex: 0, allowHardware: hardware)
        let f = try await dec.frame(at: CMTime(value: 1001 * 150, timescale: 60000))
        let ref = try ffmpegRGB(url, videoStream: 0, seconds: t, dir: dir)
        let c = compare(f.pixelBuffer, ref)
        print("COLOUR DJI hw=\(await dec.isHardwareAccelerated): mae \(c.mae), green levels ours \(c.ourLevels) ffmpeg \(c.refLevels)")
        #expect(c.mae < 2.5)
        #expect(Double(c.ourLevels) > 0.8 * Double(c.refLevels))
    }
}

/// One camera file of the user's vlog project (read-only), if installed.
enum Vlog {
    static let sample: URL? = {
        let media = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/Moheshkali Dwip Vlog.cmproj/media")
        guard let e = FileManager.default.enumerator(at: media, includingPropertiesForKeys: nil) else { return nil }
        for case let u as URL in e where u.pathExtension.uppercased() == "MP4" { return u }
        return nil
    }()
}
