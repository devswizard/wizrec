// Probing: decide the media kind and read stream metadata without decoding frames.

import CFFmpeg
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Prober {
    static let shaderExtension = "tscshadervid"
    static let recordingExtension = "trec"

    static func probe(_ url: URL) throws -> MediaInfo {
        guard FileManager.default.fileExists(atPath: url.path) else { throw MediaError.fileNotFound(url) }
        let ext = url.pathExtension.lowercased()
        if ext == shaderExtension {
            return MediaInfo(url: url, kind: .shader, streams: [], duration: .zero)
        }
        if isImageExtension(ext), let info = probeImage(url) { return info }
        if let info = try? probeFFmpeg(url) { return info }
        if let info = probeImage(url) { return info }
        return MediaInfo(url: url, kind: .unknown, streams: [], duration: .zero)
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

    static func probeFFmpeg(_ url: URL) throws -> MediaInfo {
        let fc = try FormatContext(url: url)
        let fmtName = fc.ctx.pointee.iformat.map { String(cString: $0.pointee.name) } ?? ""
        // Image demuxers (png_pipe, image2, …) mean "this is a still"; let ImageIO handle it.
        if fmtName.hasSuffix("_pipe") || fmtName == "image2" { throw MediaError.unsupported("image") }
        var streams: [StreamInfo] = []
        var hasTSCC2 = false
        for i in 0..<fc.streamCount {
            guard let st = fc.stream(i), let par = st.pointee.codecpar else { continue }
            let codec = codecName(par.pointee.codec_id)
            let duration = streamDuration(fc, st)
            switch par.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                if par.pointee.codec_id == AV_CODEC_ID_TSCC2 { hasTSCC2 = true }
                let afr = st.pointee.avg_frame_rate
                var fps = afr.den > 0 && afr.num > 0 ? Double(afr.num) / Double(afr.den) : 0
                if fps == 0 {
                    let r = st.pointee.r_frame_rate
                    fps = r.den > 0 && r.num > 0 ? Double(r.num) / Double(r.den) : 0
                }
                streams.append(StreamInfo(index: i, kind: .video, codec: codec,
                                          pixelSize: CGSize(width: Int(par.pointee.width), height: Int(par.pointee.height)),
                                          nominalFrameRate: fps, duration: duration))
            case AVMEDIA_TYPE_AUDIO:
                streams.append(StreamInfo(index: i, kind: .audio, codec: codec,
                                          sampleRate: Double(par.pointee.sample_rate),
                                          channelCount: Int(par.pointee.ch_layout.nb_channels),
                                          duration: duration))
            default:
                streams.append(StreamInfo(index: i, kind: .other, codec: codec, duration: duration))
            }
        }
        guard streams.contains(where: { $0.kind != .other }) else { throw MediaError.unsupported("no audio/video streams") }
        let kind: MediaKind = (url.pathExtension.lowercased() == recordingExtension || hasTSCC2) ? .recording : .movie
        let longest = streams.map(\.duration).filter(\.isNumeric).max() ?? .zero
        return MediaInfo(url: url, kind: kind, streams: streams, duration: longest)
    }

    /// Length from the stream's first sample, preferring the stream's own duration.
    static func streamDuration(_ fc: FormatContext, _ st: UnsafeMutablePointer<AVStream>) -> CMTime {
        let clock = StreamClock(timeBase: st.pointee.time_base, origin: 0)
        let d = st.pointee.duration
        if d != avNoPTS, d > 0 { return clock.time(ofTicks: d) }
        let fd = fc.ctx.pointee.duration
        if fd != avNoPTS, fd > 0 {
            var secs = Double(fd) / Double(AV_TIME_BASE)
            let start = st.pointee.start_time
            if start != avNoPTS { secs -= clock.seconds(start) }
            let fs = fc.ctx.pointee.start_time
            if fs != avNoPTS { secs += Double(fs) / Double(AV_TIME_BASE) }
            return CMTime(seconds: max(0, secs), preferredTimescale: 705_600_000)
        }
        return .zero
    }
}
