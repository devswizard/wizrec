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

    init(url: URL) throws {
        var p: UnsafeMutablePointer<AVFormatContext>? = nil
        let rc = avformat_open_input(&p, url.path, nil, nil)
        guard rc >= 0, let opened = p else {
            throw MediaError.unsupported("libavformat cannot open \(url.lastPathComponent): \(avErrorString(rc))")
        }
        let rc2 = avformat_find_stream_info(opened, nil)
        if rc2 < 0 {
            var q: UnsafeMutablePointer<AVFormatContext>? = opened
            avformat_close_input(&q)
            throw MediaError.unsupported("no stream info in \(url.lastPathComponent): \(avErrorString(rc2))")
        }
        ctx = opened
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

/// Tick value of stream time 0: the stream's first presentation timestamp.
func streamOrigin(_ st: UnsafeMutablePointer<AVStream>) -> Int64 {
    let s = st.pointee.start_time
    return s == avNoPTS ? 0 : s
}
