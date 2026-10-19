// Probing: decide the media kind and read stream metadata without decoding frames.
// Stream rules follow docs/specs/media-streams.md.

import CFFmpeg
import CoreGraphics
import CoreMedia
import Foundation
import TSCProjKit
import ImageIO
import UniformTypeIdentifiers

/// How public stream indices map onto the container, plus per-stream timing fixes.
struct StreamMap: Sendable, Equatable {
    /// `containerIndex[i]` = libav stream index of public stream `i` (audio/video only).
    var containerIndex: [Int] = []
    /// Audio: leading samples to drop (AAC priming libav does not remove itself).
    var audioTrim: [Int: Int64] = [:]
    /// Audio: valid sample count after trimming, when known (gapless metadata / duration).
    var audioLength: [Int: Int64] = [:]
}

/// Probe result: public info plus what the decoders need.
struct ProbeResult: Sendable {
    var info: MediaInfo
    var map: StreamMap
}

enum Prober {
    static let shaderExtension = "tscshadervid"
    static let recordingExtension = "trec"
    /// AAC encoder delay (samples) of Apple/FFmpeg/most AAC encoders.
    static let aacPriming: Int64 = 2112

    static func probe(_ url: URL) async throws -> MediaInfo { try await probeDetailed(url).info }

    /// libav probe, then the `sourceTracks` timing (`timescale`/`length`) from AVFoundation where it
    /// can read the file — the presentation length Camtasia records [obs, media-streams.md §3].
    static func probeDetailed(_ url: URL) async throws -> ProbeResult {
        var r = try probeDetailedSync(url)
        if r.info.kind == .movie || r.info.kind == .recording {
            await TrackTiming.apply(to: &r.info)
        }
        return r
    }

    static func probeDetailedSync(_ url: URL) throws -> ProbeResult {
        guard FileManager.default.fileExists(atPath: url.path) else { throw MediaError.fileNotFound(url) }
        let ext = url.pathExtension.lowercased()
        func plain(_ info: MediaInfo) -> ProbeResult { ProbeResult(info: info, map: StreamMap(containerIndex: [0])) }
        if ext == shaderExtension {
            return ProbeResult(info: probeShader(url), map: StreamMap())
        }
        if ext == "pdf", let info = probePDF(url) { return plain(info) }
        if isImageExtension(ext), let info = probeImage(url) { return plain(info) }
        if let r = try? probeFFmpeg(url) { return r }
        if let info = probeImage(url) { return plain(info) }
        if let info = probePDF(url) { return plain(info) }
        return ProbeResult(info: MediaInfo(url: url, kind: .unknown, streams: [], duration: .zero), map: StreamMap())
    }

    static func isImageExtension(_ ext: String) -> Bool {
        guard !ext.isEmpty, let t = UTType(filenameExtension: ext) else { return false }
        return t.conforms(to: .image)
    }

    /// Single still frame; stream duration `.zero`.
    static func probeImage(_ url: URL) -> MediaInfo? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) > 0,
              let typeID = CGImageSourceGetType(src) as String?,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }
        if UTType(typeID)?.conforms(to: .pdf) == true { return nil }
        var w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        var h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        // EXIF orientations 5–8 swap width and height once applied.
        if let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(o) { swap(&w, &h) }
        guard w > 0, h > 0 else { return nil }
        let codec = UTType(typeID)?.preferredFilenameExtension ?? typeID
        let depth = (props[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8
        let stream = StreamInfo(index: 0, kind: .video, codec: codec == "jpg" ? "jpeg" : codec,
                                pixelSize: CGSize(width: w, height: h), duration: .zero,
                                timescale: 600, length: 1, bitsPerComponent: depth, trackType: 1)
        return MediaInfo(url: url, kind: .image, streams: [stream], duration: .zero)
    }

    /// PDF page 1 as a still; pixel size = page size in points (crop box, rotation applied).
    static func probePDF(_ url: URL) -> MediaInfo? {
        guard let size = pdfPixelSize(url) else { return nil }
        let stream = StreamInfo(index: 0, kind: .video, codec: "pdf", pixelSize: size, duration: .zero,
                                timescale: 600, length: 1, bitsPerComponent: 8, trackType: 1)
        return MediaInfo(url: url, kind: .image, streams: [stream], duration: .zero)
    }

    static func pdfPixelSize(_ url: URL) -> CGSize? {
        guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0, let page = doc.page(at: 1) else { return nil }
        var box = page.getBoxRect(.cropBox).standardized
        if page.rotationAngle % 180 != 0 { box = CGRect(x: 0, y: 0, width: box.height, height: box.width) }
        let w = box.width.rounded(), h = box.height.rounded()
        guard w >= 1, h >= 1 else { return nil }
        return CGSize(width: w, height: h)
    }

    static func probeFFmpeg(_ url: URL) throws -> ProbeResult {
        let fc = try FormatContext(url: url)
        let fmtName = fc.ctx.pointee.iformat.map { String(cString: $0.pointee.name) } ?? ""
        // Image demuxers (png_pipe, image2, …) mean "this is a still"; let ImageIO handle it.
        if fmtName.hasSuffix("_pipe") || fmtName == "image2" { throw MediaError.unsupported("image") }
        let isMOV = fmtName.contains("mov") || fmtName.contains("mp4")

        // Public streams = audio/video tracks in container order, minus cover art.
        var map = StreamMap()
        for i in 0..<fc.streamCount {
            guard let st = fc.stream(i), let par = st.pointee.codecpar else { continue }
            let type = par.pointee.codec_type
            guard type == AVMEDIA_TYPE_VIDEO || type == AVMEDIA_TYPE_AUDIO else { continue }
            if (st.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) != 0 { continue }
            map.containerIndex.append(i)
        }
        guard !map.containerIndex.isEmpty else { throw MediaError.unsupported("no audio/video streams") }

        let gapless = gaplessInfo(fc)
        let skipSeen = firstPacketHasSkipSamples(fc, streams: Set(map.containerIndex))

        var hasTSCC2 = url.pathExtension.lowercased() == recordingExtension
        for ci in map.containerIndex where fc.stream(ci)?.pointee.codecpar?.pointee.codec_id == AV_CODEC_ID_TSCC2 {
            hasTSCC2 = true
        }
        let isRecording = hasTSCC2
        var streams: [StreamInfo] = []
        for (index, ci) in map.containerIndex.enumerated() {
            guard let st = fc.stream(ci), let par = st.pointee.codecpar else { continue }
            let codec = codecName(par.pointee.codec_id)
            if par.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                var rate = st.pointee.avg_frame_rate
                if rate.den <= 0 || rate.num <= 0 { rate = st.pointee.r_frame_rate }
                let exact: Rational? = rate.den > 0 && rate.num > 0 ? Rational(Int64(rate.num), Int64(rate.den)) : nil
                let fps = exact.map { Double($0.num) / Double($0.den) } ?? 0
                let duration = streamDuration(fc, st)
                let (ts, len) = libavLength(st, duration: duration)
                let bpc = av_pix_fmt_desc_get(AVPixelFormat(par.pointee.format)).map { Int($0.pointee.comp.0.depth) } ?? 0
                streams.append(StreamInfo(index: index, kind: .video, codec: codec,
                                          pixelSize: CGSize(width: Int(par.pointee.width), height: Int(par.pointee.height)),
                                          nominalFrameRate: fps, duration: duration,
                                          timescale: ts, length: len, frameRate: exact,
                                          bitDepth: isRecording ? recordingVideoBitDepth : 0,
                                          bitsPerComponent: bpc, trackType: 0))
            } else {
                let rate = Int64(max(1, par.pointee.sample_rate))
                var duration = streamDuration(fc, st)
                if let g = gapless, par.pointee.codec_id == AV_CODEC_ID_AAC {
                    // iTunSMPB: libav skips the priming but keeps the timestamps, so trim it here.
                    map.audioTrim[index] = g.priming
                    if g.length > 0 {
                        map.audioLength[index] = g.length
                        duration = CMTime(value: g.length, timescale: Int32(clamping: rate))
                    }
                } else if isMOV, par.pointee.codec_id == AV_CODEC_ID_AAC, !skipSeen.contains(ci) {
                    // AAC in MP4/MOV without an edit list: the 2112 priming samples are still there.
                    map.audioTrim[index] = aacPriming
                    let d = st.pointee.duration
                    if d != avNoPTS, d > 0 {
                        let clock = StreamClock(timeBase: st.pointee.time_base, origin: 0)
                        let samples = Int64((clock.seconds(d) * Double(rate)).rounded()) - aacPriming
                        if samples > 0 {
                            map.audioLength[index] = samples
                            duration = CMTime(value: samples, timescale: Int32(clamping: rate))
                        }
                    }
                }
                let samples = map.audioLength[index]
                    ?? (duration.isNumeric ? Int64((duration.seconds * Double(rate)).rounded()) : 0)
                streams.append(StreamInfo(index: index, kind: .audio, codec: codec,
                                          sampleRate: Double(par.pointee.sample_rate),
                                          channelCount: Int(par.pointee.ch_layout.nb_channels),
                                          duration: duration,
                                          timescale: Int32(clamping: rate), length: max(0, samples),
                                          bitDepth: isRecording ? recordingAudioBitDepth : 0,
                                          bitsPerComponent: audioBits(par), trackType: 2))
            }
        }
        let kind: MediaKind = isRecording ? .recording : .movie
        let longest = streams.map(\.duration).filter(\.isNumeric).max() ?? .zero
        return ProbeResult(info: MediaInfo(url: url, kind: kind, streams: streams, duration: longest), map: map)
    }

    /// `sourceTracks.bitDepth` of `.trec` tracks [obs: demo recording; older recordings write 0 for video].
    static let recordingVideoBitDepth = 24
    static let recordingAudioBitDepth = 16

    /// Fallback `timescale`/`length` from libav when AVFoundation cannot read the file:
    /// the stream time base when it is 1/n, else the duration's own timescale.
    static func libavLength(_ st: UnsafeMutablePointer<AVStream>, duration: CMTime) -> (Int32, Int64) {
        let tb = st.pointee.time_base
        let d = st.pointee.duration
        if tb.num == 1, tb.den > 0, d != avNoPTS, d > 0 { return (tb.den, d) }
        guard duration.isNumeric, duration.timescale > 0, duration.value >= 0 else { return (0, 0) }
        return (duration.timescale, duration.value)
    }

    /// Bits per PCM sample (0 for lossy codecs that define none).
    static func audioBits(_ par: UnsafeMutablePointer<AVCodecParameters>) -> Int {
        let raw = Int(par.pointee.bits_per_raw_sample)
        if raw > 0 { return raw }
        let name = codecName(par.pointee.codec_id)
        return name.hasPrefix("pcm_") ? Int(par.pointee.bits_per_coded_sample) : 0
    }

    /// `.tscshadervid`: one endless video track (type 0, editRate 30, bitDepth 32) whose size is the
    /// JSON's `width`/`height` [obs, media-streams.md §7]. No decodable frames.
    static func probeShader(_ url: URL) -> MediaInfo {
        var size = CGSize.zero
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let w = (obj["width"] as? NSNumber)?.doubleValue ?? 0, h = (obj["height"] as? NSNumber)?.doubleValue ?? 0
            if w > 0, h > 0 { size = CGSize(width: w.rounded(), height: h.rounded()) }
        }
        let stream = StreamInfo(index: 0, kind: .video, codec: "tscshadervid", pixelSize: size, nominalFrameRate: 30,
                                duration: .positiveInfinity, timescale: 30, length: Int64.max,
                                frameRate: Rational(30), bitDepth: 32, bitsPerComponent: 8, trackType: 0)
        return MediaInfo(url: url, kind: .shader, streams: [stream], duration: .zero)
    }

    /// Length on the presentation timeline (edit lists applied; stream time 0 = movie time 0).
    static func streamDuration(_ fc: FormatContext, _ st: UnsafeMutablePointer<AVStream>) -> CMTime {
        let clock = StreamClock(timeBase: st.pointee.time_base, origin: 0)
        let d = st.pointee.duration
        if d != avNoPTS, d > 0 { return clock.time(ofTicks: d) }
        let fd = fc.ctx.pointee.duration
        if fd != avNoPTS, fd > 0 {
            var secs = Double(fd) / Double(AV_TIME_BASE)
            let fs = fc.ctx.pointee.start_time
            if fs != avNoPTS { secs += Double(fs) / Double(AV_TIME_BASE) }
            return CMTime(seconds: max(0, secs), preferredTimescale: 705_600_000)
        }
        return .zero
    }

    /// iTunes gapless metadata: priming (leading) samples and valid sample count.
    static func gaplessInfo(_ fc: FormatContext) -> (priming: Int64, length: Int64)? {
        guard let e = av_dict_get(fc.ctx.pointee.metadata, "iTunSMPB", nil, 0), let v = e.pointee.value else { return nil }
        let fields = String(cString: v).split(separator: " ").map(String.init)
        guard fields.count >= 4, let priming = Int64(fields[1], radix: 16), let length = Int64(fields[3], radix: 16) else { return nil }
        return (priming, length)
    }

    /// Container streams whose first packet carries skip-samples side data (libav trims them itself).
    static func firstPacketHasSkipSamples(_ fc: FormatContext, streams: Set<Int>) -> Set<Int> {
        var aac = Set<Int>()
        for i in streams {
            if fc.stream(i)?.pointee.codecpar?.pointee.codec_id == AV_CODEC_ID_AAC { aac.insert(i) }
        }
        guard !aac.isEmpty, let pkt = av_packet_alloc() else { return [] }
        var p: UnsafeMutablePointer<AVPacket>? = pkt
        defer { av_packet_free(&p) }
        var seen = Set<Int>(), result = Set<Int>()
        var n = 0
        while seen.count < aac.count, n < 2000, av_read_frame(fc.ctx, pkt) >= 0 {
            n += 1
            let si = Int(pkt.pointee.stream_index)
            if aac.contains(si), !seen.contains(si) {
                seen.insert(si)
                if av_packet_get_side_data(pkt, AV_PKT_DATA_SKIP_SAMPLES, nil) != nil { result.insert(si) }
            }
            av_packet_unref(pkt)
        }
        return result
    }
}
