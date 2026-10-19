// Small helpers around the libav C API: macros Swift can't import, error text,
// timestamp conversion and an owned AVFormatContext opener.

import CFFmpeg
import CoreMedia
import Foundation

/// `AV_NOPTS_VALUE` (a macro Swift does not import).
let avNoPTS = Int64.min
/// `AVERROR(EAGAIN)`.
let avErrorEAGAIN: Int32 = -EAGAIN
/// `AVERROR_EOF` = `-MKTAG('E','O','F',' ')`.
let avErrorEOF: Int32 = -Int32(bitPattern: UInt32(0x45) | UInt32(0x4F) << 8 | UInt32(0x46) << 16 | UInt32(0x20) << 24)

/// Human-readable text for a libav error code.
func avErrorString(_ code: Int32) -> String {
    var buf = [CChar](repeating: 0, count: 256)
    av_strerror(code, &buf, buf.count)
    let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self) + " (\(code))"
}

/// Exact conversions between `CMTime` and integer ticks of a stream time base.
struct StreamClock: Sendable, Equatable {
    /// Seconds per tick = num / den.
    var num: Int64
    var den: Int64
    /// Tick value (in the stream time base) of stream time 0.
    var origin: Int64

    /// The time base as an `AVRational`.
    var avTimeBase: AVRational { AVRational(num: Int32(clamping: num), den: Int32(clamping: den)) }

    init(timeBase: AVRational, origin: Int64) {
        num = max(1, Int64(timeBase.num))
        den = max(1, Int64(timeBase.den))
        self.origin = origin
    }

    /// Largest tick `p` with `p` ≤ `time` (floor), in container ticks (origin added).
    func ticksFloor(_ time: CMTime) -> Int64 {
        guard time.isNumeric else {
            return time == .positiveInfinity ? Int64.max / 4 : origin
        }
        let v = time.value, s = Int64(time.timescale)
        // ticks = floor(v * den / (s * num))
        let (prod, o1) = v.multipliedReportingOverflow(by: den)
        let (div, o2) = s.multipliedReportingOverflow(by: num)
        if !o1 && !o2 && div > 0 {
            var q = prod / div
            if prod % div != 0 && prod < 0 { q -= 1 }
            return q + origin
        }
        return Int64((time.seconds * Double(den) / Double(num)).rounded(.down)) + origin
    }

    /// Stream time of a container tick value.
    func time(ofTicks ticks: Int64) -> CMTime {
        let rel = ticks - origin
        if num == 1, den <= Int64(Int32.max) {
            return CMTime(value: rel, timescale: Int32(den))
        }
        if den <= Int64(Int32.max) {
            let (v, o) = rel.multipliedReportingOverflow(by: num)
            if !o { return CMTime(value: v, timescale: Int32(den)) }
        }
        return CMTime(seconds: Double(rel) * Double(num) / Double(den), preferredTimescale: 705_600_000)
    }

    /// Duration in seconds of `ticks`.
    func seconds(_ ticks: Int64) -> Double { Double(ticks) * Double(num) / Double(den) }

    /// Ticks for `seconds` (rounded down).
    func ticks(seconds: Double) -> Int64 { Int64((seconds * Double(den) / Double(num)).rounded(.down)) }
}

/// Owns an `AVFormatContext` opened on a file, with stream info read.
final class FormatContext {
    let ctx: UnsafeMutablePointer<AVFormatContext>
    /// True when the extension's demuxer replaced the content-probed one.
    private(set) var usedExtensionHint = false

    /// Opens with libav's content probe. When the file's extension names a demuxer, the probed
    /// demuxer is not it (or the open fails), and the named demuxer opens the file with
    /// audio/video streams, that one wins: the content probe can misdetect valid files
    /// (e.g. a float WAV whose samples look like MPEG-TS sync bytes, scored 100 vs WAV's 99).
    init(url: URL) throws {
        let auto = Result { try Self.open(url, format: nil) }
        let hinted = Self.demuxer(forExtensionOf: url)
        if case .success(let c) = auto, let fmt = c.pointee.iformat,
           hinted == nil || fmt == hinted || Self.claimsExtension(fmt, url) {
            ctx = c
            return
        }
        if let hinted, let c = try? Self.open(url, format: hinted) {
            if Self.hasAudioVideo(c) {
                if case .success(let a) = auto { Self.close(a) }
                ctx = c
                usedExtensionHint = true
                return
            }
            Self.close(c)
        }
        ctx = try auto.get()
    }

    private static func close(_ c: UnsafeMutablePointer<AVFormatContext>) {
        var q: UnsafeMutablePointer<AVFormatContext>? = c
        avformat_close_input(&q)
    }

    private static func open(_ url: URL, format: UnsafePointer<AVInputFormat>?) throws -> UnsafeMutablePointer<AVFormatContext> {
        var p: UnsafeMutablePointer<AVFormatContext>? = nil
        let rc = avformat_open_input(&p, url.path, format, nil)
        guard rc >= 0, let opened = p else {
            throw MediaError.unsupported("libavformat cannot open \(url.lastPathComponent): \(avErrorString(rc))")
        }
        let rc2 = avformat_find_stream_info(opened, nil)
        if rc2 < 0 {
            close(opened)
            throw MediaError.unsupported("no stream info in \(url.lastPathComponent): \(avErrorString(rc2))")
        }
        return opened
    }

    /// True when `fmt` lists the file's extension.
    private static func claimsExtension(_ fmt: UnsafePointer<AVInputFormat>?, _ url: URL) -> Bool {
        guard let fmt, let exts = fmt.pointee.extensions else { return false }
        return av_match_ext(url.lastPathComponent, exts) > 0
    }

    /// The demuxer the file's extension names: the first registered demuxer listing it, else the
    /// demuxer named like the muxer libav picks for it (the `wav` demuxer lists no extensions).
    static func demuxer(forExtensionOf url: URL) -> UnsafePointer<AVInputFormat>? {
        guard !url.pathExtension.isEmpty else { return nil }
        var opaque: UnsafeMutableRawPointer? = nil
        while let fmt = av_demuxer_iterate(&opaque) {
            if claimsExtension(fmt, url) { return fmt }
        }
        guard let mux = av_guess_format(nil, url.lastPathComponent, nil), let name = mux.pointee.name else { return nil }
        return av_find_input_format(name)
    }

    private static func hasAudioVideo(_ c: UnsafeMutablePointer<AVFormatContext>) -> Bool {
        for i in 0..<Int(c.pointee.nb_streams) {
            guard let t = c.pointee.streams?[i]?.pointee.codecpar?.pointee.codec_type else { continue }
            if t == AVMEDIA_TYPE_AUDIO || t == AVMEDIA_TYPE_VIDEO { return true }
        }
        return false
    }

    deinit {
        var q: UnsafeMutablePointer<AVFormatContext>? = ctx
        avformat_close_input(&q)
    }

    var streamCount: Int { Int(ctx.pointee.nb_streams) }

    func stream(_ i: Int) -> UnsafeMutablePointer<AVStream>? {
        guard i >= 0, i < streamCount, let s = ctx.pointee.streams?[i] else { return nil }
        return s
    }

    /// Keep demuxing only stream `index`; all others are skipped.
    func discardAll(except index: Int) {
        for i in 0..<streamCount {
            stream(i)?.pointee.discard = (i == index) ? AVDISCARD_DEFAULT : AVDISCARD_ALL
        }
    }
}

/// libav codec name, e.g. `"h264"`.
func codecName(_ id: AVCodecID) -> String {
    guard let c = avcodec_get_name(id) else { return "unknown" }
    return String(cString: c)
}
