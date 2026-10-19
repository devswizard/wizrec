// Public interface of MediaEngine, frozen by coordination/CONTRACTS.md.
// Changing anything here needs an API_CHANGE message and the lead's approval.

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import TSCProjKit

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

    // MARK: sourceTracks metadata (M2, docs/specs/media-streams.md §3)

    /// Units per second of `length`: the value a project writes as `sourceTracks[i].editRate`
    /// (e.g. 44100 for a `.trec`, 60000 / 240000 for camera mp4 video / audio, 600 for images).
    /// Not a frame rate.
    public var timescale: Int32
    /// Presentation length in `timescale` units (edit lists applied, AAC priming removed):
    /// `sourceTracks[i].range = [0, length]`. 1 for images, `Int64.max` for shaders.
    public var length: Int64
    /// Exact frame rate (frames per second) as stored in the container, e.g. 60000/1001;
    /// the average for VFR streams. Nil for audio, images and when unknown.
    public var frameRate: Rational?
    /// `sourceTracks[i].bitDepth` as Camtasia writes it [obs]: 0 for imported files and images,
    /// 24 (video) / 16 (audio) for `.trec` recordings, 32 for shaders.
    public var bitDepth: Int
    /// Decoded sample precision in bits: 8/10/12 per video component, 16/24/32 per PCM audio
    /// sample; 0 when the codec does not define it (e.g. AAC).
    public var bitsPerComponent: Int
    /// `sourceTracks[i].type`: 0 = video, 1 = still image, 2 = audio.
    public var trackType: Int

    public init(index: Int, kind: StreamKind, codec: String, pixelSize: CGSize = .zero,
                nominalFrameRate: Double = 0, sampleRate: Double = 0, channelCount: Int = 0,
                duration: CMTime, timescale: Int32 = 0, length: Int64 = 0, frameRate: Rational? = nil,
                bitDepth: Int = 0, bitsPerComponent: Int = 0, trackType: Int? = nil) {
        self.index = index; self.kind = kind; self.codec = codec; self.pixelSize = pixelSize
        self.nominalFrameRate = nominalFrameRate; self.sampleRate = sampleRate
        self.channelCount = channelCount; self.duration = duration
        self.timescale = timescale; self.length = length; self.frameRate = frameRate
        self.bitDepth = bitDepth; self.bitsPerComponent = bitsPerComponent
        self.trackType = trackType ?? (kind == .audio ? 2 : 0)
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

/// Frame-cache counters of a `MediaPool`.
public struct CacheStats: Sendable, Equatable {
    /// `frame(_:)` calls answered from the cache.
    public var hits: Int
    /// `frame(_:)` calls that had to decode (pre-roll decodes are not counted).
    public var misses: Int
    /// Frames currently cached.
    public var frames: Int
    /// Bytes currently held by cached frames.
    public var bytes: Int

    public init(hits: Int, misses: Int, frames: Int, bytes: Int) {
        self.hits = hits; self.misses = misses; self.frames = frames; self.bytes = bytes
    }
}

/// Opens and caches media sources and decoded frames. One per document.
public actor MediaPool {
    public let cacheLimitBytes: Int

    var sources: [URL: Task<any MediaSource, Error>] = [:]
    var cache: FrameCache

    /// One pre-roll lane per stream: pending requests (in order) and the task draining them.
    struct LaneKey: Hashable { let url: URL; let stream: Int }
    private var prefetchQueue: [LaneKey: [FrameRequest]] = [:]
    private var prefetchWorkers: [LaneKey: Task<Void, Never>] = [:]

    var cacheHits = 0
    var cacheMisses = 0

    // M2 state (Pool+M2.swift).
    /// Directory of the on-disk waveform-peak cache; nil = memory only. Created on first write.
    public nonisolated let diskCacheDirectory: URL?
    struct PeakKey: Hashable { let url: URL; let stream: Int }
    var peakMemory: [PeakKey: (peaks: BasePeaks, lastUse: UInt64)] = [:]
    var peakTasks: [PeakKey: Task<BasePeaks, Error>] = [:]
    var peakClock: UInt64 = 0
    /// Memory budget for cached waveform envelopes (base resolution).
    let peakLimitBytes = 64 << 20
    /// Filmstrip decoders + cache, separate from playback decoders.
    let thumbnails = ThumbnailService(limitBytes: 64 << 20)
    /// `.nearestDecoded` catch-up decode per stream: the running task, the newest target asked
    /// for while it runs, and the last target started (targets only move forward).
    var catchUpTasks: [LaneKey: Task<Void, Never>] = [:]
    var catchUpWanted: [LaneKey: FrameRequest] = [:]
    var catchUpLast: [LaneKey: CMTime] = [:]
    /// Stream times of decodes in flight per stream (any caller), for `.nearestDecoded`.
    var inFlight: [LaneKey: [CMTime]] = [:]

    /// `~/Library/Caches/WizRec/peaks`, the default `diskCacheDirectory`.
    public static let defaultDiskCacheDirectory: URL? = PeakDiskCache.defaultDirectory

    /// `cacheLimitBytes`: budget for the decoded-frame cache (LRU). `diskCacheDirectory`: where
    /// waveform peaks persist between launches (nil = memory only; never inside a project bundle).
    public init(cacheLimitBytes: Int = 512 << 20, diskCacheDirectory: URL? = MediaPool.defaultDiskCacheDirectory) {
        self.cacheLimitBytes = cacheLimitBytes
        self.cache = FrameCache(limitBytes: cacheLimitBytes)
        self.diskCacheDirectory = diskCacheDirectory
    }

    /// Reads stream metadata without decoding frames.
    public func probe(_ url: URL) async throws -> MediaInfo {
        if let t = sources[url], let s = try? await t.value { return s.info }
        return try await Task.detached(priority: .userInitiated) { try await Prober.probe(url) }.value
    }

    /// Opens (or returns the already open) source for `url`.
    public func source(for url: URL) async throws -> any MediaSource {
        if let t = sources[url] { return try await t.value }
        let t = Task.detached(priority: .userInitiated) { () throws -> any MediaSource in
            try openSource(try await Prober.probeDetailed(url))
        }
        sources[url] = t
        do {
            return try await t.value
        } catch {
            if sources[url] == t { sources[url] = nil } // allow a retry (e.g. media relinked)
            throw error
        }
    }

    /// Stream time used for cache lookups: clamped to ≥ 0.
    static func lookupTime(_ t: CMTime) -> CMTime {
        t.isNumeric ? max(.zero, t) : (t == .positiveInfinity ? .positiveInfinity : .zero)
    }

    /// Cached frame lookup; decodes on a miss.
    public func frame(_ request: FrameRequest) async throws -> VideoFrame {
        if let f = cache.lookup(url: request.url, stream: request.stream, time: Self.lookupTime(request.time)) {
            cacheHits += 1
            return f
        }
        cacheMisses += 1
        return try await decode(request)
    }

    func decode(_ request: FrameRequest) async throws -> VideoFrame {
        let key = LaneKey(url: request.url, stream: request.stream)
        inFlight[key, default: []].append(request.time)
        defer {
            if var a = inFlight[key], let i = a.firstIndex(of: request.time) {
                a.remove(at: i)
                inFlight[key] = a.isEmpty ? nil : a
            }
        }
        let src = try await source(for: request.url)
        let f = try await src.frame(stream: request.stream, at: request.time)
        cache.insert(url: request.url, stream: request.stream, frame: f)
        return f
    }

    /// Starts decoding `requests` ahead of need (playback pre-roll). Returns immediately.
    ///
    /// Each stream has one pre-roll lane that decodes its requests in the given order, one at
    /// a time, so the decoder only moves forward. A new call *replaces* the stream's requests
    /// that have not started yet (the latest call describes what playback needs next), so
    /// successive batches never interleave and a seek drops stale pre-roll. Different streams
    /// decode in parallel.
    public func prefetch(_ requests: [FrameRequest]) {
        var groups: [LaneKey: [FrameRequest]] = [:]
        for r in requests { groups[LaneKey(url: r.url, stream: r.stream), default: []].append(r) }
        for (key, group) in groups {
            prefetchQueue[key] = group
            if prefetchWorkers[key] == nil {
                prefetchWorkers[key] = Task { [weak self] in await self?.drainPrefetch(key) }
            }
        }
    }

    private func drainPrefetch(_ key: LaneKey) async {
        while !Task.isCancelled, var queue = prefetchQueue[key], !queue.isEmpty {
            let r = queue.removeFirst()
            prefetchQueue[key] = queue
            if cache.lookup(url: r.url, stream: r.stream, time: Self.lookupTime(r.time)) != nil { continue }
            _ = try? await decode(r)
        }
        prefetchQueue[key] = nil
        prefetchWorkers[key] = nil
    }

    /// Drops all cached frames and closes sources.
    public func purge() {
        for t in prefetchWorkers.values { t.cancel() }
        prefetchWorkers.removeAll()
        prefetchQueue.removeAll()
        cache.removeAll()
        sources.removeAll()
        cacheHits = 0
        cacheMisses = 0
        for t in catchUpTasks.values { t.cancel() }
        catchUpTasks.removeAll(); catchUpWanted.removeAll(); catchUpLast.removeAll()
        for t in peakTasks.values { t.cancel() }
        peakTasks.removeAll(); peakMemory.removeAll()
        let thumbs = thumbnails
        Task { await thumbs.purge() }
    }

    /// Frame-cache counters since creation or the last `purge()`.
    public var cacheStats: CacheStats {
        CacheStats(hits: cacheHits, misses: cacheMisses, frames: cache.count, bytes: cache.totalBytes)
    }

    /// Bytes currently held by the frame cache.
    var cachedBytes: Int { cache.totalBytes }
    /// Number of cached frames.
    var cachedFrameCount: Int { cache.count }
    /// Cached on-screen intervals of one stream.
    func cachedIntervals(url: URL, stream: Int) -> [(start: CMTime, end: CMTime)] { cache.intervals(url: url, stream: stream) }
    /// True while a pre-roll lane is working.
    var isPrefetching: Bool { !prefetchWorkers.isEmpty }
}
