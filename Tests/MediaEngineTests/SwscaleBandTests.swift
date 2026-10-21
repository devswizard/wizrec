// Parallel row-band swscale conversion must produce the same bytes as one pass.

import CFFmpeg
import CoreVideo
import Foundation
import Testing
@testable import MediaEngine

@Suite struct SwscaleBandTests {
    struct Case: Sendable, CustomStringConvertible {
        let format: AVPixelFormat
        let width: Int
        let height: Int
        var description: String { "\(String(cString: av_get_pix_fmt_name(format))) \(width)x\(height)" }
    }

    static let cases: [Case] = [
        Case(format: AV_PIX_FMT_YUVA444P12LE, width: 1920, height: 1080), // ProRes 4444
        Case(format: AV_PIX_FMT_YUV444P12LE, width: 1280, height: 723),   // odd height, last band short
        Case(format: AV_PIX_FMT_YUV422P12LE, width: 1922, height: 1088),  // horizontal subsampling only
        Case(format: AV_PIX_FMT_YUV444P16LE, width: 1280, height: 720),
        Case(format: AV_PIX_FMT_GBRP10LE, width: 1280, height: 720),
        Case(format: AV_PIX_FMT_YUVA444P, width: 1280, height: 720),
    ]

    /// A frame of pseudo-random samples (full code range, incl. extremes) with smooth regions.
    static func makeFrame(_ c: Case) throws -> UnsafeMutablePointer<AVFrame> {
        let f = try #require(av_frame_alloc())
        f.pointee.width = Int32(c.width); f.pointee.height = Int32(c.height); f.pointee.format = c.format.rawValue
        f.pointee.colorspace = AVCOL_SPC_BT709
        f.pointee.color_range = AVCOL_RANGE_MPEG
        #expect(av_frame_get_buffer(f, 0) >= 0)
        let desc = try #require(av_pix_fmt_desc_get(c.format))
        let depth = Int(desc.pointee.comp.0.depth)
        let wide = depth > 8
        let maxCode = (1 << depth) - 1
        var rng = UInt64(0x9E37_79B9_7F4A_7C15)
        let planes = Int(av_pix_fmt_count_planes(c.format))
        let d = f.pointee.data, l = f.pointee.linesize
        let bases = [d.0, d.1, d.2, d.3], strides = [l.0, l.1, l.2, l.3]
        for p in 0..<planes {
            let base = try #require(bases[p])
            let pw = (p == 1 || p == 2) ? -((-c.width) >> Int(desc.pointee.log2_chroma_w)) : c.width
            for y in 0..<c.height {
                let row = base + y * Int(strides[p])
                for x in 0..<pw {
                    rng = rng &* 6364136223846793005 &+ 1442695040888963407
                    // Half random noise, half a gradient (exercises the dither on smooth areas).
                    let v = x < pw / 2 ? Int(rng >> 33) % (maxCode + 1) : (x * 7 + y * 3 + p * 101) % (maxCode + 1)
                    if wide {
                        UnsafeMutableRawPointer(row).storeBytes(of: UInt16(v), toByteOffset: 2 * x, as: UInt16.self)
                    } else {
                        row[x] = UInt8(v)
                    }
                }
            }
        }
        return f
    }

    static func bytes(_ b: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let h = CVPixelBufferGetHeight(b), w = CVPixelBufferGetWidth(b), rb = CVPixelBufferGetBytesPerRow(b)
        guard let base = CVPixelBufferGetBaseAddress(b) else { return [] }
        var out = [UInt8](); out.reserveCapacity(w * h * 4)
        for y in 0..<h { out += UnsafeRawBufferPointer(start: base + y * rb, count: w * 4) }
        return out
    }

    @Test(arguments: cases)
    func bandedEqualsOnePass(_ c: Case) throws {
        var f: UnsafeMutablePointer<AVFrame>? = try Self.makeFrame(c)
        defer { av_frame_free(&f) }
        let frame = try #require(f)
        #expect(FrameConverter.swsBands(format: c.format.rawValue, width: c.width, height: c.height, cores: 8) != nil)
        let one = FrameConverter(codec: AV_CODEC_ID_PRORES)
        one.swsBanding = false
        let banded = FrameConverter(codec: AV_CODEC_ID_PRORES)
        banded.swsBanding = true
        let a = Self.bytes(try one.convert(frame))
        let b = Self.bytes(try banded.convert(frame))
        #expect(a.count == c.width * c.height * 4)
        let diff = Synth.differingBytes(a, b)
        #expect(diff == 0, "\(diff) bytes differ")
        // Twice in a row reuses the band contexts.
        #expect(Synth.differingBytes(Self.bytes(try banded.convert(frame)), a) == 0)
    }

    /// HDR pictures with no bi-planar equivalent are resampled to 4:4:4 10-bit before tone
    /// mapping; the banded resample gives the same tone-mapped bytes.
    @Test(arguments: [AV_PIX_FMT_YUVA444P12LE, AV_PIX_FMT_YUV422P12LE])
    func hdrResampleBandedEqualsOnePass(_ format: AVPixelFormat) throws {
        let c = Case(format: format, width: 1280, height: 723)
        var f: UnsafeMutablePointer<AVFrame>? = try Self.makeFrame(c)
        defer { av_frame_free(&f) }
        let frame = try #require(f)
        var par: UnsafeMutablePointer<AVCodecParameters>? = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&par) }
        let p = try #require(par)
        p.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        p.pointee.codec_id = AV_CODEC_ID_PRORES
        p.pointee.format = format.rawValue
        p.pointee.width = Int32(c.width); p.pointee.height = Int32(c.height)
        p.pointee.color_trc = AVCOL_TRC_SMPTE2084
        p.pointee.color_space = AVCOL_SPC_BT2020_NCL
        p.pointee.color_primaries = AVCOL_PRI_BT2020
        let one = FrameConverter(par: p), banded = FrameConverter(par: p)
        #expect(one.isHDR)
        one.swsBanding = false
        banded.swsBanding = true
        let a = Self.bytes(try one.convert(frame))
        let b = Self.bytes(try banded.convert(frame))
        #expect(a.count == c.width * c.height * 4)
        #expect(Synth.differingBytes(a, b) == 0)
    }

    @Test func bandsCoverRowsOnDitherPeriod() throws {
        for h in [720, 723, 1080, 2160, 4320] {
            let bands = try #require(FrameConverter.swsBands(format: AV_PIX_FMT_YUVA444P12LE.rawValue, width: 3840, height: h, cores: 11))
            #expect(bands.first?.lowerBound == 0 && bands.last?.upperBound == h)
            for (a, b) in zip(bands, bands.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
            #expect(bands.allSatisfy { $0.lowerBound % 8 == 0 })
        }
        // Vertically subsampled formats convert in one pass.
        #expect(FrameConverter.swsBands(format: AV_PIX_FMT_YUV420P12LE.rawValue, width: 3840, height: 2160, cores: 8) == nil)
        #expect(FrameConverter.swsBands(format: AV_PIX_FMT_YUVA444P12LE.rawValue, width: 320, height: 180, cores: 8) == nil)
    }
}
