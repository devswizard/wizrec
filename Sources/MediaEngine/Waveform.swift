// Waveform peaks: one streaming decode of an audio stream into a ~1 ms min/max envelope
// (the "base" level), cached in memory and on disk; any requested resolution is
// re-bucketed from it without decoding again.

import CFFmpeg
import CoreMedia
import CryptoKit
import Foundation

/// Min/max envelope of an audio stream (all channels together), for timeline waveforms.
///
/// Bucket `i` covers stream time `[i, i + 1) / bucketsPerSecond` seconds. Values are linear
/// sample values (full scale ±1). Buckets past the end of the audio are not included;
/// silence (and a leading empty edit) is `0, 0`.
public struct WaveformPeaks: Sendable, Equatable {
    /// Buckets per second of stream time.
    public var bucketsPerSecond: Double
    /// Lowest sample per bucket (≤ 0 for real audio).
    public var min: [Float]
    /// Highest sample per bucket.
    public var max: [Float]
    /// Number of buckets.
    public var count: Int { min.count }

    public init(bucketsPerSecond: Double, min: [Float], max: [Float]) {
        self.bucketsPerSecond = bucketsPerSecond; self.min = min; self.max = max
    }
}

/// Full-stream envelope at a fixed number of source samples per bucket.
struct BasePeaks: Sendable, Equatable {
    var sampleRate: Double
    var samplesPerBucket: Int
    /// Source samples covered (the last bucket may be partial).
    var sampleCount: Int64
    var min: [Float]
    var max: [Float]

    var bytes: Int { (min.count + max.count) * MemoryLayout<Float>.size }

    /// Highest resolution served (base buckets per second).
    var bucketsPerSecond: Double { sampleRate / Double(samplesPerBucket) }

    /// Source samples per base bucket: ~1 ms.
    static func samplesPerBucket(rate: Double) -> Int { Swift.max(1, Int(rate / 1000)) }

    /// Re-buckets to `bps` buckets per second (≤ `bucketsPerSecond`): each base bucket goes to
    /// the output bucket containing its centre, so edges are exact to half a base bucket (~0.5 ms).
    func resampled(bucketsPerSecond bps: Double) -> WaveformPeaks {
        let n0 = min.count
        guard bps > 0, n0 > 0, sampleCount > 0 else { return WaveformPeaks(bucketsPerSecond: bps, min: [], max: []) }
        let samplesPerOut = sampleRate / bps
        let n = Swift.max(1, Int((Double(sampleCount) / samplesPerOut).rounded(.up)))
        var lo = [Float](repeating: 0, count: n), hi = [Float](repeating: 0, count: n)
        var filled = [Bool](repeating: false, count: n)
        let spb = Double(samplesPerBucket)
        min.withUnsafeBufferPointer { mn in
            max.withUnsafeBufferPointer { mx in
                for k in 0..<n0 {
                    let j = Swift.min(n - 1, Int(((Double(k) + 0.5) * spb) / samplesPerOut))
                    if filled[j] {
                        if mn[k] < lo[j] { lo[j] = mn[k] }
                        if mx[k] > hi[j] { hi[j] = mx[k] }
                    } else {
                        lo[j] = mn[k]; hi[j] = mx[k]; filled[j] = true
                    }
                }
                for j in 0..<n where !filled[j] {
                    let k = Swift.min(n0 - 1, Int((Double(j) + 0.5) * samplesPerOut / spb))
                    lo[j] = mn[k]; hi[j] = mx[k]
                }
            }
        }
        return WaveformPeaks(bucketsPerSecond: bps, min: lo, max: hi)
    }
}

/// Decodes a whole audio stream once into `BasePeaks`, without buffering PCM.
enum PeakScanner {
    /// `streamIndex`: libav index; `trim`/`length`: as `StreamMap.audioTrim/audioLength`.
    static func scan(url: URL, streamIndex: Int, trim: Int64, length: Int64?) throws -> BasePeaks {
        let fc = try FormatContext(url: url)
        guard let st = fc.stream(streamIndex), let par = st.pointee.codecpar,
              par.pointee.codec_type == AVMEDIA_TYPE_AUDIO
        else { throw MediaError.noSuchStream(streamIndex) }
        fc.discardAll(except: streamIndex)
        guard let dec = avcodec_find_decoder(par.pointee.codec_id) else {
            throw MediaError.unsupported("no decoder for \(codecName(par.pointee.codec_id))")
        }
        guard let ctx = avcodec_alloc_context3(dec) else { throw MediaError.decodeFailed("avcodec_alloc_context3") }
        var ctxOpt: UnsafeMutablePointer<AVCodecContext>? = ctx
        defer { avcodec_free_context(&ctxOpt) }
        guard avcodec_parameters_to_context(ctx, par) >= 0 else { throw MediaError.decodeFailed("parameters_to_context") }
        ctx.pointee.pkt_timebase = st.pointee.time_base
        let rc = avcodec_open2(ctx, dec, nil)
        guard rc >= 0 else { throw MediaError.decodeFailed("avcodec_open2: \(avErrorString(rc))") }
        guard let pkt = av_packet_alloc(), let frame = av_frame_alloc() else { throw MediaError.decodeFailed("alloc") }
        var pktOpt: UnsafeMutablePointer<AVPacket>? = pkt
        var frameOpt: UnsafeMutablePointer<AVFrame>? = frame
        defer { av_packet_free(&pktOpt); av_frame_free(&frameOpt) }

        let rate = Double(max(1, ctx.pointee.sample_rate))
        let clock = StreamClock(timeBase: st.pointee.time_base, origin: 0)
        var acc = Accumulator(samplesPerBucket: BasePeaks.samplesPerBucket(rate: rate),
                              trim: max(0, trim), validLength: length)
        var flushed = false
        decode: while true {
            let r = avcodec_receive_frame(ctx, frame)
            if r == 0 {
                var pts = frame.pointee.best_effort_timestamp
                if pts == avNoPTS { pts = frame.pointee.pts }
                let start: Int64? = pts == avNoPTS ? nil : Int64((clock.seconds(pts) * rate).rounded())
                acc.add(frame, decodedStart: start)
                av_frame_unref(frame)
                if acc.isComplete { break }
                continue
            }
            if r == avErrorEOF { break }
            guard r == avErrorEAGAIN else { throw MediaError.decodeFailed("audio receive_frame: \(avErrorString(r))") }
            if flushed { break }
            if av_read_frame(fc.ctx, pkt) < 0 {
                flushed = true
                _ = avcodec_send_packet(ctx, nil)
                continue decode
            }
            if Int(pkt.pointee.stream_index) == streamIndex { _ = avcodec_send_packet(ctx, pkt) }
            av_packet_unref(pkt)
        }
        acc.finish()
        return BasePeaks(sampleRate: rate, samplesPerBucket: acc.samplesPerBucket, sampleCount: acc.sampleCount,
                         min: acc.mins, max: acc.maxs)
    }

    /// Folds decoded frames into buckets. Sample index 0 = decoded sample `trim`.
    struct Accumulator {
        let samplesPerBucket: Int
        let trim: Int64
        let validLength: Int64?
        var mins: [Float] = []
        var maxs: [Float] = []
        /// Next stream sample index (after trim).
        private var next: Int64 = 0
        private var started = false
        private var lo: Float = 0, hi: Float = 0
        private var inBucket = 0

        init(samplesPerBucket: Int, trim: Int64, validLength: Int64?) {
            self.samplesPerBucket = samplesPerBucket; self.trim = trim; self.validLength = validLength
        }

        var isComplete: Bool { validLength.map { next >= $0 } ?? false }
        var sampleCount: Int64 { next }

        private mutating func push(_ l: Float, _ h: Float) {
            if inBucket == 0 { lo = l; hi = h } else { if l < lo { lo = l }; if h > hi { hi = h } }
            inBucket += 1
            next += 1
            if inBucket == samplesPerBucket { mins.append(lo); maxs.append(hi); inBucket = 0 }
        }

        private mutating func silence(_ n: Int64) { for _ in 0..<n { push(0, 0) } }

        /// `decodedStart`: index of the frame's first sample in decoded samples (before trim).
        mutating func add(_ f: UnsafeMutablePointer<AVFrame>, decodedStart: Int64?) {
            let n = Int(f.pointee.nb_samples)
            guard n > 0, let ext = f.pointee.extended_data else { return }
            var start = decodedStart.map { $0 - trim } ?? next
            if !started {
                started = true
                if start > 0 { silence(start) } // leading empty edit
            } else if abs(start - next) <= 2 {
                start = next // timestamp jitter: contiguous
            } else if start > next {
                silence(start - next)
            }
            // Samples of this frame before `next` (overlap / priming) are skipped.
            let skip = Int(max(0, next - start))
            guard skip < n else { return }
            let chans = max(1, Int(f.pointee.ch_layout.nb_channels))
            let fmt = AVSampleFormat(f.pointee.format)
            let planar = av_sample_fmt_is_planar(fmt) != 0
            let packed = av_get_packed_sample_fmt(fmt)
            var end = n
            if let v = validLength { end = min(n, skip + Int(max(0, v - next))) }
            guard skip < end else { return }
            func value(_ ch: Int, _ i: Int) -> Float {
                guard let plane = ext[planar ? ch : 0] else { return 0 }
                let idx = planar ? i : i * chans + ch
                let raw = UnsafeRawPointer(plane)
                switch packed {
                case AV_SAMPLE_FMT_FLT: return raw.assumingMemoryBound(to: Float.self)[idx]
                case AV_SAMPLE_FMT_S16: return Float(raw.assumingMemoryBound(to: Int16.self)[idx]) / 32768
                case AV_SAMPLE_FMT_S32: return Float(Double(raw.assumingMemoryBound(to: Int32.self)[idx]) / 2147483648)
                case AV_SAMPLE_FMT_DBL: return Float(raw.assumingMemoryBound(to: Double.self)[idx])
                case AV_SAMPLE_FMT_U8: return (Float(raw.assumingMemoryBound(to: UInt8.self)[idx]) - 128) / 128
                case AV_SAMPLE_FMT_S64: return Float(Double(raw.assumingMemoryBound(to: Int64.self)[idx]) / 9223372036854775808)
                default: return 0
                }
            }
            if packed == AV_SAMPLE_FMT_FLT && planar {
                // Fast path: float planar (AAC, MP3 decoders).
                let planes = (0..<chans).compactMap { ext[$0].map { UnsafeRawPointer($0).assumingMemoryBound(to: Float.self) } }
                guard planes.count == chans else { return }
                for i in skip..<end {
                    var l = planes[0][i], h = l
                    if chans > 1 { for c in 1..<chans { let v = planes[c][i]; if v < l { l = v }; if v > h { h = v } } }
                    push(l, h)
                }
                return
            }
            for i in skip..<end {
                var l = value(0, i), h = l
                if chans > 1 { for c in 1..<chans { let v = value(c, i); if v < l { l = v }; if v > h { h = v } } }
                push(l, h)
            }
        }

        mutating func finish() {
            if inBucket > 0 { mins.append(lo); maxs.append(hi); inBucket = 0 }
        }
    }
}

/// On-disk peak cache: one small binary file per (file path, size, mtime, stream).
struct PeakDiskCache: Sendable {
    let directory: URL

    /// `~/Library/Caches/WizRec/peaks`.
    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("WizRec", isDirectory: true).appendingPathComponent("peaks", isDirectory: true)
    }

    /// Nil when `directory` lies inside a project bundle (never write caches into projects).
    init?(directory: URL) {
        if directory.standardizedFileURL.pathComponents.contains(where: { $0.lowercased().hasSuffix(".cmproj") }) { return nil }
        self.directory = directory
    }

    private static let magic: UInt32 = 0x4B50_5A57 // "WZPK"
    private static let version: UInt32 = 2
    private static let header = 32

    func fileURL(for url: URL, stream: Int) -> URL? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        else { return nil }
        let key = "\(url.standardizedFileURL.path)|\(size)|\(mtime)|\(stream)|v\(Self.version)"
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".wzpk")
    }

    func load(_ file: URL) -> BasePeaks? {
        guard let d = try? Data(contentsOf: file), d.count >= Self.header else { return nil }
        return d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> BasePeaks? in
            func u32(_ o: Int) -> UInt32 { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
            guard u32(0) == Self.magic, u32(4) == Self.version else { return nil }
            let rate = Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self)))
            let spb = Int(u32(16)), n = Int(u32(20))
            let samples = Int64(littleEndian: raw.loadUnaligned(fromByteOffset: 24, as: Int64.self))
            let h = Self.header
            guard rate > 0, spb > 0, samples >= 0, d.count == h + n * 8 else { return nil }
            var mn = [Float](repeating: 0, count: n), mx = [Float](repeating: 0, count: n)
            for i in 0..<n {
                mn[i] = Float(bitPattern: u32(h + i * 4))
                mx[i] = Float(bitPattern: u32(h + (n + i) * 4))
            }
            return BasePeaks(sampleRate: rate, samplesPerBucket: spb, sampleCount: samples, min: mn, max: mx)
        }
    }

    func store(_ p: BasePeaks, to file: URL) {
        var d = Data(capacity: Self.header + p.min.count * 8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        u32(Self.magic); u32(Self.version)
        withUnsafeBytes(of: p.sampleRate.bitPattern.littleEndian) { d.append(contentsOf: $0) }
        u32(UInt32(p.samplesPerBucket)); u32(UInt32(p.min.count))
        withUnsafeBytes(of: p.sampleCount.littleEndian) { d.append(contentsOf: $0) }
        for v in p.min { u32(v.bitPattern) }
        for v in p.max { u32(v.bitPattern) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try d.write(to: file, options: .atomic)
        } catch {
            // A cache write failure only costs a re-decode next time.
        }
    }
}
