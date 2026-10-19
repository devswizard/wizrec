import CoreMedia
import CoreGraphics
import Foundation
import MediaEngine

/// Min/max audio peaks of one stream, `bucketsPerSecond` buckets from stream time 0.
/// Values are sample amplitudes in −1…1 (all channels merged).
public struct TimelineWaveform: Sendable, Equatable {
    public var bucketsPerSecond: Double
    public var minima: [Float]
    public var maxima: [Float]

    public init(bucketsPerSecond: Double, minima: [Float], maxima: [Float]) {
        self.bucketsPerSecond = bucketsPerSecond; self.minima = minima; self.maxima = maxima
    }

    /// Min/max over stream seconds `a..<b` (nil outside the data).
    public func range(from a: Double, to b: Double) -> (min: Float, max: Float)? {
        let n = min(minima.count, maxima.count)
        guard n > 0, bucketsPerSecond > 0 else { return nil }
        let lo = max(0, Int((min(a, b) * bucketsPerSecond).rounded(.down)))
        let hi = min(n - 1, max(lo, Int((max(a, b) * bucketsPerSecond).rounded(.up)) - 1))
        guard lo < n else { return nil }
        var mn: Float = 0, mx: Float = 0
        for i in lo...hi { mn = Swift.min(mn, minima[i]); mx = Swift.max(mx, maxima[i]) }
        return (mn, mx)
    }
}

/// Supplies filmstrip thumbnails and waveforms to the timeline. Injected so the view
/// runs without media in tests. Implementations must be thread-safe.
public protocol TimelineMediaProvider: AnyObject, Sendable {
    /// Frame of `media` at stream seconds `seconds`, longer side ≤ `maxPixelSize` px.
    func thumbnail(_ media: TimelineMediaRef, atSeconds seconds: Double, maxPixelSize: Int) async -> CGImage?
    /// Peaks of the whole stream.
    func waveform(_ media: TimelineMediaRef) async -> TimelineWaveform?
}

/// `TimelineMediaProvider` backed by MediaEngine: filmstrip frames from
/// `MediaPool.thumbnail(url:stream:at:maxPixelSize:accuracy:)` (its own decoders, so playback
/// lanes never move; nearest keyframe) and waveforms from `MediaPool.peaks` (decoded once,
/// cached in memory and on disk). The playback pool can be shared.
public final class MediaPoolTimelineProvider: TimelineMediaProvider {
    public let pool: MediaPool
    /// Waveform resolution requested from `MediaPool.peaks`, buckets per second.
    public let bucketsPerSecond: Double
    private let resolve: @Sendable (TimelineMediaRef) -> URL?

    /// `resolve` maps a source to its file (the app knows the bundle location).
    public init(pool: MediaPool, bucketsPerSecond: Double = 400,
                resolve: @escaping @Sendable (TimelineMediaRef) -> URL?) {
        self.pool = pool; self.bucketsPerSecond = bucketsPerSecond; self.resolve = resolve
    }

    /// Resolves `src` like `ProjectBundle.resolve`: absolute paths and `file:` URLs as is,
    /// anything else relative to `bundleDirectory`.
    public convenience init(pool: MediaPool, bundleDirectory: URL) {
        self.init(pool: pool) { ref in
            if ref.src.hasPrefix("/") { return URL(fileURLWithPath: ref.src) }
            if let u = URL(string: ref.src), u.scheme == "file" { return u }
            return bundleDirectory.appendingPathComponent(ref.src).standardizedFileURL
        }
    }

    public func thumbnail(_ media: TimelineMediaRef, atSeconds seconds: Double, maxPixelSize: Int) async -> CGImage? {
        guard let url = resolve(media) else { return nil }
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        return try? await pool.thumbnail(url: url, stream: media.stream, at: t, maxPixelSize: maxPixelSize,
                                         accuracy: .nearestKeyframe).image
    }

    public func waveform(_ media: TimelineMediaRef) async -> TimelineWaveform? {
        guard let url = resolve(media),
              let p = try? await pool.peaks(url: url, stream: media.stream, bucketsPerSecond: bucketsPerSecond)
        else { return nil }
        return TimelineWaveform(bucketsPerSecond: p.bucketsPerSecond, minima: p.min, maxima: p.max)
    }
}

/// Main-actor cache in front of a `TimelineMediaProvider`: deduplicates requests, runs at
/// most `maxConcurrent` at once, newest first (what is on screen now), and calls
/// `onUpdate` when something arrives.
@MainActor
final class MediaArtCache {
    struct ThumbKey: Hashable { var media: TimelineMediaRef; var millis: Int64; var size: Int }

    var provider: (any TimelineMediaProvider)? {
        didSet { if provider !== oldValue { reset() } }
    }
    var onUpdate: (() -> Void)?
    let maxConcurrent = 4
    let maxThumbnails = 800

    private var thumbs: [ThumbKey: CGImage] = [:]
    private var thumbOrder: [ThumbKey] = []
    private var waves: [TimelineMediaRef: TimelineWaveform] = [:]
    private var missingWaves: Set<TimelineMediaRef> = []
    private var pending: [ThumbKey] = []
    private var inFlight: Set<ThumbKey> = []
    private var wavesInFlight: Set<TimelineMediaRef> = []
    private var generation = 0

    func reset() {
        generation += 1
        thumbs = [:]; thumbOrder = []; waves = [:]; missingWaves = []; pending = []; inFlight = []; wavesInFlight = []
    }

    /// Cached thumbnail, or nil after queueing a request.
    func thumbnail(_ media: TimelineMediaRef, seconds: Double, size: Int) -> CGImage? {
        let key = ThumbKey(media: media, millis: Int64((seconds * 1000).rounded()), size: size)
        if let img = thumbs[key] { return img }
        guard provider != nil, !inFlight.contains(key) else { return nil }
        if let i = pending.firstIndex(of: key) { pending.remove(at: i) }
        pending.append(key)
        if pending.count > 256 { pending.removeFirst(pending.count - 256) }
        pump()
        return nil
    }

    /// Cached waveform, or nil after queueing a request.
    func waveform(_ media: TimelineMediaRef) -> TimelineWaveform? {
        if let w = waves[media] { return w }
        guard let provider, !wavesInFlight.contains(media), !missingWaves.contains(media) else { return nil }
        wavesInFlight.insert(media)
        let gen = generation
        Task { [weak self] in
            let w = await provider.waveform(media)
            guard let self, self.generation == gen else { return }
            self.wavesInFlight.remove(media)
            if let w { self.waves[media] = w } else { self.missingWaves.insert(media) }
            self.onUpdate?()
        }
        return nil
    }

    /// Any thumbnail of `media` already loaded (to size empty tiles while loading).
    func anyThumbnail(of media: TimelineMediaRef) -> CGImage? {
        thumbOrder.last { $0.media == media }.flatMap { thumbs[$0] }
    }

    private func pump() {
        guard let provider else { return }
        while inFlight.count < maxConcurrent, let key = pending.popLast() {
            inFlight.insert(key)
            let gen = generation
            Task { [weak self] in
                let img = await provider.thumbnail(key.media, atSeconds: Double(key.millis) / 1000, maxPixelSize: key.size)
                guard let self, self.generation == gen else { return }
                self.inFlight.remove(key)
                if let img { self.store(img, for: key) }
                self.pump()
                self.onUpdate?()
            }
        }
    }

    private func store(_ img: CGImage, for key: ThumbKey) {
        thumbs[key] = img
        thumbOrder.append(key)
        if thumbOrder.count > maxThumbnails {
            let drop = thumbOrder.count - maxThumbnails
            for k in thumbOrder.prefix(drop) { thumbs[k] = nil }
            thumbOrder.removeFirst(drop)
        }
    }

    var isIdle: Bool { pending.isEmpty && inFlight.isEmpty && wavesInFlight.isEmpty }
}
