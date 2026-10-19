// MediaSource implementations: libav-backed movies/recordings, still images, shaders.

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import VideoToolbox

/// Opens the right `MediaSource` for a probed file.
func openSource(_ probe: ProbeResult) throws -> any MediaSource {
    let info = probe.info
    switch info.kind {
    case .movie, .recording: return FFMediaSource(info: info, map: probe.map)
    case .image: return ImageSource(info: info)
    case .shader: return ShaderSource(info: info)
    case .unknown: throw MediaError.unsupported("unrecognised media: \(info.url.lastPathComponent)")
    }
}

/// A movie or `.trec` recording decoded with libav. One decoder actor per stream, created on first use.
actor FFMediaSource: MediaSource {
    nonisolated let info: MediaInfo
    nonisolated let map: StreamMap
    private var video: [Int: VideoStreamDecoder] = [:]
    private var audioDecoders: [Int: AudioDecoder] = [:]

    init(info: MediaInfo, map: StreamMap) { self.info = info; self.map = map }

    /// Container index of public stream `stream` after checking its kind.
    private func containerIndex(_ stream: Int, kind: StreamKind) throws -> Int {
        guard stream >= 0, stream < map.containerIndex.count,
              let s = info.streams.first(where: { $0.index == stream })
        else { throw MediaError.noSuchStream(stream) }
        guard s.kind == kind else { throw MediaError.unsupported("stream \(stream) is \(s.kind.rawValue), not \(kind.rawValue)") }
        return map.containerIndex[stream]
    }

    private func videoDecoder(_ stream: Int) throws -> VideoStreamDecoder {
        if let d = video[stream] { return d }
        let d = try VideoStreamDecoder(url: info.url, streamIndex: try containerIndex(stream, kind: .video))
        video[stream] = d
        return d
    }

    private func audioDecoder(_ stream: Int) throws -> AudioDecoder {
        if let d = audioDecoders[stream] { return d }
        let d = try AudioDecoder(url: info.url, streamIndex: try containerIndex(stream, kind: .audio),
                                 trim: map.audioTrim[stream] ?? 0, length: map.audioLength[stream])
        audioDecoders[stream] = d
        return d
    }

    func frame(stream: Int, at time: CMTime) async throws -> VideoFrame {
        try await videoDecoder(stream).frame(at: time)
    }

    func audio(stream: Int, range: CMTimeRange, format: PCMFormat) async throws -> PCMBuffer {
        try await audioDecoder(stream).pcm(range: range, format: format)
    }

    func thumbnail(stream: Int, at time: CMTime, maxPixelSize: Int) async throws -> CGImage {
        let f = try await frame(stream: stream, at: time)
        return try downscaledImage(f.pixelBuffer, maxPixelSize: maxPixelSize)
    }

    /// Number of video streams with open playback decoders (tests: thumbnails must not open any).
    var openVideoDecoders: Int { video.count }

    /// Measured decode rate of `stream` (pictures per busy second); nil when not decoded yet.
    func decodeRate(stream: Int) async -> Double? {
        guard let d = video[stream] else { return nil }
        return await d.decodeRate
    }

    /// True when `stream` decodes on VideoToolbox (opens the decoder if needed).
    func isHardwareAccelerated(stream: Int) async throws -> Bool {
        try await videoDecoder(stream).isHardwareAccelerated
    }

    /// Requests served by the hardware and software lanes of `stream` (diagnostics, tests).
    func laneCounts(stream: Int) async throws -> (hardware: Int, software: Int) {
        let d = try videoDecoder(stream)
        return (await d.hardwareServed, await d.softwareServed)
    }
}

/// A still image (or PDF page 1): every time returns the same frame (PTS 0, duration `.invalid`).
actor ImageSource: MediaSource {
    nonisolated let info: MediaInfo
    private var cached: VideoFrame?

    init(info: MediaInfo) { self.info = info }

    private func load() throws -> VideoFrame {
        if let c = cached { return c }
        let img = info.streams.first?.codec == "pdf" ? try renderPDF() : try decodeImage()
        let f = VideoFrame(pixelBuffer: try makePixelBuffer(from: img), presentationTime: .zero, duration: .invalid)
        cached = f
        return f
    }

    private func decodeImage() throws -> CGImage {
        let size = info.streams.first?.pixelSize ?? .zero
        let opts: [CFString: Any] = [
            // A full-size thumbnail with transform applies the EXIF orientation.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(Int(size.width), Int(size.height), 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let src = CGImageSourceCreateWithURL(info.url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { throw MediaError.decodeFailed("ImageIO cannot decode \(info.url.lastPathComponent)") }
        return img
    }

    /// Page 1 at its point size (1 pt = 1 px), on transparent background.
    private func renderPDF() throws -> CGImage {
        guard let doc = CGPDFDocument(info.url as CFURL), let page = doc.page(at: 1),
              let size = info.streams.first?.pixelSize, size.width >= 1, size.height >= 1,
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw MediaError.decodeFailed("cannot render PDF \(info.url.lastPathComponent)") }
        let rect = CGRect(origin: .zero, size: size)
        ctx.clear(rect)
        ctx.interpolationQuality = .high
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        guard let img = ctx.makeImage() else { throw MediaError.decodeFailed("cannot render PDF") }
        return img
    }

    func frame(stream: Int, at time: CMTime) async throws -> VideoFrame {
        guard stream == 0 else { throw MediaError.noSuchStream(stream) }
        return try load()
    }


    func audio(stream: Int, range: CMTimeRange, format: PCMFormat) async throws -> PCMBuffer {
        throw MediaError.noSuchStream(stream)
    }

    func thumbnail(stream: Int, at time: CMTime, maxPixelSize: Int) async throws -> CGImage {
        try downscaledImage(try await frame(stream: stream, at: time).pixelBuffer, maxPixelSize: maxPixelSize)
    }
}

/// A `.tscshadervid` source: metadata only; RenderEngine draws it.
final class ShaderSource: MediaSource {
    let info: MediaInfo
    init(info: MediaInfo) { self.info = info }

    func frame(stream: Int, at time: CMTime) async throws -> VideoFrame {
        throw MediaError.unsupported("shader sources have no decodable frames")
    }
    func audio(stream: Int, range: CMTimeRange, format: PCMFormat) async throws -> PCMBuffer {
        throw MediaError.noSuchStream(stream)
    }
    func thumbnail(stream: Int, at time: CMTime, maxPixelSize: Int) async throws -> CGImage {
        throw MediaError.unsupported("shader sources have no decodable frames")
    }
}

/// CGImage (sRGB) of `buffer`, scaled so its longer side is ≤ `maxPixelSize`.
func downscaledImage(_ buffer: CVPixelBuffer, maxPixelSize: Int) throws -> CGImage {
    var full: CGImage?
    VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &full)
    guard let full else { throw MediaError.decodeFailed("cannot make CGImage from frame") }
    let w = full.width, h = full.height
    let longer = max(w, h)
    let limit = max(1, maxPixelSize)
    if longer <= limit { return full }
    let scale = Double(limit) / Double(longer)
    let tw = max(1, Int((Double(w) * scale).rounded())), th = max(1, Int((Double(h) * scale).rounded()))
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { throw MediaError.decodeFailed("cannot create thumbnail context") }
    ctx.interpolationQuality = .high
    ctx.draw(full, in: CGRect(x: 0, y: 0, width: tw, height: th))
    guard let out = ctx.makeImage() else { throw MediaError.decodeFailed("cannot render thumbnail") }
    return out
}
