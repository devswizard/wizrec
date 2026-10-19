// Probing: decide the media kind and read stream metadata without decoding frames.
// Stream rules follow docs/specs/media-streams.md.

import CFFmpeg
import CoreGraphics
import CoreMedia
import Foundation
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

    static func probe(_ url: URL) throws -> MediaInfo { try probeDetailed(url).info }

    static func probeDetailed(_ url: URL) throws -> ProbeResult {
        guard FileManager.default.fileExists(atPath: url.path) else { throw MediaError.fileNotFound(url) }
        let ext = url.pathExtension.lowercased()
        func plain(_ info: MediaInfo) -> ProbeResult { ProbeResult(info: info, map: StreamMap(containerIndex: [0])) }
        if ext == shaderExtension {
            return ProbeResult(info: MediaInfo(url: url, kind: .shader, streams: [], duration: .zero), map: StreamMap())
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
        let stream = StreamInfo(index: 0, kind: .video, codec: codec == "jpg" ? "jpeg" : codec,
                                pixelSize: CGSize(width: w, height: h), duration: .zero)
        return MediaInfo(url: url, kind: .image, streams: [stream], duration: .zero)
    }

    /// PDF page 1 as a still; pixel size = page size in points (crop box, rotation applied).
    static func probePDF(_ url: URL) -> MediaInfo? {
        guard let size = pdfPixelSize(url) else { return nil }
        let stream = StreamInfo(index: 0, kind: .video, codec: "pdf", pixelSize: size, duration: .zero)
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

        var streams: [StreamInfo] = []
        var hasTSCC2 = false
        for (index, ci) in map.containerIndex.enumerated() {
            guard let st = fc.stream(ci), let par = st.pointee.codecpar else { continue }
            let codec = codecName(par.pointee.codec_id)
            if par.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                if par.pointee.codec_id == AV_CODEC_ID_TSCC2 { hasTSCC2 = true }
                let afr = st.pointee.avg_frame_rate
                var fps = afr.den > 0 && afr.num > 0 ? Double(afr.num) / Double(afr.den) : 0
                if fps == 0 {
                    let r = st.pointee.r_frame_rate
                    fps = r.den > 0 && r.num > 0 ? Double(r.num) / Double(r.den) : 0
                }
                streams.append(StreamInfo(index: index, kind: .video, codec: codec,
                                          pixelSize: CGSize(width: Int(par.pointee.width), height: Int(par.pointee.height)),
                                          nominalFrameRate: fps, duration: streamDuration(fc, st)))
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
                streams.append(StreamInfo(index: index, kind: .audio, codec: codec,
                                          sampleRate: Double(par.pointee.sample_rate),
                                          channelCount: Int(par.pointee.ch_layout.nb_channels),
                                          duration: duration))
            }
        }
        let kind: MediaKind = (url.pathExtension.lowercased() == recordingExtension || hasTSCC2) ? .recording : .movie
        let longest = streams.map(\.duration).filter(\.isNumeric).max() ?? .zero
        return ProbeResult(info: MediaInfo(url: url, kind: kind, streams: streams, duration: longest), map: map)
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
