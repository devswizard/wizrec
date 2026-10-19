// Public interface of MediaEngine, frozen by coordination/CONTRACTS.md.
// Changing anything here needs an API_CHANGE message and the lead's approval.

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// What a media file is, decided by probing its contents.
public enum MediaKind: String, Sendable, Equatable {
    /// AVFoundation-readable container (mp4, mov, m4a, wav, …).
    case movie
    /// `.trec` screen recording: QuickTime container whose screen stream is `tscc2` (decoded with libavcodec).
    case recording
    /// Still image (png, jpg, heic, gif first frame, …).
    case image
    /// `.tscshadervid` JSON shader; has no decodable frames, RenderEngine draws it.
    case shader
    case unknown
}

/// Elementary stream type.
public enum StreamKind: String, Sendable, Equatable {
    case video, audio, other
}

/// One elementary stream of a media file.
public struct StreamInfo: Sendable, Equatable {
    /// Position in container order. Equals a project clip's `trackNumber`.
    public var index: Int
    public var kind: StreamKind
    /// Codec name, e.g. `"h264"`, `"hevc"`, `"tscc2"`, `"aac"`, `"png"`.
    public var codec: String
    /// Frame size in pixels; `.zero` for audio.
    public var pixelSize: CGSize
    /// Frames per second; the average for variable-frame-rate streams; 0 for audio.
    public var nominalFrameRate: Double
    /// Samples per second; audio only, otherwise 0.
    public var sampleRate: Double
    /// Audio channel count; otherwise 0.
    public var channelCount: Int
    /// Stream length, measured from its first sample (stream time 0).
    public var duration: CMTime

    public init(index: Int, kind: StreamKind, codec: String, pixelSize: CGSize = .zero,
                nominalFrameRate: Double = 0, sampleRate: Double = 0, channelCount: Int = 0,
                duration: CMTime) {
        self.index = index; self.kind = kind; self.codec = codec; self.pixelSize = pixelSize
        self.nominalFrameRate = nominalFrameRate; self.sampleRate = sampleRate
        self.channelCount = channelCount; self.duration = duration
    }
}

/// Result of probing a file.
public struct MediaInfo: Sendable, Equatable {
    public var url: URL
    public var kind: MediaKind
    public var streams: [StreamInfo]
    /// Longest stream duration.
    public var duration: CMTime

    public init(url: URL, kind: MediaKind, streams: [StreamInfo], duration: CMTime) {
        self.url = url; self.kind = kind; self.streams = streams; self.duration = duration
    }
}

/// A decoded video frame.
///
/// `pixelBuffer` is IOSurface-backed, Metal-compatible, `kCVPixelFormatType_32BGRA`.
// @unchecked: a CVPixelBuffer is never written after the decoder publishes it,
// so sharing it read-only across actors is safe.
public struct VideoFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    /// Presentation time in stream time (first frame of the stream = 0).
    public let presentationTime: CMTime
    /// Time until the next frame; `.invalid` for the last frame.
    public let duration: CMTime

    public init(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, duration: CMTime) {
        self.pixelBuffer = pixelBuffer; self.presentationTime = presentationTime; self.duration = duration
    }
}

/// Float32, non-interleaved PCM layout.
public struct PCMFormat: Sendable, Equatable {
    /// Samples per second.
    public var sampleRate: Double
    public var channels: Int
    public init(sampleRate: Double, channels: Int) { self.sampleRate = sampleRate; self.channels = channels }
}

/// Decoded audio, one `[Float]` per channel, all `frameCount` long.
public struct PCMBuffer: Sendable {
    public var format: PCMFormat
    /// Stream time of the first sample.
    public var startTime: CMTime
    public var frameCount: Int
    public var channels: [[Float]]
    public init(format: PCMFormat, startTime: CMTime, frameCount: Int, channels: [[Float]]) {
        self.format = format; self.startTime = startTime; self.frameCount = frameCount; self.channels = channels
    }
}

/// Key for one frame lookup: file, stream and stream time.
public struct FrameRequest: Hashable, Sendable {
    public var url: URL
    /// Stream index (`trackNumber`).
    public var stream: Int
    /// Stream time.
    public var time: CMTime

    public init(url: URL, stream: Int, time: CMTime) { self.url = url; self.stream = stream; self.time = time }

    public static func == (a: FrameRequest, b: FrameRequest) -> Bool {
        a.url == b.url && a.stream == b.stream && a.time == b.time
    }
    public func hash(into h: inout Hasher) {
        h.combine(url); h.combine(stream)
        // Hash on the exact time in seconds so equal CMTimes with different timescales collide.
        h.combine(time.isNumeric ? time.seconds : -1)
    }
}

public enum MediaError: Error, Sendable, Equatable {
    case fileNotFound(URL)
    case unsupported(String)
    case noSuchStream(Int)
    case decodeFailed(String)
    case notImplemented
}

/// An open media file. Implementations are thread-safe (actors or locked classes).
public protocol MediaSource: AnyObject, Sendable {
    var info: MediaInfo { get }

    /// The frame on screen at stream time `time`: the last frame whose PTS ≤ `time`.
    /// Variable-frame-rate streams hold the previous frame. `time` is clamped to the
    /// stream. Exact: never returns a neighbouring frame.
    func frame(stream: Int, at time: CMTime) async throws -> VideoFrame

    /// PCM for `range` (stream time), resampled to `format`. Silence-padded past the ends.
    func audio(stream: Int, range: CMTimeRange, format: PCMFormat) async throws -> PCMBuffer

    /// Downscaled frame whose longer side is at most `maxPixelSize` px.
    func thumbnail(stream: Int, at time: CMTime, maxPixelSize: Int) async throws -> CGImage
}

/// Opens and caches media sources and decoded frames. One per document.
public actor MediaPool {
    public let cacheLimitBytes: Int

    private var sources: [URL: Task<any MediaSource, Error>] = [:]
    private var cache: FrameCache
    private var prefetchTasks: [UUID: Task<Void, Never>] = [:]

    /// `cacheLimitBytes`: budget for the decoded-frame cache (LRU).
    public init(cacheLimitBytes: Int = 512 << 20) {
        self.cacheLimitBytes = cacheLimitBytes
        self.cache = FrameCache(limitBytes: cacheLimitBytes)
    }

    /// Reads stream metadata without decoding frames.
    public func probe(_ url: URL) async throws -> MediaInfo {
        if let t = sources[url], let s = try? await t.value { return s.info }
        return try await Task.detached(priority: .userInitiated) { try Prober.probe(url) }.value
    }

    /// Opens (or returns the already open) source for `url`.
    public func source(for url: URL) async throws -> any MediaSource {
        if let t = sources[url] { return try await t.value }
        let t = Task.detached(priority: .userInitiated) { () throws -> any MediaSource in
            try openSource(try Prober.probe(url))
        }
        sources[url] = t
        do {
            return try await t.value
        } catch {
            if sources[url] == t { sources[url] = nil } // allow a retry (e.g. media relinked)
            throw error
        }
    }

    /// Cached frame lookup; decodes on a miss.
    public func frame(_ request: FrameRequest) async throws -> VideoFrame {
        let t = request.time.isNumeric ? max(0, request.time.seconds) : (request.time == .positiveInfinity ? .infinity : 0)
        if let f = cache.lookup(url: request.url, stream: request.stream, seconds: t) { return f }
        let src = try await source(for: request.url)
        let f = try await src.frame(stream: request.stream, at: request.time)
        cache.insert(url: request.url, stream: request.stream, frame: f)
        return f
    }

    /// Starts decoding `requests` ahead of need (playback pre-roll). Returns immediately.
    ///
    /// Requests for the same stream are decoded in the given order (so sequential pre-roll
    /// never makes the decoder seek backwards); different streams decode in parallel.
    public func prefetch(_ requests: [FrameRequest]) {
        var groups: [String: [FrameRequest]] = [:]
        var order: [String] = []
        for r in requests {
            let k = "\(r.stream)|\(r.url.absoluteString)"
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(r)
        }
        for k in order {
            guard let group = groups[k] else { continue }
            let id = UUID()
            prefetchTasks[id] = Task { [weak self] in
                for r in group {
                    if Task.isCancelled { break }
                    _ = try? await self?.frame(r)
                }
                await self?.prefetchFinished(id)
            }
        }
    }

    private func prefetchFinished(_ id: UUID) { prefetchTasks[id] = nil }

    /// Drops all cached frames and closes sources.
    public func purge() {
        for t in prefetchTasks.values { t.cancel() }
        prefetchTasks.removeAll()
        cache.removeAll()
        sources.removeAll()
    }

    /// Bytes currently held by the frame cache.
    var cachedBytes: Int { cache.totalBytes }
    /// Number of cached frames.
    var cachedFrameCount: Int { cache.count }
}
