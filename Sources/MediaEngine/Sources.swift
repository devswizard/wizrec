// MediaSource implementations: libav-backed movies/recordings, still images, shaders.

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import VideoToolbox

/// Opens the right `MediaSource` for a probed file.
func openSource(_ info: MediaInfo) throws -> any MediaSource {
    switch info.kind {
    case .movie, .recording: return FFMediaSource(info: info)
    case .image: return ImageSource(info: info)
    case .shader: return ShaderSource(info: info)
    case .unknown: throw MediaError.unsupported("unrecognised media: \(info.url.lastPathComponent)")
    }
}

/// A movie or `.trec` recording decoded with libav. One decoder actor per stream, created on first use.
actor FFMediaSource: MediaSource {
    nonisolated let info: MediaInfo
    private var video: [Int: VideoDecoder] = [:]
    private var audioDecoders: [Int: AudioDecoder] = [:]

    init(info: MediaInfo) { self.info = info }

    private func streamInfo(_ stream: Int, kind: StreamKind) throws -> StreamInfo {
        guard let s = info.streams.first(where: { $0.index == stream }) else { throw MediaError.noSuchStream(stream) }
        guard s.kind == kind else { throw MediaError.unsupported("stream \(stream) is \(s.kind.rawValue), not \(kind.rawValue)") }
        return s
    }

    private func videoDecoder(_ stream: Int) throws -> VideoDecoder {
        if let d = video[stream] { return d }
        _ = try streamInfo(stream, kind: .video)
        let d = try VideoDecoder(url: info.url, streamIndex: stream)
        video[stream] = d
        return d
    }

    private func audioDecoder(_ stream: Int) throws -> AudioDecoder {
        if let d = audioDecoders[stream] { return d }
        _ = try streamInfo(stream, kind: .audio)
        let d = try AudioDecoder(url: info.url, streamIndex: stream)
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

    /// True when `stream` decodes on VideoToolbox (opens the decoder if needed).
    func isHardwareAccelerated(stream: Int) async throws -> Bool {
        try await videoDecoder(stream).isHardwareAccelerated
    }
}

/// A still image: every time returns the same frame (PTS 0, duration `.invalid`).
actor ImageSource: MediaSource {
    nonisolated let info: MediaInfo
    private var cached: VideoFrame?

    init(info: MediaInfo) { self.info = info }

    private func load() throws -> VideoFrame {
        if let c = cached { return c }
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let src = CGImageSourceCreateWithURL(info.url as CFURL, nil),
              // A thumbnail at full size with transform applies EXIF orientation.
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(Int(info.streams.first?.pixelSize.width ?? 0),
                                                           Int(info.streams.first?.pixelSize.height ?? 0), 1),
                  kCGImageSourceShouldCacheImmediately: true,
              ].merging(opts) { a, _ in a } as CFDictionary)
        else { throw MediaError.decodeFailed("ImageIO cannot decode \(info.url.lastPathComponent)") }
        let f = VideoFrame(pixelBuffer: try makePixelBuffer(from: img), presentationTime: .zero, duration: .invalid)
        cached = f
        return f
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
