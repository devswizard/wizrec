// Audio decoding of one stream with libav, conversion to Float32 planar, and a
// stateless windowed-sinc resampler (each output sample is a pure function of
// its stream time, so consecutive requests join without clicks).

import CFFmpeg
import CoreMedia
import Foundation

/// Decodes one audio stream to PCM. Runs on a private serial queue (blocking libav work).
actor AudioDecoder {
    nonisolated let streamIndex: Int
    private let queue: DispatchSerialQueue
    private let core: AudioDecodeCore
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// `streamIndex`: libav (container) index. `trim`: leading samples to drop (AAC priming);
    /// `length`: valid samples after the trim, when known.
    init(url: URL, streamIndex: Int, trim: Int64 = 0, length: Int64? = nil) throws {
        self.streamIndex = streamIndex
        self.queue = DispatchSerialQueue(label: "wizrec.media.audio.\(streamIndex)", qos: .userInitiated)
        self.core = try AudioDecodeCore(url: url, streamIndex: streamIndex, trim: trim, length: length)
    }

    /// PCM for `range` (stream time), resampled to `format`, silence outside the stream.
    func pcm(range: CMTimeRange, format: PCMFormat) throws -> PCMBuffer {
        try core.pcm(range: range, format: format)
    }
}

/// libav state behind an `AudioDecoder`. Not thread-safe; confined to the actor.
final class AudioDecodeCore {
    let streamIndex: Int
    let clock: StreamClock
    /// Native sample rate (Hz) and channel count of the stream.
    let sourceRate: Double
    let sourceChannels: Int

    private let format: FormatContext
    private let codec: UnsafeMutablePointer<AVCodecContext>
    private let packet: UnsafeMutablePointer<AVPacket>
    private let frame: UnsafeMutablePointer<AVFrame>

    /// Decoded samples per channel, covering source sample indices [bufStart, bufStart + count).
    private var buf: [[Float]]
    private var bufStart: Int64 = 0
    /// Decoder continues contiguously after the buffer end (no seek needed to extend it).
    private var positioned = false
    private var flushed = false
    /// Sample index where decoding hit end of stream, once known.
    private var endSample: Int64?

    /// Source samples decoded before the requested region after a seek (decoder warm-up).
    private let preroll: Int64 = 4096

    /// Decoded samples dropped from the start (priming); sample 0 = decoded sample `trim`.
    let trim: Int64
    /// Valid sample count, when known; later samples are silence.
    let validLength: Int64?

    init(url: URL, streamIndex: Int, trim: Int64, length: Int64?) throws {
        self.streamIndex = streamIndex
        self.trim = max(0, trim)
        self.validLength = length
        let fc = try FormatContext(url: url)
        guard let st = fc.stream(streamIndex), let par = st.pointee.codecpar,
              par.pointee.codec_type == AVMEDIA_TYPE_AUDIO
        else { throw MediaError.noSuchStream(streamIndex) }
        fc.discardAll(except: streamIndex)
        format = fc
        // Stream time 0 = movie time 0 (edit lists applied by libav), minus `trim` samples.
        clock = StreamClock(timeBase: st.pointee.time_base, origin: 0)
        guard let dec = avcodec_find_decoder(par.pointee.codec_id) else {
            throw MediaError.unsupported("no decoder for \(codecName(par.pointee.codec_id))")
        }
        guard let ctx = avcodec_alloc_context3(dec) else { throw MediaError.decodeFailed("avcodec_alloc_context3") }
        var c: UnsafeMutablePointer<AVCodecContext>? = ctx
        guard avcodec_parameters_to_context(ctx, par) >= 0 else {
            avcodec_free_context(&c); throw MediaError.decodeFailed("parameters_to_context")
        }
        // Lets the decoder shift frame timestamps when it drops priming (skip-samples) audio.
        ctx.pointee.pkt_timebase = st.pointee.time_base
        let rc = avcodec_open2(ctx, dec, nil)
        guard rc >= 0 else { avcodec_free_context(&c); throw MediaError.decodeFailed("avcodec_open2: \(avErrorString(rc))") }
        guard let pkt = av_packet_alloc(), let frm = av_frame_alloc() else {
            avcodec_free_context(&c); throw MediaError.decodeFailed("alloc")
        }
        codec = ctx; packet = pkt; frame = frm
        sourceRate = Double(max(1, ctx.pointee.sample_rate))
        sourceChannels = max(1, Int(ctx.pointee.ch_layout.nb_channels))
        buf = Array(repeating: [], count: sourceChannels)
    }

    deinit {
        var c: UnsafeMutablePointer<AVCodecContext>? = codec
        avcodec_free_context(&c)
        var p: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&p)
        var f: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&f)
    }

    private var bufEnd: Int64 { bufStart + Int64(buf[0].count) }

    // MARK: - Request

    func pcm(range: CMTimeRange, format out: PCMFormat) throws -> PCMBuffer {
        guard out.sampleRate > 0, out.channels > 0 else { throw MediaError.unsupported("invalid PCM format") }
        let start = range.start.isNumeric ? range.start : .zero
        let durSec = range.duration.isNumeric ? max(0, range.duration.seconds) : 0
        let n = Int((durSec * out.sampleRate).rounded())
        guard n > 0 else {
            return PCMBuffer(format: out, startTime: start, frameCount: 0, channels: Array(repeating: [], count: out.channels))
        }
        let t0 = start.seconds
        let ratio = out.sampleRate / sourceRate
        let p0 = t0 * sourceRate                // source position of output sample 0
        let step = sourceRate / out.sampleRate  // source samples per output sample

        var src: [[Float]]
        let p0Round = p0.rounded()
        if ratio == 1, abs(p0 - p0Round) < 1e-6 {
            let a = Int64(p0Round)
            src = try fetch(a, a + Int64(n))
        } else {
            let k = Resampler.kernel(cutoff: min(1, ratio))
            let lo = Int64((p0 - k.halfWidth).rounded(.down)) - 1
            let hi = Int64((p0 + Double(n - 1) * step + k.halfWidth).rounded(.up)) + 2
            let input = try fetch(lo, hi)
            src = Resampler.resample(input, inputStart: lo, p0: p0, step: step, count: n, kernel: k)
        }
        return PCMBuffer(format: out, startTime: start, frameCount: n, channels: Self.mapChannels(src, to: out.channels, count: n))
    }

    static func mapChannels(_ src: [[Float]], to channels: Int, count n: Int) -> [[Float]] {
        if src.count == channels { return src }
        if channels == 1 {
            var mono = [Float](repeating: 0, count: n)
            let g = 1 / Float(src.count)
            for ch in src { for i in 0..<n { mono[i] += ch[i] * g } }
            return [mono]
        }
        if src.count == 1 { return Array(repeating: src[0], count: channels) }
        return (0..<channels).map { $0 < src.count ? src[$0] : [Float](repeating: 0, count: n) }
    }

    // MARK: - Source samples

    /// Source samples [a, b) per channel; zeros outside the decoded stream.
    private func fetch(_ a: Int64, _ b: Int64) throws -> [[Float]] {
        let count = Int(b - a)
        var out = Array(repeating: [Float](repeating: 0, count: count), count: sourceChannels)
        let lo = max(a, 0)
        var hi = endSample.map { min(b, $0) } ?? b
        if let v = validLength { hi = min(hi, v) }
        if lo < hi {
            try ensureDecoded(lo, hi)
            let s = max(lo, bufStart), e = min(hi, bufEnd)
            if s < e {
                for ch in 0..<sourceChannels {
                    let srcOff = Int(s - bufStart), dstOff = Int(s - a), len = Int(e - s)
                    buf[ch].withUnsafeBufferPointer { sp in
                        out[ch].withUnsafeMutableBufferPointer { dp in
                            guard let sb = sp.baseAddress, let db = dp.baseAddress else { return }
                            (db + dstOff).update(from: sb + srcOff, count: len)
                        }
                    }
                }
            }
        }
        return out
    }

    private func ensureDecoded(_ lo: Int64, _ hi: Int64) throws {
        let haveData = !buf[0].isEmpty
        if haveData && lo >= bufStart && hi <= bufEnd { return }
        let canContinue = haveData && positioned && lo >= bufStart && lo <= bufEnd + Int64(sourceRate)
        if !canContinue {
            try seek(toSample: max(0, lo - preroll))
        } else {
            trim(before: lo - preroll)
        }
        while bufEnd < hi || buf[0].isEmpty {
            if try !decodeFrame() {
                endSample = buf[0].isEmpty ? 0 : bufEnd
                break
            }
        }
    }

    private func trim(before s: Int64) {
        let drop = Int(s - bufStart)
        guard drop > 0, drop < buf[0].count else { return }
        for ch in 0..<sourceChannels { buf[ch].removeFirst(drop) }
        bufStart += Int64(drop)
    }

    private func seek(toSample s: Int64) throws {
        for ch in 0..<sourceChannels { buf[ch].removeAll(keepingCapacity: true) }
        bufStart = 0
        positioned = true
        flushed = false
        avcodec_flush_buffers(codec)
        var ts = clock.ticks(seconds: Double(s + trim) / sourceRate)
        let idx = Int32(streamIndex)
        if s <= 0, let st = format.stream(streamIndex) {
            // From the very first packet, so libav re-applies the start-of-stream priming skip
            // (a seek into the priming region skips the wrong amount).
            ts = avformat_index_get_entries_count(st) > 0 ? (avformat_index_get_entry(st, 0)?.pointee.timestamp ?? Int64.min) : Int64.min
        }
        var rc = avformat_seek_file(format.ctx, idx, Int64.min, ts, ts, 0)
        if rc < 0 { rc = av_seek_frame(format.ctx, idx, ts, AVSEEK_FLAG_BACKWARD) }
        if rc < 0 { rc = av_seek_frame(format.ctx, idx, ts, AVSEEK_FLAG_BACKWARD | AVSEEK_FLAG_ANY) }
        if rc < 0 { throw MediaError.decodeFailed("audio seek failed: \(avErrorString(rc))") }
    }

    /// Decodes one frame into the buffer. False at end of stream.
    private func decodeFrame() throws -> Bool {
        while true {
            let r = avcodec_receive_frame(codec, frame)
            if r == 0 {
                defer { av_frame_unref(frame) }
                append(frame)
                return true
            }
            if r == avErrorEOF { return false }
            guard r == avErrorEAGAIN else { throw MediaError.decodeFailed("audio receive_frame: \(avErrorString(r))") }
            if flushed { return false }
            if av_read_frame(format.ctx, packet) < 0 {
                flushed = true
                _ = avcodec_send_packet(codec, nil)
                continue
            }
            defer { av_packet_unref(packet) }
            guard Int(packet.pointee.stream_index) == streamIndex else { continue }
            _ = avcodec_send_packet(codec, packet) // corrupt packets are skipped
        }
    }

    private func append(_ f: UnsafeMutablePointer<AVFrame>) {
        let n = Int(f.pointee.nb_samples)
        guard n > 0 else { return }
        var pts = f.pointee.best_effort_timestamp
        if pts == avNoPTS { pts = f.pointee.pts }
        var start: Int64 = buf[0].isEmpty ? 0 : bufEnd
        if pts != avNoPTS {
            start = Int64((clock.seconds(pts) * sourceRate).rounded()) - trim
        }
        if buf[0].isEmpty {
            bufStart = start
        } else {
            let end = bufEnd
            if abs(start - end) <= 2 {
                start = end // timestamp jitter: treat as contiguous
            } else if start > end {
                let gap = Int(start - end)
                for ch in 0..<sourceChannels { buf[ch].append(contentsOf: repeatElement(0, count: gap)) }
            } else {
                let keep = max(0, Int(start - bufStart))
                for ch in 0..<sourceChannels { buf[ch].removeLast(buf[ch].count - keep) }
                if keep == 0 { bufStart = start }
            }
        }
        let chans = min(sourceChannels, Int(f.pointee.ch_layout.nb_channels))
        guard let ext = f.pointee.extended_data else { return }
        let fmt = AVSampleFormat(f.pointee.format)
        let planar = av_sample_fmt_is_planar(fmt) != 0
        let packed = av_get_packed_sample_fmt(fmt)
        let stride = planar ? 1 : Int(f.pointee.ch_layout.nb_channels)
        for ch in 0..<sourceChannels {
            guard ch < chans, let plane = ext[planar ? ch : 0] else {
                buf[ch].append(contentsOf: repeatElement(0, count: n)); continue
            }
            let off = planar ? 0 : ch
            let old = buf[ch].count
            buf[ch].append(contentsOf: repeatElement(0, count: n))
            let raw = UnsafeRawPointer(plane)
            // Per-sample conversion into the grown buffer through a pointer (`while`, not
            // `append` per sample: debug builds paid an array call per sample; AUD12-2).
            buf[ch].withUnsafeMutableBufferPointer { (bp: inout UnsafeMutableBufferPointer<Float>) -> Void in
                guard let base = bp.baseAddress else { return }
                Self.convert(raw, packed, n, stride, off, into: base + old)
            }
        }
    }

    /// Converts sample `off`, `off + stride`, … (n of them) of `raw` in format `fmt` to Float into `d`
    /// (zeros for unknown formats).
    private static func convert(_ raw: UnsafeRawPointer, _ fmt: AVSampleFormat, _ n: Int, _ stride: Int, _ off: Int,
                                into d: UnsafeMutablePointer<Float>) {
        var i = 0
        switch fmt {
        case AV_SAMPLE_FMT_FLT:
            let p = raw.assumingMemoryBound(to: Float.self)
            while i < n { d[i] = p[i * stride + off]; i += 1 }
        case AV_SAMPLE_FMT_S16:
            let p = raw.assumingMemoryBound(to: Int16.self)
            while i < n { d[i] = Float(p[i * stride + off]) / 32768; i += 1 }
        case AV_SAMPLE_FMT_S32:
            let p = raw.assumingMemoryBound(to: Int32.self)
            while i < n { d[i] = Float(Double(p[i * stride + off]) / 2147483648); i += 1 }
        case AV_SAMPLE_FMT_DBL:
            let p = raw.assumingMemoryBound(to: Double.self)
            while i < n { d[i] = Float(p[i * stride + off]); i += 1 }
        case AV_SAMPLE_FMT_U8:
            let p = raw.assumingMemoryBound(to: UInt8.self)
            while i < n { d[i] = (Float(p[i * stride + off]) - 128) / 128; i += 1 }
        case AV_SAMPLE_FMT_S64:
            let p = raw.assumingMemoryBound(to: Int64.self)
            while i < n { d[i] = Float(Double(p[i * stride + off]) / 9223372036854775808); i += 1 }
        default:
            break
        }
    }
}

/// Windowed-sinc (Blackman) interpolation from a table.
enum Resampler {
    /// Zero crossings on each side of the kernel centre (at cutoff 1).
    static let zeroCrossings = 16
    static let tableResolution = 512

    struct Kernel: Sendable {
        let cutoff: Double
        /// Support radius in source samples.
        let halfWidth: Double
        let table: [Float]
    }

    /// Normalised sinc·Blackman over u ∈ [0, zeroCrossings], u = cutoff · x.
    static let table: [Float] = {
        let z = Double(zeroCrossings), n = zeroCrossings * tableResolution
        return (0...n).map { i in
            let u = Double(i) / Double(tableResolution)
            let sinc = u == 0 ? 1 : sin(Double.pi * u) / (Double.pi * u)
            let w = 0.42 + 0.5 * cos(Double.pi * u / z) + 0.08 * cos(2 * Double.pi * u / z)
            return Float(sinc * w)
        } + [0]
    }()

    static func kernel(cutoff: Double) -> Kernel {
        Kernel(cutoff: cutoff, halfWidth: Double(zeroCrossings) / cutoff, table: table)
    }

    /// Output sample k = Σ x[i]·h(p0 + k·step − i), normalised by Σ h, for every channel of `x`
    /// (all `x[c]` the same length). The taps of each output sample are computed once and shared
    /// by all channels, in the same pass that sums them (ascending `i`, as resampling the channels
    /// one by one would), so the result is bit-identical to the per-channel textbook loop. Plain
    /// pointer `while` loops: no per-sample allocation and no generic calls, which debug builds
    /// would otherwise pay per tap (AUD12-1/2).
    static func resample(_ x: [[Float]], inputStart: Int64, p0: Double, step: Double, count n: Int,
                         kernel k: Kernel) -> [[Float]] {
        let channels = x.count
        guard n > 0, let len = x.first?.count, len > 0 else {
            return Array(repeating: [Float](repeating: 0, count: max(0, n)), count: channels)
        }
        // Contiguous channel-major copies of the input (zero-padded to `len`) and the output.
        let flatIn = UnsafeMutablePointer<Float>.allocate(capacity: channels * len)
        let flatOut = UnsafeMutablePointer<Float>.allocate(capacity: channels * n)
        defer { flatIn.deallocate(); flatOut.deallocate() }
        flatOut.initialize(repeating: 0, count: channels * n)
        for c in 0..<channels {
            let dst: UnsafeMutablePointer<Float> = flatIn + c * len
            x[c].withUnsafeBufferPointer { (sp: UnsafeBufferPointer<Float>) -> Void in
                let m = Swift.min(len, sp.count)
                if let sb = sp.baseAddress, m > 0 { dst.initialize(from: sb, count: m) } else { dst.initialize(repeating: 0, count: len); return }
                if m < len { (dst + m).initialize(repeating: 0, count: len - m) }
            }
        }
        k.table.withUnsafeBufferPointer { (tb: UnsafeBufferPointer<Float>) -> Void in
            guard let tp = tb.baseAddress else { return }
            let pass = ResamplePass(table: tp, halfWidth: k.halfWidth, cutoff: k.cutoff, p0: p0, step: step,
                                    start: Double(inputStart), length: len)
            switch channels {
            case 1: pass.mono(flatIn, flatOut, n)
            case 2: pass.stereo(flatIn, flatIn + len, flatOut, flatOut + n, n)
            default: pass.any(flatIn, flatOut, channels, n)
            }
        }
        return (0..<channels).map { (c: Int) -> [Float] in Array(UnsafeBufferPointer(start: flatOut + c * n, count: n)) }
    }
}

/// One resampling pass over raw buffers (`Resampler.resample`). For output j the read position is
/// p = p0 + j·step − start; the taps are the inputs i in [⌈p − hw⌉, ⌊p + hw⌋] ∩ [0, length) with
/// u = |p − i|·cutoff < zeroCrossings, weight = table lerp at u·resolution. Every variant sums
/// in ascending i and divides by the weight sum, so all variants agree bit for bit.
private struct ResamplePass {
    let table: UnsafePointer<Float>
    let halfWidth: Double
    let cutoff: Double
    let p0: Double
    let step: Double
    let start: Double
    let length: Int
    let res = Double(Resampler.tableResolution)
    let maxU = Double(Resampler.zeroCrossings)

    /// Read position and tap range [lo, hi] of output j (empty when lo > hi).
    @inline(__always) func taps(_ j: Int) -> (p: Double, lo: Int, hi: Int) {
        let p: Double = p0 + Double(j) * step - start
        var lo = Int((p - halfWidth).rounded(.up))
        if lo < 0 { lo = 0 }
        var hi = Int((p + halfWidth).rounded(.down))
        if hi > length - 1 { hi = length - 1 }
        return (p, lo, hi)
    }

    /// Weight of input i for read position p, or nil outside the kernel's support.
    @inline(__always) func weight(_ p: Double, _ i: Int) -> Float? {
        let d: Double = p - Double(i)
        let u: Double = (d < 0 ? -d : d) * cutoff
        guard u < maxU else { return nil }
        let fi: Double = u * res
        let ii = Int(fi)
        let frac = Float(fi - Double(ii))
        let a: Float = table[ii]
        return a + (table[ii + 1] - a) * frac
    }

    func mono(_ x: UnsafePointer<Float>, _ out: UnsafeMutablePointer<Float>, _ n: Int) {
        var j = 0
        while j < n {
            let (p, lo, hi) = taps(j)
            var acc: Float = 0, wsum: Float = 0
            var i = lo
            while i <= hi {
                // `weight(p, i)`, written out: debug builds do not inline it.
                let d: Double = p - Double(i)
                let u: Double = (d < 0 ? -d : d) * cutoff
                if u < maxU {
                    let fi: Double = u * res
                    let ii = Int(fi)
                    let frac = Float(fi - Double(ii))
                    let a: Float = table[ii]
                    let w: Float = a + (table[ii + 1] - a) * frac
                    wsum += w; acc += x[i] * w
                }
                i += 1
            }
            if wsum > 1e-6 { out[j] = acc / wsum }
            j += 1
        }
    }

    func stereo(_ x0: UnsafePointer<Float>, _ x1: UnsafePointer<Float>,
                _ o0: UnsafeMutablePointer<Float>, _ o1: UnsafeMutablePointer<Float>, _ n: Int) {
        var j = 0
        while j < n {
            let (p, lo, hi) = taps(j)
            var a0: Float = 0, a1: Float = 0, wsum: Float = 0
            var i = lo
            while i <= hi {
                // `weight(p, i)`, written out: debug builds do not inline it.
                let d: Double = p - Double(i)
                let u: Double = (d < 0 ? -d : d) * cutoff
                if u < maxU {
                    let fi: Double = u * res
                    let ii = Int(fi)
                    let frac = Float(fi - Double(ii))
                    let a: Float = table[ii]
                    let w: Float = a + (table[ii + 1] - a) * frac
                    wsum += w; a0 += x0[i] * w; a1 += x1[i] * w
                }
                i += 1
            }
            if wsum > 1e-6 { o0[j] = a0 / wsum; o1[j] = a1 / wsum }
            j += 1
        }
    }

    /// Any channel count: weights of output j into scratch, then each channel's sum.
    func any(_ x: UnsafePointer<Float>, _ out: UnsafeMutablePointer<Float>, _ channels: Int, _ n: Int) {
        let cap = Int(2 * halfWidth) + 3
        let index = UnsafeMutablePointer<Int>.allocate(capacity: cap)
        let weights = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        defer { index.deallocate(); weights.deallocate() }
        var j = 0
        while j < n {
            let (p, lo, hi) = taps(j)
            var m = 0
            var wsum: Float = 0
            var i = lo
            while i <= hi {
                if let w = weight(p, i) { index[m] = i; weights[m] = w; wsum += w; m += 1 }
                i += 1
            }
            if wsum > 1e-6 {
                var c = 0
                while c < channels {
                    let xs = x + c * length
                    var acc: Float = 0
                    var t = 0
                    while t < m { acc += xs[index[t]] * weights[t]; t += 1 }
                    out[c * n + j] = acc / wsum
                    c += 1
                }
            }
            j += 1
        }
    }
}
