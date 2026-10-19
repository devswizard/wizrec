// Asynchronous VideoToolbox decoding of h264/hevc packets demuxed by libavformat, with several
// frames in flight. libav's own VideoToolbox hwaccel decodes one frame at a time (submit, wait,
// return), which caps 2.7K 10-bit HEVC near 105 fps; keeping a queue of packets inside the
// hardware decoder overlaps their latency.
//
// Output is reordered into presentation order here: a decoded picture is released once no
// packet that could present before it is still unread or still decoding.

import CFFmpeg
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Completions posted by VideoToolbox's output handler (on its own threads).
// @unchecked: every mutable field is only touched while holding `cond`.
final class VTOutputMailbox: @unchecked Sendable {
    private let cond = NSCondition()
    private var done: [(id: Int64, buffer: CVPixelBuffer?)] = []

    func post(_ id: Int64, _ buffer: CVPixelBuffer?) {
        cond.lock()
        done.append((id, buffer))
        cond.signal()
        cond.unlock()
    }

    /// Takes all completions; with `wait`, blocks until at least one arrives (or 2 s pass).
    func take(wait: Bool) -> [(id: Int64, buffer: CVPixelBuffer?)] {
        cond.lock()
        defer { cond.unlock() }
        if wait, done.isEmpty { _ = cond.wait(until: Date(timeIntervalSinceNow: 2)) }
        let d = done
        done.removeAll(keepingCapacity: true)
        return d
    }
}

/// One `VTDecompressionSession` fed with libav packets. Not thread-safe: owned by one decoder core.
final class VTPictureDecoder {
    let session: VTDecompressionSession
    let format: CMVideoFormatDescription
    /// Packets kept inside the decoder at once.
    let depth: Int

    private let mailbox = VTOutputMailbox()
    private let colour: [CFString: CFString]
    private var nextID: Int64 = 1
    /// Submitted, not yet completed: id → (pts, discard). pts `Int64.min` when unknown.
    private var inFlight: [Int64: (pts: Int64, discard: Bool)] = [:]
    /// Decoded pictures waiting for release, ascending pts.
    private var ready: [(pts: Int64, buffer: CVPixelBuffer)] = []
    /// DTS (else PTS) of the last packet read from the demuxer.
    private(set) var lastReadDTS = Int64.min
    private(set) var eof = false

    var inFlightCount: Int { inFlight.count }
    var hasReady: Bool { !ready.isEmpty }

    /// Nil when VideoToolbox cannot take this stream (codec, Annex B extradata, no hardware decoder).
    init?(par: UnsafeMutablePointer<AVCodecParameters>, depth: Int) {
        let id = par.pointee.codec_id
        let codecType: CMVideoCodecType
        let atom: String
        switch id {
        case AV_CODEC_ID_HEVC: codecType = kCMVideoCodecType_HEVC; atom = "hvcC"
        case AV_CODEC_ID_H264: codecType = kCMVideoCodecType_H264; atom = "avcC"
        default: return nil
        }
        guard VTIsHardwareDecodeSupported(codecType),
              let ex = par.pointee.extradata, par.pointee.extradata_size > 6, ex[0] == 1 // ISO (length-prefixed) only
        else { return nil }
        let w = Int(par.pointee.width), h = Int(par.pointee.height)
        guard w > 0, h > 0 else { return nil }
        let colour = Self.colourAttachments(par)
        var ext: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms:
                [atom: Data(bytes: ex, count: Int(par.pointee.extradata_size))] as CFDictionary,
            kCMFormatDescriptionExtension_FullRangeVideo: par.pointee.color_range == AVCOL_RANGE_JPEG,
        ]
        for (k, v) in colour { ext[k] = v }
        var fd: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(allocator: nil, codecType: codecType, width: Int32(w), height: Int32(h),
                                             extensions: ext as CFDictionary, formatDescriptionOut: &fd) == noErr,
              let fd else { return nil }

        let depthBits = av_pix_fmt_desc_get(AVPixelFormat(par.pointee.format)).map { Int($0.pointee.comp.0.depth) } ?? 8
        let full = par.pointee.color_range == AVCOL_RANGE_JPEG
        let pixel: OSType = depthBits > 8
            ? (full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            : (full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixel,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let spec: [CFString: Any] = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]
        var s: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: spec as CFDictionary,
                                           imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                           decompressionSessionOut: &s) == noErr, let s
        else { return nil }
        // Not real-time: decode as fast as possible (playback at high clip speeds, scrubbing).
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        session = s
        format = fd
        self.depth = max(1, depth)
        self.colour = colour
    }

    deinit {
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
    }

    // MARK: - Colour

    /// CoreVideo colour tags for the stream; untagged streams follow FrameConverter's software
    /// rule (BT.709 from 720 lines up, else BT.601) so both lanes produce the same pixels.
    static func colourAttachments(_ par: UnsafeMutablePointer<AVCodecParameters>) -> [CFString: CFString] {
        let hd = par.pointee.height >= 720
        let primaries: CFString
        switch par.pointee.color_primaries {
        case AVCOL_PRI_BT709: primaries = kCVImageBufferColorPrimaries_ITU_R_709_2
        case AVCOL_PRI_BT470BG: primaries = kCVImageBufferColorPrimaries_EBU_3213
        case AVCOL_PRI_SMPTE170M, AVCOL_PRI_SMPTE240M: primaries = kCVImageBufferColorPrimaries_SMPTE_C
        case AVCOL_PRI_BT2020: primaries = kCVImageBufferColorPrimaries_ITU_R_2020
        case AVCOL_PRI_SMPTE432: primaries = kCVImageBufferColorPrimaries_P3_D65
        default: primaries = hd ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_SMPTE_C
        }
        let transfer: CFString
        switch par.pointee.color_trc {
        case AVCOL_TRC_SMPTE2084: transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case AVCOL_TRC_ARIB_STD_B67: transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG
        case AVCOL_TRC_IEC61966_2_1: transfer = kCVImageBufferTransferFunction_sRGB
        case AVCOL_TRC_LINEAR: transfer = kCVImageBufferTransferFunction_Linear
        case AVCOL_TRC_BT2020_10, AVCOL_TRC_BT2020_12: transfer = kCVImageBufferTransferFunction_ITU_R_2020
        default: transfer = kCVImageBufferTransferFunction_ITU_R_709_2
        }
        let matrix: CFString
        switch par.pointee.color_space {
        case AVCOL_SPC_BT709: matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M: matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4
        case AVCOL_SPC_SMPTE240M: matrix = kCVImageBufferYCbCrMatrix_SMPTE_240M_1995
        case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
        default: matrix = hd ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4
        }
        return [kCVImageBufferColorPrimariesKey: primaries, kCVImageBufferTransferFunctionKey: transfer,
                kCVImageBufferYCbCrMatrixKey: matrix]
    }

    // MARK: - Decoding

    /// Queues `packet` (length-prefixed NAL units) for asynchronous decode.
    func submit(_ packet: UnsafeMutablePointer<AVPacket>, timeBase: AVRational) throws {
        let pts = packet.pointee.pts, dts = packet.pointee.dts
        let order = dts != avNoPTS ? dts : pts
        if order != avNoPTS { lastReadDTS = max(lastReadDTS, order) }
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return }
        let size = Int(packet.pointee.size)

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: size, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: size,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block,
              CMBlockBufferReplaceDataBytes(with: data, blockBuffer: block, offsetIntoDestination: 0, dataLength: size) == noErr
        else { throw MediaError.decodeFailed("CMBlockBuffer") }
        func cm(_ v: Int64) -> CMTime {
            v == avNoPTS ? .invalid : CMTime(value: v * Int64(timeBase.num), timescale: timeBase.den)
        }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: cm(pts), decodeTimeStamp: cm(dts))
        var sampleSize = size
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sb) == noErr,
              let sb
        else { throw MediaError.decodeFailed("CMSampleBuffer") }

        let id = nextID
        nextID += 1
        inFlight[id] = (pts, (packet.pointee.flags & AV_PKT_FLAG_DISCARD) != 0)
        let mailbox = self.mailbox
        let rc = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [._EnableAsynchronousDecompression],
                                                   infoFlagsOut: nil) { status, _, image, _, _ in
            mailbox.post(id, status == noErr ? image : nil)
        }
        if rc != noErr {
            inFlight[id] = nil
            if rc == kVTInvalidSessionErr || rc == kVTVideoDecoderMalfunctionErr {
                throw MediaError.decodeFailed("VTDecompressionSessionDecodeFrame \(rc)")
            }
            // A bad packet: like libav, skip it (its picture counts as dropped).
        }
    }

    /// Moves completed pictures into the reorder buffer.
    /// Returns the number of completions taken (0 after a 2 s timeout when waiting).
    @discardableResult
    func collect(wait: Bool) -> Int {
        let done = mailbox.take(wait: wait)
        for (id, buffer) in done {
            guard let meta = inFlight.removeValue(forKey: id) else { continue } // flushed meanwhile
            guard let buffer, !meta.discard, meta.pts != avNoPTS else { continue }
            let i = ready.firstIndex { $0.pts > meta.pts } ?? ready.count
            ready.insert((meta.pts, buffer), at: i)
        }
        return done.count
    }

    /// The next picture in presentation order once nothing earlier can still arrive.
    func popReleasable() -> (pts: Int64, buffer: CVPixelBuffer)? {
        guard let first = ready.first else { return nil }
        // Unread packets have DTS ≥ lastReadDTS and PTS ≥ DTS, so none presents before `first`.
        guard eof || first.pts <= lastReadDTS else { return nil }
        if inFlight.values.contains(where: { $0.pts < first.pts }) { return nil }
        ready.removeFirst()
        for (k, v) in colour { CVBufferSetAttachment(first.buffer, k, v, .shouldPropagate) }
        return first
    }

    /// End of stream: emit the decoder's delayed pictures.
    func markEOF() {
        eof = true
        VTDecompressionSessionFinishDelayedFrames(session)
    }

    /// Drops everything in flight and buffered (seek).
    func flush() {
        if !inFlight.isEmpty { VTDecompressionSessionWaitForAsynchronousFrames(session) }
        _ = mailbox.take(wait: false)
        inFlight.removeAll()
        ready.removeAll()
        lastReadDTS = Int64.min
        eof = false
    }
}

/// Wraps a decoded `CVPixelBuffer` in an `AVFrame` (`AV_PIX_FMT_VIDEOTOOLBOX`, buffer in
/// `data[3]`, released by the frame's `buf[0]`), the shape libav's hwaccel produces.
func makeVideoToolboxFrame(_ buffer: CVPixelBuffer, pts: Int64) throws -> UnsafeMutablePointer<AVFrame> {
    guard let f = av_frame_alloc() else { throw MediaError.decodeFailed("av_frame_alloc") }
    let retained = Unmanaged.passRetained(buffer).toOpaque()
    let bytes = retained.assumingMemoryBound(to: UInt8.self)
    guard let ref = av_buffer_create(bytes, 1, { _, data in
        if let data { Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(data)).release() }
    }, nil, 0) else {
        Unmanaged<CVPixelBuffer>.fromOpaque(retained).release()
        var fp: UnsafeMutablePointer<AVFrame>? = f
        av_frame_free(&fp)
        throw MediaError.decodeFailed("av_buffer_create")
    }
    f.pointee.buf.0 = ref
    f.pointee.data.3 = bytes
    f.pointee.format = AV_PIX_FMT_VIDEOTOOLBOX.rawValue
    f.pointee.width = Int32(CVPixelBufferGetWidth(buffer))
    f.pointee.height = Int32(CVPixelBufferGetHeight(buffer))
    f.pointee.pts = pts
    f.pointee.best_effort_timestamp = pts
    return f
}
