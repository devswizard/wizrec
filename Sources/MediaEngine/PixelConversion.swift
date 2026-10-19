// Conversion of decoded frames into 32BGRA, IOSurface-backed, Metal-compatible
// CVPixelBuffers drawn from a pool.

import CFFmpeg
import CoreGraphics
import CoreVideo
import Foundation
import VideoToolbox

/// A `CVPixelBufferPool` of BGRA buffers for one frame size. Not thread-safe: owned by one decoder.
final class BGRAPool {
    let width: Int
    let height: Int
    private let pool: CVPixelBufferPool

    init(width: Int, height: Int) throws {
        self.width = width; self.height = height
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var p: CVPixelBufferPool?
        let rc = CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
        guard rc == kCVReturnSuccess, let pool = p else {
            throw MediaError.decodeFailed("CVPixelBufferPoolCreate \(width)x\(height) failed (\(rc))")
        }
        self.pool = pool
    }

    func make() throws -> CVPixelBuffer {
        var b: CVPixelBuffer?
        let rc = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &b)
        guard rc == kCVReturnSuccess, let buf = b else {
            throw MediaError.decodeFailed("CVPixelBufferPoolCreatePixelBuffer failed (\(rc))")
        }
        // Tag as sRGB so CoreImage/CG consumers interpret the bytes as display RGB.
        CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        return buf
    }
}

/// Converts `AVFrame`s (software or VideoToolbox) to BGRA buffers. One per decoder.
final class FrameConverter {
    private var pool: BGRAPool?
    private var sws: UnsafeMutablePointer<SwsContext>?
    private var swsKey: (Int32, Int32, Int32, Int32, Int32) = (0, 0, -1, -1, -1)
    private var transfer: VTPixelTransferSession?
    /// Codec of the stream; picks the default matrix for untagged frames.
    private let codecID: AVCodecID

    init(codec: AVCodecID) { codecID = codec }

    deinit {
        if let s = sws { sws_freeContext(s) }
        if let t = transfer { VTPixelTransferSessionInvalidate(t) }
    }

    private func buffer(width: Int, height: Int) throws -> CVPixelBuffer {
        if pool?.width != width || pool?.height != height {
            pool = try BGRAPool(width: width, height: height)
        }
        guard let pool else { throw MediaError.decodeFailed("no pixel buffer pool") }
        return try pool.make()
    }

    func convert(_ frame: UnsafeMutablePointer<AVFrame>) throws -> CVPixelBuffer {
        let w = Int(frame.pointee.width), h = Int(frame.pointee.height)
        guard w > 0, h > 0 else { throw MediaError.decodeFailed("empty frame") }
        if frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
            guard let raw = frame.pointee.data.3 else { throw MediaError.decodeFailed("VideoToolbox frame without buffer") }
            let src = Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(raw)).takeUnretainedValue()
            return try transferVT(src)
        }
        return try convertSoftware(frame, width: w, height: h)
    }

    /// GPU colour conversion of a decoder surface (NV12/P010/…) to BGRA.
    func transferVT(_ src: CVPixelBuffer) throws -> CVPixelBuffer {
        if transfer == nil {
            var t: VTPixelTransferSession?
            let rc = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &t)
            guard rc == noErr, let t else { throw MediaError.decodeFailed("VTPixelTransferSessionCreate \(rc)") }
            transfer = t
        }
        guard let transfer else { throw MediaError.decodeFailed("no transfer session") }
        let dst = try buffer(width: CVPixelBufferGetWidth(src), height: CVPixelBufferGetHeight(src))
        let rc = VTPixelTransferSessionTransferImage(transfer, from: src, to: dst)
        guard rc == noErr else { throw MediaError.decodeFailed("VTPixelTransferSessionTransferImage \(rc)") }
        return dst
    }

    private func convertSoftware(_ frame: UnsafeMutablePointer<AVFrame>, width w: Int, height h: Int) throws -> CVPixelBuffer {
        let fmt = frame.pointee.format
        let colorspace = frame.pointee.colorspace
        let range = frame.pointee.color_range
        let key = (Int32(w), Int32(h), fmt, Int32(bitPattern: colorspace.rawValue), Int32(bitPattern: range.rawValue))
        if sws == nil || key != swsKey {
            sws = sws_getCachedContext(sws, Int32(w), Int32(h), AVPixelFormat(fmt), Int32(w), Int32(h), AV_PIX_FMT_BGRA,
                                       Int32(SWS_BILINEAR.rawValue | SWS_ACCURATE_RND.rawValue | SWS_FULL_CHR_H_INT.rawValue),
                                       nil, nil, nil)
            guard let s = sws else { throw MediaError.decodeFailed("sws_getCachedContext failed for pix_fmt \(fmt)") }
            swsKey = key
            let desc = av_pix_fmt_desc_get(AVPixelFormat(fmt))
            let isRGB = desc.map { ($0.pointee.flags & UInt64(AV_PIX_FMT_FLAG_RGB)) != 0 } ?? false
            if !isRGB {
                let cs = Self.swsColorspace(colorspace, codec: codecID, height: h)
                // Unspecified range on YUV means limited ("tv") range, the libav convention.
                let srcFull: Int32 = (range == AVCOL_RANGE_JPEG || Self.isJPEGFormat(fmt)) ? 1 : 0
                let coeffs = sws_getCoefficients(cs)
                _ = sws_setColorspaceDetails(s, coeffs, srcFull, sws_getCoefficients(Int32(SWS_CS_DEFAULT)), 1,
                                             0, 1 << 16, 1 << 16)
            }
        }
        guard let s = sws else { throw MediaError.decodeFailed("no swscale context") }
        let dst = try buffer(width: w, height: h)
        CVPixelBufferLockBaseAddress(dst, [])
        defer { CVPixelBufferUnlockBaseAddress(dst, []) }
        guard let base = CVPixelBufferGetBaseAddress(dst) else { throw MediaError.decodeFailed("pixel buffer has no memory") }
        var dstPtrs: [UnsafeMutablePointer<UInt8>?] = [base.assumingMemoryBound(to: UInt8.self), nil, nil, nil]
        var dstStrides: [Int32] = [Int32(CVPixelBufferGetBytesPerRow(dst)), 0, 0, 0]
        let rc = withUnsafePointer(to: frame.pointee.data) { dp in
            dp.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { srcData in
                withUnsafePointer(to: frame.pointee.linesize) { lp in
                    lp.withMemoryRebound(to: Int32.self, capacity: 8) { srcStrides in
                        sws_scale(s, srcData, srcStrides, 0, Int32(h), &dstPtrs, &dstStrides)
                    }
                }
            }
        }
        guard rc > 0 else { throw MediaError.decodeFailed("sws_scale failed (\(rc))") }
        return dst
    }

    /// The YUV->RGB matrix. Tagged streams follow their tags. Untagged: tscc2 is BT.601
    /// (limited range; docs/specs/media-streams.md 5a [obs]); other untagged streams use
    /// BT.709 from 720 lines up, else BT.601 (the common convention) [inf].
    static func swsColorspace(_ cs: AVColorSpace, codec: AVCodecID, height: Int) -> Int32 {
        switch cs {
        case AVCOL_SPC_BT709: return Int32(SWS_CS_ITU709)
        case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: return Int32(SWS_CS_BT2020)
        case AVCOL_SPC_SMPTE240M: return Int32(SWS_CS_SMPTE240M)
        case AVCOL_SPC_FCC: return Int32(SWS_CS_FCC)
        case AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M: return Int32(SWS_CS_ITU601)
        default:
            if codec == AV_CODEC_ID_TSCC2 { return Int32(SWS_CS_ITU601) }
            return height >= 720 ? Int32(SWS_CS_ITU709) : Int32(SWS_CS_ITU601)
        }
    }

    static func isJPEGFormat(_ fmt: Int32) -> Bool {
        [AV_PIX_FMT_YUVJ420P, AV_PIX_FMT_YUVJ422P, AV_PIX_FMT_YUVJ444P, AV_PIX_FMT_YUVJ440P, AV_PIX_FMT_YUVJ411P]
            .contains { $0.rawValue == fmt }
    }
}

/// Draws a `CGImage` into a new BGRA (premultiplied alpha) pixel buffer in sRGB.
func makePixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
    let pool = try BGRAPool(width: image.width, height: image.height)
    let buf = try pool.make()
    CVPixelBufferLockBaseAddress(buf, [])
    defer { CVPixelBufferUnlockBaseAddress(buf, []) }
    guard let base = CVPixelBufferGetBaseAddress(buf),
          let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: base, width: image.width, height: image.height, bitsPerComponent: 8,
                              bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { throw MediaError.decodeFailed("cannot draw image into pixel buffer") }
    ctx.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return buf
}
