// MediaPool M2 API: waveform peaks, filmstrip thumbnails, the "nearest decoded frame"
// policy and decode-rate measurement.

import CoreGraphics
import CoreMedia
import Foundation

/// How `MediaPool.frame(_:policy:)` trades accuracy for latency.
public enum FramePolicy: Sendable, Equatable {
    /// The exact frame (last PTS ≤ time). May wait for decode. Same as `frame(_:)`.
    case exact
    /// The exact frame when it is cached. Otherwise, **while a decode of the same stream is in
    /// flight** (decode cannot keep up), the newest already-decoded frame of that stream with
    /// PTS ≤ time and `time − PTS ≤ maxLag` (stream time), returned at once; a background
    /// decode then moves toward `time` (forward only, newest request wins, never behind a
    /// later request already in flight). When the decoder is idle or nothing qualifies (after a
    /// seek, lag > `maxLag`), it waits for the exact frame.
    ///
    /// The result is exact iff `pts ≤ time` and (`duration` is invalid or `time < pts + duration`).
    case nearestDecoded(maxLag: CMTime)
}

extension MediaPool {
    // MARK: - Nearest decoded frame

    /// Frame lookup under `policy` (see `FramePolicy`).
    public func frame(_ request: FrameRequest, policy: FramePolicy) async throws -> VideoFrame {
        guard case .nearestDecoded(let maxLag) = policy else { return try await frame(request) }
        let t = Self.lookupTime(request.time)
        if let f = cache.lookup(url: request.url, stream: request.stream, time: t) {
            cacheHits += 1
            return f
        }
        let key = LaneKey(url: request.url, stream: request.stream)
        if inFlight[key] != nil || catchUpTasks[key] != nil,
           let stale = cache.latest(url: request.url, stream: request.stream, atOrBefore: t),
           stale.presentationTime.isNumeric, t.isNumeric, t - stale.presentationTime <= maxLag {
            cacheHits += 1
            scheduleCatchUp(request)
            return stale
        }
        cacheMisses += 1
        return try await decode(request)
    }

    private func scheduleCatchUp(_ r: FrameRequest) {
        let key = LaneKey(url: r.url, stream: r.stream)
        if catchUpTasks[key] != nil {
            if r.time > (catchUpWanted[key]?.time ?? catchUpLast[key] ?? .negativeInfinity) { catchUpWanted[key] = r }
            return
        }
        // A later request is already decoding: it gets there first; never pull the decoder back.
        if let times = inFlight[key], times.contains(where: { $0 >= r.time }) { return }
        startCatchUp(r, key)
    }

    private func startCatchUp(_ r: FrameRequest, _ key: LaneKey) {
        catchUpLast[key] = r.time
        catchUpTasks[key] = Task { [weak self] in
            _ = try? await self?.decode(r)
            await self?.catchUpDone(key)
        }
    }

    private func catchUpDone(_ key: LaneKey) {
        catchUpTasks[key] = nil
        let last = catchUpLast.removeValue(forKey: key)
        if let w = catchUpWanted.removeValue(forKey: key), w.time > (last ?? .negativeInfinity),
           cache.lookup(url: w.url, stream: w.stream, time: Self.lookupTime(w.time)) == nil {
            startCatchUp(w, key)
        }
    }

    /// Measured decode throughput of `stream`: decoded pictures per second of decoder busy time
    /// (smoothed over recent `frame` calls of every caller, both lanes); nil until measured or
    /// for streams that are not decoded (images, audio).
    public func decodeRate(url: URL, stream: Int) async -> Double? {
        guard let t = sources[url], let src = try? await t.value as? FFMediaSource else { return nil }
        return await src.decodeRate(stream: stream)
    }

    // MARK: - Waveform peaks

    /// Min/max envelope of audio `stream` at `bucketsPerSecond` (clamped to the ~1000/s base
    /// resolution; the result states the rate used). The stream is decoded once, then served
    /// from memory and from `diskCacheDirectory`.
    public func peaks(url: URL, stream: Int, bucketsPerSecond: Double) async throws -> WaveformPeaks {
        let base = try await basePeaks(url: url, stream: stream)
        let bps = min(max(bucketsPerSecond, 1e-3), base.bucketsPerSecond)
        return await Task.detached(priority: .userInitiated) { base.resampled(bucketsPerSecond: bps) }.value
    }

    func basePeaks(url: URL, stream: Int) async throws -> BasePeaks {
        let key = PeakKey(url: url, stream: stream)
        peakClock &+= 1
        if let m = peakMemory[key] {
            peakMemory[key] = (m.peaks, peakClock)
            return m.peaks
        }
        if let t = peakTasks[key] { return try await t.value }
        let src = try await source(for: url)
        guard let ff = src as? FFMediaSource, stream >= 0, stream < ff.map.containerIndex.count,
              let info = ff.info.streams.first(where: { $0.index == stream })
        else { throw MediaError.noSuchStream(stream) }
        guard info.kind == .audio else { throw MediaError.unsupported("stream \(stream) is \(info.kind.rawValue), not audio") }
        let ci = ff.map.containerIndex[stream], trim = ff.map.audioTrim[stream] ?? 0, length = ff.map.audioLength[stream]
        let disk = diskCacheDirectory.flatMap(PeakDiskCache.init(directory:))
        let task = Task<BasePeaks, Error> {
            try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .utility).async {
                    let file = disk?.fileURL(for: url, stream: stream)
                    if let disk, let file, let p = disk.load(file) { cont.resume(returning: p); return }
                    do {
                        let p = try PeakScanner.scan(url: url, streamIndex: ci, trim: trim, length: length)
                        if let disk, let file { disk.store(p, to: file) }
                        cont.resume(returning: p)
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        peakTasks[key] = task
        defer { peakTasks[key] = nil }
        let p = try await task.value
        peakMemory[key] = (p, peakClock)
        var total = peakMemory.values.reduce(0) { $0 + $1.peaks.bytes }
        while total > peakLimitBytes, peakMemory.count > 1,
              let victim = peakMemory.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            total -= victim.value.peaks.bytes
            peakMemory[victim.key] = nil
        }
        return p
    }

    // MARK: - Filmstrip thumbnails

    /// Thumbnails of video `stream` at `times` (stream time), longer side ≤ `maxPixelSize` px,
    /// yielded in ascending time order as they decode. Uses its own decoders, so playback lanes
    /// never move. Cached (LRU, 64 MB). Cancelling the iteration stops decoding.
    public nonisolated func thumbnails(url: URL, stream: Int, times: [CMTime], maxPixelSize: Int,
                                       accuracy: ThumbnailAccuracy = .nearestKeyframe) -> AsyncThrowingStream<Thumbnail, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    for t in times.sorted() {
                        try Task.checkCancellation()
                        cont.yield(try await self.thumbnail(url: url, stream: stream, at: t, maxPixelSize: maxPixelSize,
                                                            accuracy: accuracy))
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// One thumbnail (see `thumbnails(url:stream:times:maxPixelSize:accuracy:)`).
    public func thumbnail(url: URL, stream: Int, at time: CMTime, maxPixelSize: Int,
                          accuracy: ThumbnailAccuracy = .nearestKeyframe) async throws -> Thumbnail {
        let src = try await source(for: url)
        guard let ff = src as? FFMediaSource else {
            let img = try await src.thumbnail(stream: stream, at: time, maxPixelSize: maxPixelSize)
            return Thumbnail(requestedTime: time, presentationTime: .zero, image: img)
        }
        guard stream >= 0, stream < ff.map.containerIndex.count,
              let info = ff.info.streams.first(where: { $0.index == stream })
        else { throw MediaError.noSuchStream(stream) }
        guard info.kind == .video else { throw MediaError.unsupported("stream \(stream) is \(info.kind.rawValue), not video") }
        return try await thumbnails.thumbnail(url: url, stream: stream, containerIndex: ff.map.containerIndex[stream],
                                              time: time, maxPixelSize: maxPixelSize, accuracy: accuracy)
    }
}
