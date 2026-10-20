// Frame-accurate video decoding of one stream with libavformat + libavcodec
// (VideoToolbox hardware decode for h264/hevc/prores when available).

import CFFmpeg
import CoreMedia
import CoreVideo
import Foundation

/// A decoded but not yet converted frame.
private struct DecodedFrame {
    let frame: UnsafeMutablePointer<AVFrame>
    let pts: Int64
}

/// Decodes one video stream. Owns its own demuxer so streams of one file seek independently.
///
/// Runs on a private serial dispatch queue: decode work blocks, so it stays off the
/// cooperative pool, and the libav contexts in `core` are only ever touched from that queue.
actor VideoDecoder {
    /// libav (container) stream index.
    nonisolated let streamIndex: Int
    private let queue: DispatchSerialQueue
    private let core: VideoDecodeCore
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    init(url: URL, streamIndex: Int, allowHardware: Bool = true, hdrToneMapping: HDRToneMapping = .cpu) throws {
        self.streamIndex = streamIndex
        self.queue = DispatchSerialQueue(label: "wizrec.media.video.\(streamIndex)", qos: .userInitiated)
        let core = try VideoDecodeCore(url: url, streamIndex: streamIndex, allowHardware: allowHardware,
                                       hdrToneMapping: hdrToneMapping)
        self.core = core
        self.isHardwareCapable = core.usingHardware
    }

    /// The decoder opened on VideoToolbox.
    nonisolated let isHardwareCapable: Bool

    /// Frame on screen at stream time `time` (last frame with PTS ≤ time, clamped).
    func frame(at time: CMTime) throws -> VideoFrame { try core.frame(at: time) }

    /// `frame(at:)` plus its cost: pictures decoded and wall time (ms).
    func measuredFrame(at time: CMTime) throws -> (frame: VideoFrame, decoded: Int, ms: Double) {
        let before = core.decodedFrames
        let start = DispatchTime.now().uptimeNanoseconds
        let f = try core.frame(at: time)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        return (f, core.decodedFrames - before, ms)
    }

    /// True when serving `time` would need a demuxer seek (not just decoding forward).
    func requiresSeek(at time: CMTime) -> Bool { core.requiresSeek(at: time) }

    /// True when frames come from VideoToolbox.
    var isHardwareAccelerated: Bool { core.usingHardware }

    /// True when frames come from the asynchronous VideoToolbox path (several in flight).
    var isAsyncVideoToolbox: Bool { core.usingAsyncVideoToolbox }
}

/// One video stream, served by up to two decoders ("lanes"):
///
/// - a VideoToolbox lane — cheap and fast while decoding forward (playback);
/// - a multithreaded software lane, created on the first seek.
///
/// h264/hevc with ISO extradata decode on the asynchronous VideoToolbox path (`VTPictureDecoder`,
/// several frames in flight); other hardware codecs use libav's synchronous hwaccel. Depending on the
/// stream either lane can be the cheaper one to seek with. So each
/// lane's decode cost per frame is measured, and a seek goes to the cheaper lane. When the
/// software lane is playing forward, the hardware lane is repositioned in the background just
/// ahead of the playhead and takes over there.
///
/// Both lanes return byte-identical frames for a time, so switching is invisible and a frame
/// never depends on decode history: they pick the same picture (same frame rule), H.264/HEVC
/// decoding is bit-exact, and both convert YCbCr to BGRA through one path (`FrameConverter`:
/// software pictures are staged into the bi-planar layout VideoToolbox returns, both get the
/// same stream-level colour tags, one `VTPixelTransferSession` converts). Exception: software
/// formats with no bi-planar CoreVideo equivalent (12-bit, alpha, e.g. ProRes 4444) fall back
/// to swscale and may differ from the hardware lane by rounding.
/// Codecs without hardware decode (tscc2, …) use one software lane.
actor VideoStreamDecoder {
    nonisolated let url: URL
    nonisolated let streamIndex: Int
    private let hw: VideoDecoder?
    private var sw: VideoDecoder?

    /// Requests the software lane served by decoding forward, in a row.
    private var softwareRun = 0
    /// The hardware lane is busy repositioning in the background.
    private var warming = false
    /// The hardware lane only serves at or after this time (where it was repositioned).
    private var hwFrom: CMTime = .zero
    /// The hardware lane was repositioned ahead and waits for the playhead to reach `hwFrom`.
    private var handoverPending = false
    /// Bumped on every scrub, so a late handover for an old position is ignored.
    private var generation: UInt64 = 0
    /// Smoothed decode cost per picture (ms) of each lane; nil until measured.
    private var hwCost: Double?
    private var swCost: Double?

    /// Software frames in a row before the hardware lane is repositioned for playback.
    private let runBeforeHandover = 6
    /// How far ahead of the playhead the hardware lane is repositioned (seconds).
    private let handoverLead = 0.5

    /// Where HDR frames are tone-mapped (both lanes alike).
    nonisolated let hdrToneMapping: HDRToneMapping

    init(url: URL, streamIndex: Int, hdrToneMapping: HDRToneMapping = .cpu) throws {
        self.url = url
        self.streamIndex = streamIndex
        self.hdrToneMapping = hdrToneMapping
        let first = try VideoDecoder(url: url, streamIndex: streamIndex, allowHardware: true, hdrToneMapping: hdrToneMapping)
        if first.isHardwareCapable {
            hw = first
        } else {
            hw = nil
            sw = first
        }
    }

    private func softwareLane() throws -> VideoDecoder {
        if let sw { return sw }
        let d = try VideoDecoder(url: url, streamIndex: streamIndex, allowHardware: false, hdrToneMapping: hdrToneMapping)
        sw = d
        return d
    }

    private static func smooth(_ old: Double?, _ sample: Double) -> Double {
        old.map { 0.7 * $0 + 0.3 * sample } ?? sample
    }

    private func serveHardware(_ hw: VideoDecoder, _ time: CMTime) async throws -> VideoFrame {
        hardwareServed += 1
        let r = try await hw.measuredFrame(at: time)
        if r.decoded > 0 { hwCost = Self.smooth(hwCost, r.ms / Double(r.decoded)) }
        recordRate(r.decoded, r.ms)
        return r.frame
    }

    private func serveSoftware(_ sw: VideoDecoder, _ time: CMTime) async throws -> VideoFrame {
        softwareServed += 1
        let r = try await sw.measuredFrame(at: time)
        if r.decoded > 0 { swCost = Self.smooth(swCost, r.ms / Double(r.decoded)) }
        recordRate(r.decoded, r.ms)
        return r.frame
    }

    /// Decayed sums of pictures decoded and busy time (ms) over recent requests that decoded.
    private var rateFrames = 0.0
    private var rateMs = 0.0

    private func recordRate(_ decoded: Int, _ ms: Double) {
        guard decoded > 0 else { return }
        rateFrames = 0.9 * rateFrames + Double(decoded)
        rateMs = 0.9 * rateMs + ms
    }

    /// Decoded pictures per second of busy time, smoothed; nil until measured.
    var decodeRate: Double? { rateMs > 0 ? rateFrames / rateMs * 1000 : nil }

    func frame(at time: CMTime) async throws -> VideoFrame {
        guard let hw else { return try await softwareLane().frame(at: time) }
        // 1. Hardware lane positioned for this time: playback.
        if !warming, time >= hwFrom, await !hw.requiresSeek(at: time) {
            softwareRun = 0
            handoverPending = false
            return try await serveHardware(hw, time)
        }
        // 2. Software lane positioned for this time.
        if let sw, await !sw.requiresSeek(at: time) {
            let f = try await serveSoftware(sw, time)
            softwareRun += 1
            if softwareRun >= runBeforeHandover, !warming, !handoverPending { startHandover(hw, after: time) }
            return f
        }
        // 3. A seek. It invalidates any pending handover.
        softwareRun = 0
        handoverPending = false
        generation &+= 1
        if !warming, let h = hwCost, let s = swCost, h < 0.9 * s {
            hwFrom = .zero
            return try await serveHardware(hw, time)
        }
        return try await serveSoftware(try softwareLane(), time)
    }

    private func startHandover(_ hw: VideoDecoder, after time: CMTime) {
        warming = true
        let target = time + CMTime(seconds: handoverLead, preferredTimescale: 600)
        let gen = generation
        Task {
            var ok = false
            do {
                let r = try await hw.measuredFrame(at: target)
                ok = true
                if r.decoded > 0 { self.recordHardwareCost(r.ms / Double(r.decoded)) }
            } catch {}
            self.handoverDone(at: target, ok: ok, generation: gen)
        }
    }

    private func recordHardwareCost(_ ms: Double) { hwCost = Self.smooth(hwCost, ms) }

    private func handoverDone(at time: CMTime, ok: Bool, generation gen: UInt64) {
        warming = false
        guard gen == generation else { return } // the playhead jumped meanwhile
        if ok {
            hwFrom = time
            handoverPending = true
        } else {
            hwFrom = .positiveInfinity // hardware lane unusable; stay in software
        }
    }

    /// True when playback frames come from VideoToolbox.
    var isHardwareAccelerated: Bool { get async { await hw?.isHardwareAccelerated ?? false } }

    /// Requests served per lane (diagnostics, tests).
    private(set) var hardwareServed = 0
    private(set) var softwareServed = 0
}


/// The libav state behind a `VideoDecoder`. Not thread-safe; confined to the actor.
final class VideoDecodeCore {
    /// libav (container) stream index.
    let streamIndex: Int
    let clock: StreamClock

    private let url: URL
    private let format: FormatContext
    private var codec: UnsafeMutablePointer<AVCodecContext>
    private(set) var usingHardware: Bool
    /// Asynchronous VideoToolbox decoder (several frames in flight); nil = libav decodes.
    private var vt: VTPictureDecoder?
    private let packet: UnsafeMutablePointer<AVPacket>
    private let converter: FrameConverter
    /// Keyframe timestamps (stream ticks, ascending) from the container index. May be empty.
    private let keyframes: [Int64]

    private var current: DecodedFrame?
    private var pending: DecodedFrame?
    private var currentOutput: VideoFrame?
    /// The decoder has returned its last frame.
    private var drained = false
    private var sentFlushPacket = false
    /// True when no packet has been read since the last seek/open (decoder empty).
    private var atStart = true

    /// Seek ahead instead of decoding through when the target is this far past the decoder (seconds).
    private let seekAheadThreshold = 0.25

    init(url: URL, streamIndex: Int, allowHardware: Bool = true, hdrToneMapping: HDRToneMapping = .cpu) throws {
        self.url = url
        self.streamIndex = streamIndex
        let fc = try FormatContext(url: url)
        guard let st = fc.stream(streamIndex), let par = st.pointee.codecpar,
              par.pointee.codec_type == AVMEDIA_TYPE_VIDEO
        else { throw MediaError.noSuchStream(streamIndex) }
        fc.discardAll(except: streamIndex)
        self.format = fc
        // Stream time 0 = movie time 0 (edit lists applied by libav); never the first PTS.
        self.clock = StreamClock(timeBase: st.pointee.time_base, origin: 0)

        var kf: [Int64] = []
        let n = avformat_index_get_entries_count(st)
        if n > 0 {
            kf.reserveCapacity(Int(n) / 8)
            for i in 0..<n {
                guard let e = avformat_index_get_entry(st, i) else { continue }
                if (e.pointee.flags & Int32(AVINDEX_KEYFRAME)) != 0 { kf.append(e.pointee.timestamp) }
            }
            kf.sort()
        }
        self.keyframes = kf
        self.converter = FrameConverter(par: par, hdrToneMapping: hdrToneMapping)

        if allowHardware, Self.asyncVideoToolboxEnabled,
           let vt = VTPictureDecoder(par: par, depth: Self.asyncDepth) {
            // libav keeps demuxing; its codec context is only a light single-threaded stand-in.
            let (ctx, _) = try Self.openCodec(par: par, timeBase: st.pointee.time_base, allowHardware: false, threads: 1)
            self.codec = ctx
            self.vt = vt
            self.usingHardware = true
        } else {
            let (ctx, hw) = try Self.openCodec(par: par, timeBase: st.pointee.time_base, allowHardware: allowHardware)
            self.codec = ctx
            self.usingHardware = hw
        }
        guard let pkt = av_packet_alloc() else { throw MediaError.decodeFailed("av_packet_alloc") }
        self.packet = pkt
    }

    deinit {
        clearPacketQueue()
        var c: UnsafeMutablePointer<AVCodecContext>? = codec
        avcodec_free_context(&c)
        var p: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&p)
        for f in [current, pending].compactMap({ $0 }) {
            var fp: UnsafeMutablePointer<AVFrame>? = f.frame
            av_frame_free(&fp)
        }
    }

    /// `WIZREC_VT_ASYNC=0` turns the asynchronous VideoToolbox path off (libav's hwaccel instead).
    static var asyncVideoToolboxEnabled: Bool {
        ProcessInfo.processInfo.environment["WIZREC_VT_ASYNC"] != "0"
            && ProcessInfo.processInfo.environment["WIZREC_NO_HWDEC"] == nil
    }

    /// Packets in flight on the asynchronous VideoToolbox path (`WIZREC_VT_DEPTH`, default 8).
    static var asyncDepth: Int {
        ProcessInfo.processInfo.environment["WIZREC_VT_DEPTH"].flatMap(Int.init).map { min(max($0, 1), 32) } ?? 8
    }

    /// True when frames come from the asynchronous VideoToolbox path.
    var usingAsyncVideoToolbox: Bool { vt != nil }

    private static func openCodec(par: UnsafeMutablePointer<AVCodecParameters>, timeBase: AVRational,
                                  allowHardware: Bool, threads: Int32 = 0) throws -> (UnsafeMutablePointer<AVCodecContext>, Bool) {
        let id = par.pointee.codec_id
        guard let dec = avcodec_find_decoder(id) else {
            throw MediaError.unsupported("no decoder for \(codecName(id))")
        }
        guard let ctx = avcodec_alloc_context3(dec) else { throw MediaError.decodeFailed("avcodec_alloc_context3") }
        var ok = false
        defer { if !ok { var c: UnsafeMutablePointer<AVCodecContext>? = ctx; avcodec_free_context(&c) } }
        guard avcodec_parameters_to_context(ctx, par) >= 0 else { throw MediaError.decodeFailed("parameters_to_context") }
        ctx.pointee.pkt_timebase = timeBase

        var hw = false
        // Only codecs whose decoding is bit-exact by specification, so both lanes see the same
        // samples. ProRes, MPEG-4 Part 2 and MPEG-2 are not (IDCT within a tolerance): VideoToolbox
        // and libav reconstruct different ProRes samples (±1, observed), so they decode in software.
        let hwCodecs: Set<AVCodecID> = [AV_CODEC_ID_H264, AV_CODEC_ID_HEVC, AV_CODEC_ID_VP9, AV_CODEC_ID_AV1]
        if allowHardware, hwCodecs.contains(id), ProcessInfo.processInfo.environment["WIZREC_NO_HWDEC"] == nil {
            var dev: UnsafeMutablePointer<AVBufferRef>? = nil
            if av_hwdevice_ctx_create(&dev, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0, let dev {
                ctx.pointee.hw_device_ctx = dev // ownership moves to the codec context
                ctx.pointee.get_format = { _, fmts in
                    guard var p = fmts else { return AV_PIX_FMT_NONE }
                    var first = AV_PIX_FMT_NONE
                    while p.pointee != AV_PIX_FMT_NONE {
                        if p.pointee == AV_PIX_FMT_VIDEOTOOLBOX { return AV_PIX_FMT_VIDEOTOOLBOX }
                        if first == AV_PIX_FMT_NONE { first = p.pointee }
                        p += 1
                    }
                    return first
                }
                ctx.pointee.thread_count = 1
                hw = true
            }
        }
        if !hw {
            ctx.pointee.thread_count = threads // 0 = auto
            ctx.pointee.thread_type = threads == 1 ? 0 : FF_THREAD_FRAME | FF_THREAD_SLICE
        }
        let rc = avcodec_open2(ctx, dec, nil)
        guard rc >= 0 else { throw MediaError.decodeFailed("avcodec_open2 \(codecName(id)): \(avErrorString(rc))") }
        ok = true
        return (ctx, hw)
    }

    // MARK: - Public entry

    /// Frame on screen at stream time `time` (last frame with PTS ≤ time, clamped).
    /// Pictures decoded so far (all calls); lets callers measure decode cost per frame.
    private(set) var decodedFrames = 0

    func frame(at time: CMTime) throws -> VideoFrame {
        var target = clock.ticksFloor(time)
        if target < clock.origin { target = clock.origin }
        do {
            return try locate(target)
        } catch where usingHardware {
            // VideoToolbox can refuse streams (profile/size limits): retry once in software.
            try switchToSoftware()
            return try locate(target)
        }
    }

    private func switchToSoftware() throws {
        guard let par = format.stream(streamIndex)?.pointee.codecpar else { throw MediaError.noSuchStream(streamIndex) }
        let (ctx, _) = try Self.openCodec(par: par, timeBase: clock.avTimeBase, allowHardware: false)
        var old: UnsafeMutablePointer<AVCodecContext>? = codec
        avcodec_free_context(&old)
        codec = ctx
        resetState()
        vt = nil
        usingHardware = false
        current = nil
    }

    // MARK: - Positioning

    private func covers(_ target: Int64) -> Bool {
        guard let cur = current, cur.pts <= target else { return false }
        if let p = pending { return p.pts > target }
        return drained
    }

    private func locate(_ target: Int64) throws -> VideoFrame {
        if covers(target) { return try output() }

        if needsSeek(to: target) {
            try seekAndDecode(to: target)
        } else {
            try advance(to: target)
            if current == nil { try seekAndDecode(to: target) }
        }
        guard let cur = current else { throw MediaError.decodeFailed("no frame decoded for stream \(streamIndex)") }
        if usingHardware {
            // VideoToolbox can silently drop a frame (e.g. under GPU/decoder pressure); that
            // would hold the previous frame. Every packet presenting in (cur, target] must have
            // produced a picture, else fall back to software (frame(at:) retries).
            if sentPTS.contains(where: { $0 > cur.pts && $0 <= target }) {
                throw MediaError.decodeFailed("VideoToolbox dropped a frame in stream \(streamIndex)")
            }
            sentPTS.removeAll { $0 <= target }
        }
        return try output()
    }

    /// PTS of packets sent to a hardware decoder and not yet checked against its output.
    private var sentPTS: [Int64] = []

    /// True when serving `time` needs a demuxer seek rather than decoding forward.
    func requiresSeek(at time: CMTime) -> Bool {
        let target = max(clock.origin, clock.ticksFloor(time))
        return !covers(target) && needsSeek(to: target)
    }

    private func needsSeek(to target: Int64) -> Bool {
        // Fresh decoder: decoding from the start is only worth it for a target near the start.
        guard let cur = current else { return !atStart || clock.seconds(target - clock.origin) > seekAheadThreshold }
        if target < cur.pts { return true }
        if let k = keyframeIndex(atOrBefore: target), keyframes[k] > cur.pts,
           clock.seconds(target - cur.pts) > seekAheadThreshold {
            return true
        }
        return false
    }

    private func keyframeIndex(atOrBefore t: Int64) -> Int? {
        var lo = 0, hi = keyframes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if keyframes[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    /// Seek so the target frame decodes, stepping further back while the first decoded
    /// frame lands after `target` (B-frame reordering, missing or inexact index).
    ///
    /// Demuxers seek by presentation time (mov picks the last sync sample presenting at or
    /// before the timestamp), so the first try seeks to the target itself. Retries step back
    /// one indexed keyframe at a time (or 1 s, 2 s, 4 s … without an index).
    private func seekAndDecode(to target: Int64) throws {
        var k = keyframeIndex(atOrBefore: target) ?? -1
        var back: Int64 = 0
        let first = keyframes.first ?? clock.origin
        for attempt in 0..<64 {
            let seekTS: Int64
            if attempt == 0 {
                seekTS = target
            } else if !keyframes.isEmpty {
                k -= 1
                seekTS = k >= 0 ? keyframes[k] : Int64.min
            } else {
                back = max(clock.ticks(seconds: 1), back * 2)
                seekTS = target - back
            }
            try seek(to: seekTS)
            try queuePacketsAfterSeek(target: target)
            try advance(to: target)
            if current != nil { return }
            if seekTS == Int64.min || seekTS <= first {
                // Target precedes every frame: hold the first frame.
                if let p = pending { current = p; pending = nil; currentOutput = nil }
                if current != nil { return }
                throw MediaError.decodeFailed("stream \(streamIndex) has no frames")
            }
        }
        throw MediaError.decodeFailed("cannot seek to \(target) in stream \(streamIndex)")
    }

    private func resetState() {
        clearPacketQueue()
        for f in [current, pending].compactMap({ $0 }) {
            var fp: UnsafeMutablePointer<AVFrame>? = f.frame
            av_frame_free(&fp)
        }
        current = nil; pending = nil; currentOutput = nil
        sentPTS.removeAll()
        vt?.flush()
        drained = false; sentFlushPacket = false; atStart = true
    }

    /// Positions the demuxer on the keyframe at or before `ts` (`Int64.min` = stream start).
    private func seek(to ts: Int64) throws {
        resetState()
        avcodec_flush_buffers(codec)
        let t = ts == Int64.min ? (keyframes.first ?? clock.origin) : ts
        let idx = Int32(streamIndex)
        var rc = avformat_seek_file(format.ctx, idx, Int64.min, t, t, 0)
        if rc < 0 { rc = av_seek_frame(format.ctx, idx, t, AVSEEK_FLAG_BACKWARD) }
        if rc < 0 { rc = av_seek_frame(format.ctx, idx, t, AVSEEK_FLAG_BACKWARD | AVSEEK_FLAG_ANY) }
        if rc < 0 { throw MediaError.decodeFailed("seek to \(t) failed: \(avErrorString(rc))") }
    }

    /// Decode forward until the frame after `current` lies beyond `target`.
    private func advance(to target: Int64) throws {
        while true {
            if pending == nil && !drained {
                pending = try decodeNext()
                if pending == nil { drained = true }
            }
            guard let p = pending, p.pts <= target else { return }
            if let c = current {
                var fp: UnsafeMutablePointer<AVFrame>? = c.frame
                av_frame_free(&fp)
            }
            current = p
            pending = nil
            currentOutput = nil
        }
    }

    // MARK: - Packets

    /// Packets read ahead after a seek, consumed by `readPacket()` before the demuxer.
    private var packetQueue: [UnsafeMutablePointer<AVPacket>] = []

    private func clearPacketQueue() {
        for q in packetQueue { var qp: UnsafeMutablePointer<AVPacket>? = q; av_packet_free(&qp) }
        packetQueue.removeAll()
    }

    /// Fills `packet` from the read-ahead queue or the demuxer. Negative at end of file.
    private func readPacket() -> Int32 {
        if !packetQueue.isEmpty {
            let q = packetQueue.removeFirst()
            av_packet_move_ref(packet, q)
            var qp: UnsafeMutablePointer<AVPacket>? = q
            av_packet_free(&qp)
            return 0
        }
        return av_read_frame(format.ctx, packet)
    }

    /// After a seek, reads every packet that can present at or before `target` (all packets
    /// up to the first with DTS > target) and drops disposable (non-reference) ones that
    /// present before the target frame: nothing depends on them and they are never shown.
    private func queuePacketsAfterSeek(target: Int64) throws {
        guard canSkipDisposable else { return }
        var read: [UnsafeMutablePointer<AVPacket>] = []
        while read.count < 2048 {
            guard let q = av_packet_alloc() else { break }
            if av_read_frame(format.ctx, q) < 0 { var qp: UnsafeMutablePointer<AVPacket>? = q; av_packet_free(&qp); break }
            if Int(q.pointee.stream_index) != streamIndex { var qp: UnsafeMutablePointer<AVPacket>? = q; av_packet_free(&qp); continue }
            read.append(q)
            let d = q.pointee.dts != avNoPTS ? q.pointee.dts : q.pointee.pts
            if d != avNoPTS && d > target { break }
        }
        var targetPTS = Int64.min
        for q in read where q.pointee.pts != avNoPTS && q.pointee.pts <= target { targetPTS = max(targetPTS, q.pointee.pts) }
        for q in read {
            let pts = q.pointee.pts
            if pts != avNoPTS, pts < targetPTS, isDisposable(q) {
                var qp: UnsafeMutablePointer<AVPacket>? = q
                av_packet_free(&qp)
            } else {
                packetQueue.append(q)
            }
        }
    }

    /// NAL length size for length-prefixed (avcC) H.264, nil for Annex B / other codecs.
    private lazy var avcLengthSize: Int? = {
        guard codec.pointee.codec_id == AV_CODEC_ID_H264, let ex = codec.pointee.extradata,
              codec.pointee.extradata_size >= 7, ex[0] == 1 else { return nil }
        return Int(ex[4] & 3) + 1
    }()

    private var canSkipDisposable: Bool {
        codec.pointee.codec_id == AV_CODEC_ID_H264 && ProcessInfo.processInfo.environment["WIZREC_NO_SKIP"] == nil
    }

    /// True when the packet's picture is never used as a reference.
    private func isDisposable(_ q: UnsafeMutablePointer<AVPacket>) -> Bool {
        if (q.pointee.flags & AV_PKT_FLAG_DISPOSABLE) != 0 { return true }
        if (q.pointee.flags & AV_PKT_FLAG_KEY) != 0 { return false }
        guard let data = q.pointee.data else { return false }
        let size = Int(q.pointee.size)
        // H.264: the first VCL NAL (type 1 or 5) decides; nal_ref_idc == 0 means non-reference.
        func check(_ nal: Int) -> Bool? {
            let b = data[nal], type = b & 0x1F
            guard type == 1 || type == 5 else { return nil }
            return (b >> 5) & 3 == 0
        }
        if let len = avcLengthSize {
            var o = 0
            while o + len < size {
                var n = 0
                for i in 0..<len { n = (n << 8) | Int(data[o + i]) }
                let nal = o + len
                guard n > 0, nal + n <= size else { return false }
                if let r = check(nal) { return r }
                o = nal + n
            }
            return false
        }
        // Annex B start codes.
        var i = 0
        while i + 3 < size {
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                if let r = check(i + 3) { return r }
                i += 3
            } else { i += 1 }
        }
        return false
    }

    /// Next frame in presentation order, or nil at end of stream.
    private func decodeNext() throws -> DecodedFrame? {
        if let vt { return try decodeNextAsync(vt) }
        guard let f = av_frame_alloc() else { throw MediaError.decodeFailed("av_frame_alloc") }
        var keep = false
        defer { if !keep { var fp: UnsafeMutablePointer<AVFrame>? = f; av_frame_free(&fp) } }
        while true {
            let r = avcodec_receive_frame(codec, f)
            if r == 0 {
                var pts = f.pointee.best_effort_timestamp
                if pts == avNoPTS { pts = f.pointee.pts }
                if pts == avNoPTS {
                    // No timestamp at all: place it just after the previous frame.
                    pts = (pending?.pts ?? current?.pts ?? clock.origin - 1) + 1
                }
                if let c = current, pts <= c.pts {
                    // Out-of-order/duplicate timestamp after a seek (leading frames of an open GOP).
                    av_frame_unref(f)
                    continue
                }
                keep = true
                decodedFrames += 1
                return DecodedFrame(frame: f, pts: pts)
            }
            if r == avErrorEOF { return nil }
            guard r == avErrorEAGAIN else { throw MediaError.decodeFailed("receive_frame: \(avErrorString(r))") }

            if sentFlushPacket { return nil }
            let rr = readPacket()
            if rr < 0 {
                // End of file (or read error): drain the decoder.
                sentFlushPacket = true
                _ = avcodec_send_packet(codec, nil)
                continue
            }
            defer { av_packet_unref(packet) }
            guard Int(packet.pointee.stream_index) == streamIndex else { continue }
            atStart = false
            if usingHardware, packet.pointee.pts != avNoPTS, (packet.pointee.flags & AV_PKT_FLAG_DISCARD) == 0 {
                sentPTS.append(packet.pointee.pts)
            }
            let s = avcodec_send_packet(codec, packet)
            if s < 0 && s != avErrorEAGAIN {
                // Corrupt packet: skip it, like ffmpeg does, unless hardware refuses everything.
                if usingHardware && current == nil && pending == nil {
                    throw MediaError.decodeFailed("send_packet: \(avErrorString(s))")
                }
            }
        }
    }

    /// `decodeNext` on the asynchronous VideoToolbox path: keeps up to `vt.depth` packets in
    /// the decoder and returns pictures in presentation order.
    private func decodeNextAsync(_ vt: VTPictureDecoder) throws -> DecodedFrame? {
        var silentWaits = 0
        while true {
            vt.collect(wait: false)
            if let r = vt.popReleasable() {
                if let c = current, r.pts <= c.pts { continue } // leading pictures after a seek
                decodedFrames += 1
                return DecodedFrame(frame: try makeVideoToolboxFrame(r.buffer, pts: r.pts), pts: r.pts)
            }
            if !vt.eof, vt.inFlightCount < vt.depth {
                if readPacket() < 0 { vt.markEOF(); continue }
                defer { av_packet_unref(packet) }
                guard Int(packet.pointee.stream_index) == streamIndex else { continue }
                atStart = false
                if packet.pointee.pts != avNoPTS, (packet.pointee.flags & AV_PKT_FLAG_DISCARD) == 0 {
                    sentPTS.append(packet.pointee.pts)
                }
                try vt.submit(packet, timeBase: clock.avTimeBase)
                continue
            }
            if vt.inFlightCount == 0 {
                if vt.eof && !vt.hasReady { return nil }
                if !vt.eof { continue } // reorder buffer waits for more packets
            }
            if vt.collect(wait: true) == 0 {
                // VideoToolbox stopped answering (2 s per wait): give up; frame(at:) retries in software.
                silentWaits += 1
                if silentWaits >= 2 { throw MediaError.decodeFailed("VideoToolbox stalled in stream \(streamIndex)") }
            } else {
                silentWaits = 0
            }
        }
    }

    // MARK: - Output

    private func output() throws -> VideoFrame {
        if let o = currentOutput { return o }
        guard let cur = current else { throw MediaError.decodeFailed("no current frame") }
        let buf = try converter.convert(cur.frame)
        let pts = clock.time(ofTicks: cur.pts)
        let duration: CMTime
        if let p = pending {
            duration = CMTimeSubtract(clock.time(ofTicks: p.pts), pts)
        } else if drained {
            duration = .invalid
        } else {
            // Peek one frame ahead so the duration (and cache interval) is exact.
            pending = try decodeNext()
            if pending == nil { drained = true }
            duration = pending.map { CMTimeSubtract(clock.time(ofTicks: $0.pts), pts) } ?? .invalid
        }
        let out = VideoFrame(pixelBuffer: buf, presentationTime: pts, duration: duration)
        currentOutput = out
        return out
    }
}

// MARK: - Thumbnails

extension VideoDecodeCore {
    /// A small BGRA picture for a filmstrip: the exact frame at `time` (`exact`), or the first
    /// picture decoded after seeking to the keyframe at or before `time` (cheap: one GOP start).
    /// Returns the buffer and the picture's stream time.
    func thumbnailFrame(at time: CMTime, exact: Bool, maxPixelSize: Int) throws -> (CVPixelBuffer, CMTime) {
        do {
            return try thumbnailFrameOnce(at: time, exact: exact, maxPixelSize: maxPixelSize)
        } catch where usingHardware {
            try switchToSoftware()
            return try thumbnailFrameOnce(at: time, exact: exact, maxPixelSize: maxPixelSize)
        }
    }

    private func thumbnailFrameOnce(at time: CMTime, exact: Bool, maxPixelSize: Int) throws -> (CVPixelBuffer, CMTime) {
        var target = clock.ticksFloor(time)
        if target < clock.origin { target = clock.origin }
        if exact || covers(target) {
            _ = try locate(target)
        } else {
            try seek(to: target)
            current = try decodeNext()
            if current == nil {
                // Nothing decodes from that keyframe (index gap): use the exact path.
                _ = try locate(target)
            }
        }
        guard let cur = current else { throw MediaError.decodeFailed("no frame for thumbnail") }
        let buf = try converter.convertScaled(cur.frame, maxPixelSize: maxPixelSize)
        return (buf, clock.time(ofTicks: cur.pts))
    }

    /// Index of the keyframe at or before `time` (container index), for thumbnail cache keys.
    func keyframeOrdinal(at time: CMTime) -> Int? {
        keyframeIndex(atOrBefore: max(clock.origin, clock.ticksFloor(time)))
    }
}
