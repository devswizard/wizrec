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
    nonisolated let streamIndex: Int
    private let queue: DispatchSerialQueue
    private let core: VideoDecodeCore
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    init(url: URL, streamIndex: Int, allowHardware: Bool = true) throws {
        self.streamIndex = streamIndex
        self.queue = DispatchSerialQueue(label: "wizrec.media.video.\(streamIndex)", qos: .userInitiated)
        self.core = try VideoDecodeCore(url: url, streamIndex: streamIndex, allowHardware: allowHardware)
    }

    /// Frame on screen at stream time `time` (last frame with PTS ≤ time, clamped).
    func frame(at time: CMTime) throws -> VideoFrame { try core.frame(at: time) }

    /// True when frames come from VideoToolbox.
    var isHardwareAccelerated: Bool { core.usingHardware }
}

/// The libav state behind a `VideoDecoder`. Not thread-safe; confined to the actor.
final class VideoDecodeCore {
    let streamIndex: Int
    let clock: StreamClock

    private let url: URL
    private let format: FormatContext
    private var codec: UnsafeMutablePointer<AVCodecContext>
    private(set) var usingHardware: Bool
    private let packet: UnsafeMutablePointer<AVPacket>
    private let converter = FrameConverter()
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

    init(url: URL, streamIndex: Int, allowHardware: Bool = true) throws {
        self.url = url
        self.streamIndex = streamIndex
        let fc = try FormatContext(url: url)
        guard let st = fc.stream(streamIndex), let par = st.pointee.codecpar,
              par.pointee.codec_type == AVMEDIA_TYPE_VIDEO
        else { throw MediaError.noSuchStream(streamIndex) }
        fc.discardAll(except: streamIndex)
        self.format = fc
        self.clock = StreamClock(timeBase: st.pointee.time_base, origin: streamOrigin(st))

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

        let (ctx, hw) = try Self.openCodec(par: par, allowHardware: allowHardware)
        self.codec = ctx
        self.usingHardware = hw
        guard let pkt = av_packet_alloc() else { throw MediaError.decodeFailed("av_packet_alloc") }
        self.packet = pkt
    }

    deinit {
        var c: UnsafeMutablePointer<AVCodecContext>? = codec
        avcodec_free_context(&c)
        var p: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&p)
        for f in [current, pending].compactMap({ $0 }) {
            var fp: UnsafeMutablePointer<AVFrame>? = f.frame
            av_frame_free(&fp)
        }
    }

    private static func openCodec(par: UnsafeMutablePointer<AVCodecParameters>, allowHardware: Bool) throws
        -> (UnsafeMutablePointer<AVCodecContext>, Bool) {
        let id = par.pointee.codec_id
        guard let dec = avcodec_find_decoder(id) else {
            throw MediaError.unsupported("no decoder for \(codecName(id))")
        }
        guard let ctx = avcodec_alloc_context3(dec) else { throw MediaError.decodeFailed("avcodec_alloc_context3") }
        var ok = false
        defer { if !ok { var c: UnsafeMutablePointer<AVCodecContext>? = ctx; avcodec_free_context(&c) } }
        guard avcodec_parameters_to_context(ctx, par) >= 0 else { throw MediaError.decodeFailed("parameters_to_context") }

        var hw = false
        let hwCodecs: Set<AVCodecID> = [AV_CODEC_ID_H264, AV_CODEC_ID_HEVC, AV_CODEC_ID_PRORES, AV_CODEC_ID_MPEG4,
                                         AV_CODEC_ID_MPEG2VIDEO, AV_CODEC_ID_VP9, AV_CODEC_ID_AV1]
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
            ctx.pointee.thread_count = 0 // auto
            ctx.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE
        }
        let rc = avcodec_open2(ctx, dec, nil)
        guard rc >= 0 else { throw MediaError.decodeFailed("avcodec_open2 \(codecName(id)): \(avErrorString(rc))") }
        ok = true
        return (ctx, hw)
    }

    // MARK: - Public entry

    /// Frame on screen at stream time `time` (last frame with PTS ≤ time, clamped).
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
        let (ctx, _) = try Self.openCodec(par: par, allowHardware: false)
        var old: UnsafeMutablePointer<AVCodecContext>? = codec
        avcodec_free_context(&old)
        codec = ctx
        usingHardware = false
        resetState()
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
        guard current != nil else { throw MediaError.decodeFailed("no frame decoded for stream \(streamIndex)") }
        return try output()
    }

    private func needsSeek(to target: Int64) -> Bool {
        guard let cur = current else { return !atStart }
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

    /// Seek to the keyframe before `target`, stepping further back while the first
    /// decoded frame lands after `target` (B-frame reordering / missing index).
    private func seekAndDecode(to target: Int64) throws {
        var k = keyframeIndex(atOrBefore: target)
        var fallbackBack: Int64 = 0
        for _ in 0..<64 {
            let seekTS: Int64
            if !keyframes.isEmpty {
                seekTS = k.map { keyframes[$0] } ?? Int64.min
            } else {
                seekTS = target - fallbackBack
            }
            try seek(to: seekTS)
            try advance(to: target)
            let firstWasBefore = current != nil
            let atStreamStart = (!keyframes.isEmpty && (k ?? 0) <= 0) || (keyframes.isEmpty && seekTS <= clock.origin)
            if firstWasBefore { return }
            if atStreamStart {
                // Target precedes every frame: hold the first frame.
                if let p = pending { current = p; pending = nil; currentOutput = nil }
                if current != nil { return }
                throw MediaError.decodeFailed("stream \(streamIndex) has no frames")
            }
            if !keyframes.isEmpty {
                k = (k ?? 0) - 1
            } else {
                fallbackBack = max(clock.ticks(seconds: 1), fallbackBack * 2)
            }
        }
        throw MediaError.decodeFailed("cannot seek to \(target) in stream \(streamIndex)")
    }

    private func resetState() {
        for f in [current, pending].compactMap({ $0 }) {
            var fp: UnsafeMutablePointer<AVFrame>? = f.frame
            av_frame_free(&fp)
        }
        current = nil; pending = nil; currentOutput = nil
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

    /// Next frame in presentation order, or nil at end of stream.
    private func decodeNext() throws -> DecodedFrame? {
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
                return DecodedFrame(frame: f, pts: pts)
            }
            if r == avErrorEOF { return nil }
            guard r == avErrorEAGAIN else { throw MediaError.decodeFailed("receive_frame: \(avErrorString(r))") }

            if sentFlushPacket { return nil }
            let rr = av_read_frame(format.ctx, packet)
            if rr < 0 {
                // End of file (or read error): drain the decoder.
                sentFlushPacket = true
                _ = avcodec_send_packet(codec, nil)
                continue
            }
            defer { av_packet_unref(packet) }
            guard Int(packet.pointee.stream_index) == streamIndex else { continue }
            atStart = false
            let s = avcodec_send_packet(codec, packet)
            if s < 0 && s != avErrorEAGAIN {
                // Corrupt packet: skip it, like ffmpeg does, unless hardware refuses everything.
                if usingHardware && current == nil && pending == nil {
                    throw MediaError.decodeFailed("send_packet: \(avErrorString(s))")
                }
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
