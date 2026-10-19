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
///
/// Streams that can decode on VideoToolbox (`sharesGPUConversion`) convert every frame the same
/// way, whichever lane decoded it: software pictures are copied into a bi-planar YCbCr
/// `CVPixelBuffer` (the layout VideoToolbox returns), both kinds of buffer get the same
/// stream-level colour tags (matrix, primaries, transfer, chroma siting), and one
/// `VTPixelTransferSession` converts them to BGRA. H.264/HEVC decoding is bit-exact, so the
/// BGRA bytes depend only on (source, frame). Other streams (tscc2, …) use swscale.
final class FrameConverter {
    private var pool: BGRAPool?
    private var sws: UnsafeMutablePointer<SwsContext>?
    private var swsKey: [Int32] = []
    private var transfer: VTPixelTransferSession?
    /// Codec of the stream; picks the default matrix for untagged frames.
    private let codecID: AVCodecID
    /// Both lanes convert through VideoToolbox with `tags` (codecs with a hardware lane).
    let sharesGPUConversion: Bool
    /// Colour attachments applied to every YCbCr source buffer before conversion.
    private let tags: [CFString: CFString]
    /// The stream's samples are full range (JPEG); picks the staging buffer format.
    private let fullRange: Bool
    /// Bi-planar YCbCr staging buffers for software pictures, and their (width, height, format).
    private var stagingPool: CVPixelBufferPool?
    private var stagingKey: [Int] = []

    /// Codecs that may decode on VideoToolbox; their software frames share its conversion.
    static let gpuConvertedCodecs: Set<AVCodecID> = [AV_CODEC_ID_H264, AV_CODEC_ID_HEVC, AV_CODEC_ID_PRORES,
                                                      AV_CODEC_ID_MPEG4, AV_CODEC_ID_MPEG2VIDEO, AV_CODEC_ID_VP9,
                                                      AV_CODEC_ID_AV1]

    /// Converter for the stream described by `par`.
    init(par: UnsafeMutablePointer<AVCodecParameters>) {
        codecID = par.pointee.codec_id
        sharesGPUConversion = Self.gpuConvertedCodecs.contains(codecID)
        tags = VTPictureDecoder.colourAttachments(par)
        fullRange = Self.isFullRange(par)
    }

    /// Converter for a stream known only by its codec (swscale only).
    init(codec: AVCodecID) {
        codecID = codec
        sharesGPUConversion = false
        tags = [:]
        fullRange = false
    }

    /// Full-range (JPEG) samples: tagged so, or a `yuvj*` format.
    static func isFullRange(_ par: UnsafeMutablePointer<AVCodecParameters>) -> Bool {
        par.pointee.color_range == AVCOL_RANGE_JPEG || isJPEGFormat(par.pointee.format)
    }

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
        if let src = try yuvSource(frame) { return try transferVT(src) }
        return try convertSoftware(frame, width: w, height: h, outWidth: w, outHeight: h)
    }

    /// Output size whose longer side is at most `maxPixelSize` (never upscaled), aspect kept.
    static func scaledSize(width w: Int, height h: Int, maxPixelSize: Int) -> (Int, Int) {
        let longer = max(w, h), limit = max(1, maxPixelSize)
        guard longer > limit else { return (w, h) }
        let scale = Double(limit) / Double(longer)
        return (max(1, Int((Double(w) * scale).rounded())), max(1, Int((Double(h) * scale).rounded())))
    }

    /// Like `convert`, scaled in the same pass so the longer side is ≤ `maxPixelSize` (thumbnails).
    func convertScaled(_ frame: UnsafeMutablePointer<AVFrame>, maxPixelSize: Int) throws -> CVPixelBuffer {
        let w = Int(frame.pointee.width), h = Int(frame.pointee.height)
        guard w > 0, h > 0 else { throw MediaError.decodeFailed("empty frame") }
        let (ow, oh) = Self.scaledSize(width: w, height: h, maxPixelSize: maxPixelSize)
        if let src = try yuvSource(frame) { return try transferVT(src, width: ow, height: oh) }
        return try convertSoftware(frame, width: w, height: h, outWidth: ow, outHeight: oh)
    }

    /// The YCbCr buffer to convert on the GPU: the VideoToolbox surface itself, or (when the
    /// stream shares the GPU conversion) a software picture copied into a staging buffer,
    /// tagged with the stream's colour attachments. Nil = convert with swscale.
    private func yuvSource(_ frame: UnsafeMutablePointer<AVFrame>) throws -> CVPixelBuffer? {
        let src: CVPixelBuffer
        if frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
            guard let raw = frame.pointee.data.3 else { throw MediaError.decodeFailed("VideoToolbox frame without buffer") }
            src = Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(raw)).takeUnretainedValue()
            guard sharesGPUConversion else { return src } // keep the decoder's own tags
        } else {
            guard sharesGPUConversion, let staged = try stage(frame) else { return nil }
            src = staged
        }
        // Identical tags on both lanes' buffers: nothing a decoder attached (clean aperture,
        // gamma, ICC profile, its own siting guess) may change the conversion.
        CVBufferRemoveAllAttachments(src)
        for (k, v) in tags { CVBufferSetAttachment(src, k, v, .shouldPropagate) }
        return src
    }

    /// Bi-planar CoreVideo format for a planar YCbCr software format; nil when there is none.
    static func stagingFormat(_ fmt: Int32, fullRange full: Bool) -> (format: OSType, depth: Int, cw: Int, ch: Int)? {
        guard let d = av_pix_fmt_desc_get(AVPixelFormat(fmt)) else { return nil }
        let desc = d.pointee
        let flags = desc.flags
        guard desc.nb_components == 3,
              flags & UInt64(AV_PIX_FMT_FLAG_PLANAR) != 0,
              flags & UInt64(AV_PIX_FMT_FLAG_RGB) == 0,
              flags & UInt64(AV_PIX_FMT_FLAG_BE) == 0,
              flags & UInt64(AV_PIX_FMT_FLAG_HWACCEL) == 0,
              desc.comp.0.plane == 0, desc.comp.1.plane == 1, desc.comp.2.plane == 2,
              desc.comp.0.shift == 0, desc.comp.1.shift == 0, desc.comp.2.shift == 0
        else { return nil }
        let depth = Int(desc.comp.0.depth), cw = Int(desc.log2_chroma_w), ch = Int(desc.log2_chroma_h)
        let f: OSType
        switch (depth, cw, ch) {
        case (8, 1, 1): f = full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case (8, 1, 0): f = full ? kCVPixelFormatType_422YpCbCr8BiPlanarFullRange : kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange
        case (8, 0, 0): f = full ? kCVPixelFormatType_444YpCbCr8BiPlanarFullRange : kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
        case (10, 1, 1): f = full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case (10, 1, 0): f = full ? kCVPixelFormatType_422YpCbCr10BiPlanarFullRange : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        case (10, 0, 0): f = full ? kCVPixelFormatType_444YpCbCr10BiPlanarFullRange : kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
        default: return nil
        }
        let step = depth > 8 ? 2 : 1
        guard Int(desc.comp.0.step) == step, Int(desc.comp.1.step) == step, Int(desc.comp.2.step) == step else { return nil }
        return (f, depth, cw, ch)
    }

    /// Copies a planar software picture into a bi-planar staging buffer (luma plane, then
    /// interleaved Cb/Cr; 10-bit samples moved to the 16-bit MSBs as VideoToolbox stores them).
    /// Nil when the format has no bi-planar equivalent.
    private func stage(_ frame: UnsafeMutablePointer<AVFrame>) throws -> CVPixelBuffer? {
        guard let sf = Self.stagingFormat(frame.pointee.format, fullRange: fullRange) else { return nil }
        let w = Int(frame.pointee.width), h = Int(frame.pointee.height)
        let key = [w, h, Int(sf.format)]
        if stagingPool == nil || stagingKey != key {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: sf.format,
                kCVPixelBufferWidthKey: w,
                kCVPixelBufferHeightKey: h,
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
            ]
            var p: CVPixelBufferPool?
            let rc = CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            guard rc == kCVReturnSuccess, let p else { throw MediaError.decodeFailed("staging pool \(w)x\(h) failed (\(rc))") }
            stagingPool = p
            stagingKey = key
        }
        guard let stagingPool else { return nil }
        var b: CVPixelBuffer?
        let rc = CVPixelBufferPoolCreatePixelBuffer(nil, stagingPool, &b)
        guard rc == kCVReturnSuccess, let dst = b else { throw MediaError.decodeFailed("staging buffer failed (\(rc))") }
        guard let sy = frame.pointee.data.0, let su = frame.pointee.data.1, let sv = frame.pointee.data.2 else {
            throw MediaError.decodeFailed("software frame without planes")
        }
        let ly = Int(frame.pointee.linesize.0), lu = Int(frame.pointee.linesize.1), lv = Int(frame.pointee.linesize.2)
        CVPixelBufferLockBaseAddress(dst, [])
        defer { CVPixelBufferUnlockBaseAddress(dst, []) }
        guard let dy = CVPixelBufferGetBaseAddressOfPlane(dst, 0), let dc = CVPixelBufferGetBaseAddressOfPlane(dst, 1) else {
            throw MediaError.decodeFailed("staging buffer has no memory")
        }
        let ry = CVPixelBufferGetBytesPerRowOfPlane(dst, 0), rcb = CVPixelBufferGetBytesPerRowOfPlane(dst, 1)
        let cwid = min((w + (1 << sf.cw) - 1) >> sf.cw, CVPixelBufferGetWidthOfPlane(dst, 1))
        let chgt = min((h + (1 << sf.ch) - 1) >> sf.ch, CVPixelBufferGetHeightOfPlane(dst, 1))
        if sf.depth == 8 {
            for y in 0..<h { (dy + y * ry).copyMemory(from: sy + y * ly, byteCount: w) }
            for y in 0..<chgt {
                let u = su + y * lu, v = sv + y * lv
                let d = (dc + y * rcb).assumingMemoryBound(to: UInt8.self)
                for x in 0..<cwid { d[2 * x] = u[x]; d[2 * x + 1] = v[x] }
            }
        } else {
            let shift = UInt16(16 - sf.depth)
            for y in 0..<h {
                let s = UnsafeRawPointer(sy + y * ly).assumingMemoryBound(to: UInt16.self)
                let d = (dy + y * ry).assumingMemoryBound(to: UInt16.self)
                for x in 0..<w { d[x] = s[x] << shift }
            }
            for y in 0..<chgt {
                let u = UnsafeRawPointer(su + y * lu).assumingMemoryBound(to: UInt16.self)
                let v = UnsafeRawPointer(sv + y * lv).assumingMemoryBound(to: UInt16.self)
                let d = (dc + y * rcb).assumingMemoryBound(to: UInt16.self)
                for x in 0..<cwid { d[2 * x] = u[x] << shift; d[2 * x + 1] = v[x] << shift }
            }
        }
        return dst
    }

    /// GPU colour conversion (and scaling) of a decoder surface (NV12/P010/…) to BGRA.
    func transferVT(_ src: CVPixelBuffer, width: Int? = nil, height: Int? = nil) throws -> CVPixelBuffer {
        if transfer == nil {
            var t: VTPixelTransferSession?
            let rc = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &t)
            guard rc == noErr, let t else { throw MediaError.decodeFailed("VTPixelTransferSessionCreate \(rc)") }
            transfer = t
        }
        guard let transfer else { throw MediaError.decodeFailed("no transfer session") }
        let dst = try buffer(width: width ?? CVPixelBufferGetWidth(src), height: height ?? CVPixelBufferGetHeight(src))
        let rc = VTPixelTransferSessionTransferImage(transfer, from: src, to: dst)
        guard rc == noErr else { throw MediaError.decodeFailed("VTPixelTransferSessionTransferImage \(rc)") }
        return dst
    }

    private func convertSoftware(_ frame: UnsafeMutablePointer<AVFrame>, width w: Int, height h: Int,
                                 outWidth ow: Int, outHeight oh: Int) throws -> CVPixelBuffer {
        let fmt = frame.pointee.format
        let colorspace = frame.pointee.colorspace
        let range = frame.pointee.color_range
        let key: [Int32] = [Int32(w), Int32(h), fmt, Int32(bitPattern: colorspace.rawValue), Int32(bitPattern: range.rawValue),
                   Int32(ow), Int32(oh)]
        if sws == nil || key != swsKey {
            let flags = (ow == w && oh == h ? SWS_BILINEAR.rawValue : SWS_AREA.rawValue)
                | SWS_ACCURATE_RND.rawValue | SWS_FULL_CHR_H_INT.rawValue
            sws = sws_getCachedContext(sws, Int32(w), Int32(h), AVPixelFormat(fmt), Int32(ow), Int32(oh), AV_PIX_FMT_BGRA,
                                       Int32(flags),
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
        let dst = try buffer(width: ow, height: oh)
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
