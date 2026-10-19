// HDR10 (PQ) and HLG sources are tone-mapped to SDR BT.709 BGRA, identically on both lanes.

import CFFmpeg
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import MediaEngine

/// The tone-map curves themselves (no media).
struct ToneCurveTests {
    @Test func pqReferenceWhiteIsOne() {
        // PQ signal of 203 cd/m² is 0.5806 (BT.2408).
        #expect(abs(ToneMapper.linearise(0.5806, .pq) - 1) < 0.01)
        #expect(ToneMapper.linearise(0, .pq) == 0)
        #expect(abs(ToneMapper.linearise(1, .pq) * ToneMapper.referenceWhite - 10000) < 1)
    }

    @Test func hlgSeventyFivePercentIsReferenceWhite() {
        // Grey at HLG 0.75 on a 1000 cd/m² display ≈ 203 cd/m² after the OOTF.
        let e = ToneMapper.linearise(0.75, .hlg)
        let nits = ToneMapper.hlgPeak * powf(e, 0.2) * e
        #expect(abs(nits - 203) < 2)
    }

    @Test func curveIsContinuousMonotoneAndBelowPeak() {
        var prev: Float = -1
        for i in 0...5000 {
            let m = Float(i) / 100
            let f = ToneMapper.curve(m)
            #expect(f >= prev)
            #expect(f <= 1)
            prev = f
        }
        let k = ToneMapper.knee
        #expect(abs(ToneMapper.curve(k + 1e-4) - (k + 1e-4)) < 1e-4) // slope 1 at the knee
        #expect(ToneMapper.curve(0.5) == 0.5)
    }

    @Test func bt709Encoding() {
        #expect(ToneMapper.oetf709(0) == 0)
        #expect(ToneMapper.oetf709(1) == 255)
        #expect(ToneMapper.oetf709(0.18) == 104) // 1.099·0.18^0.45 − 0.099 = 0.409
    }

    @Test func transferDetectionFromTags() {
        #expect(HDRTransfer.of(AVCOL_TRC_SMPTE2084) == .pq)
        #expect(HDRTransfer.of(AVCOL_TRC_ARIB_STD_B67) == .hlg)
        #expect(HDRTransfer.of(AVCOL_TRC_BT709) == nil)
        #expect(HDRTransfer.of(AVCOL_TRC_UNSPECIFIED) == nil)
    }
}

/// Expected SDR code of a neutral grey at normalised signal `e`.
private func expectedGrey(_ e: Float, _ t: HDRTransfer) -> Int {
    var l = ToneMapper.linearise(e, t)
    if t == .hlg { l *= ToneMapper.hlgPeak * powf(l, 0.2) / ToneMapper.referenceWhite }
    return Int(ToneMapper.oetf709(ToneMapper.curve(l)))
}

@Suite(.serialized, .enabled(if: Synth.ffmpegPath != nil, "needs ffmpeg"))
struct HDRDecodeTests {
    /// A lossless 10-bit HEVC of flat grey (8-bit RGB level `level`) tagged with `trc`.
    private func greyMovie(level: Int, trc: String, pixFmt: String = "yuv420p10le", in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("grey-\(trc)-\(pixFmt).mp4")
        let hex = String(format: "0x%02X%02X%02X", level, level, level)
        try Synth.ffmpeg(["-f", "lavfi", "-i", "color=c=\(hex):size=128x72:rate=30", "-frames:v", "5",
                          "-c:v", "libx265", "-x265-params", "log-level=error:lossless=1", "-tag:v", "hvc1",
                          "-pix_fmt", pixFmt, "-vf", "setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=\(trc)",
                          url.path])
        return url
    }

    /// Limited-range 10-bit luma code of an 8-bit full-scale RGB grey, normalised.
    private func signal(_ level: Int) -> Float {
        (Float(64 + Int((Float(level) * 876 / 255).rounded())) - 64) / 876
    }

    private func checkGrey(_ url: URL, level: Int, _ t: HDRTransfer, hardware: Bool) async throws {
        let dec = try VideoDecoder(url: url, streamIndex: 0, allowHardware: hardware)
        let f = try await dec.frame(at: CMTime(value: 2, timescale: 30))
        let p = Synth.pixel(f.pixelBuffer, x: 64, y: 36)
        let want = expectedGrey(signal(level), t)
        #expect(abs(Int(p.r) - want) <= 2 && abs(Int(p.g) - want) <= 2 && abs(Int(p.b) - want) <= 2,
                "\(t) level \(level) hw \(hardware): got \(p.r),\(p.g),\(p.b), want \(want)")
        #expect(p.a == 255)
    }

    /// PQ grey at ≈203 cd/m² (reference white) lands just under SDR peak; ≈100 cd/m² mid-tone.
    @Test(arguments: [false, true])
    func pqGreyIsToneMapped(hardware: Bool) async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for level in [148, 130, 60] {
            try await checkGrey(try greyMovie(level: level, trc: "smpte2084", in: dir), level: level, .pq, hardware: hardware)
        }
        // Sanity on the curve output itself: reference white is bright but not clipped.
        let white = expectedGrey(signal(148), .pq)
        #expect(white > 235 && white < 255)
    }

    @Test(arguments: [false, true])
    func hlgGreyIsToneMapped(hardware: Bool) async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for level in [191, 128, 40] {
            try await checkGrey(try greyMovie(level: level, trc: "arib-std-b67", in: dir), level: level, .hlg, hardware: hardware)
        }
    }

    /// 12-bit HDR has no bi-planar staging format: resampled to 10-bit, then tone-mapped.
    @Test func twelveBitPQ() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try greyMovie(level: 148, trc: "smpte2084", pixFmt: "yuv420p12le", in: dir)
        try await checkGrey(url, level: 148, .pq, hardware: false)
    }

    /// ProRes 4:2:2 10-bit PQ (software lane only: ProRes decoding is not bit-exact across decoders).
    @Test func proresPQ() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("grey.mov")
        try Synth.ffmpeg(["-f", "lavfi", "-i", "color=c=0x949494:size=128x72:rate=30", "-frames:v", "3",
                          "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le",
                          "-vf", "setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=smpte2084", url.path])
        let hw = try VideoDecoder(url: url, streamIndex: 0, allowHardware: true)
        #expect(!hw.isHardwareCapable)
        try await checkGrey(url, level: 148, .pq, hardware: true)
    }

    /// Saturated BT.2020 colours keep their hue and stay in range; thumbnails are tone-mapped too.
    @Test func colourBarsAndThumbnail() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("red.mp4")
        try Synth.ffmpeg(["-f", "lavfi", "-i", "color=c=0xB00000:size=128x72:rate=30", "-frames:v", "3",
                          "-c:v", "libx265", "-x265-params", "log-level=error:lossless=1", "-tag:v", "hvc1",
                          "-pix_fmt", "yuv444p10le",
                          "-vf", "setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=smpte2084", url.path])
        let dec = try VideoDecoder(url: url, streamIndex: 0, allowHardware: false)
        let f = try await dec.frame(at: .zero)
        let p = Synth.pixel(f.pixelBuffer, x: 64, y: 36)
        #expect(p.r > 150 && p.g < 40 && p.b < 40, "red got \(p.r),\(p.g),\(p.b)")

        let core = try VideoDecodeCore(url: url, streamIndex: 0, allowHardware: false)
        let (thumb, _) = try core.thumbnailFrame(at: .zero, exact: true, maxPixelSize: 64)
        #expect(CVPixelBufferGetWidth(thumb) == 64)
        let t = Synth.pixel(thumb, x: 32, y: 18)
        #expect(abs(Int(t.r) - Int(p.r)) <= 1 && abs(Int(t.g) - Int(p.g)) <= 1 && abs(Int(t.b) - Int(p.b)) <= 1)
    }
}
