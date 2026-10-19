// LRU cache of decoded frames, keyed by the interval each frame is on screen,
// so every request inside [pts, pts + duration) hits the same entry.
// Intervals are exact CMTime rationals: float seconds would let neighbouring
// frames overlap by rounding error.

import CoreMedia
import CoreVideo
import Foundation

struct FrameCache {
    private struct StreamKey: Hashable {
        let url: URL
        let stream: Int
    }

    private struct Entry {
        let frame: VideoFrame
        /// On-screen interval in stream time: [start, end). `end` is +∞ for a stream's last frame.
        let start: CMTime
        var end: CMTime
        let bytes: Int
        var lastUse: UInt64
    }

    let limitBytes: Int
    private(set) var totalBytes = 0
    private var clock: UInt64 = 0
    /// Per stream: entries sorted by `start`, non-overlapping.
    private var streams: [StreamKey: [Entry]] = [:]

    init(limitBytes: Int) { self.limitBytes = max(0, limitBytes) }

    var count: Int { streams.values.reduce(0) { $0 + $1.count } }

    /// Index of the entry whose interval contains `t`, and the insertion point for `t`.
    private static func search(_ entries: [Entry], _ t: CMTime) -> (found: Int?, insert: Int) {
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if entries[mid].start <= t { lo = mid + 1 } else { hi = mid }
        }
        // lo = first entry with start > t
        if lo > 0, t < entries[lo - 1].end { return (lo - 1, lo) }
        return (nil, lo)
    }

    /// Cached frame on screen at stream time `t` (already clamped ≥ 0; may be +∞).
    mutating func lookup(url: URL, stream: Int, time t: CMTime) -> VideoFrame? {
        let key = StreamKey(url: url, stream: stream)
        guard var entries = streams[key], let i = Self.search(entries, t).found else { return nil }
        clock &+= 1
        entries[i].lastUse = clock
        streams[key] = entries
        return entries[i].frame
    }

    mutating func insert(url: URL, stream: Int, frame: VideoFrame) {
        let start = frame.presentationTime.isNumeric ? frame.presentationTime : .zero
        var end = CMTime.positiveInfinity
        if frame.duration.isNumeric, frame.duration > .zero { end = start + frame.duration }
        let bytes = CVPixelBufferGetDataSize(frame.pixelBuffer)
        guard bytes <= limitBytes else { return }
        let key = StreamKey(url: url, stream: stream)
        var entries = streams[key] ?? []
        let s = Self.search(entries, start)
        if s.found != nil { return } // already cached
        // Never overlap the next cached frame (defensive; durations come from real PTS gaps).
        if s.insert < entries.count, end > entries[s.insert].start { end = entries[s.insert].start }
        clock &+= 1
        entries.insert(Entry(frame: frame, start: start, end: end, bytes: bytes, lastUse: clock), at: s.insert)
        streams[key] = entries
        totalBytes += bytes
        evict()
    }

    private mutating func evict() {
        while totalBytes > limitBytes {
            var victim: (StreamKey, Int, UInt64)?
            for (k, entries) in streams {
                for (i, e) in entries.enumerated() {
                    if let v = victim, e.lastUse >= v.2 { continue }
                    victim = (k, i, e.lastUse)
                }
            }
            guard let (k, i, _) = victim, var entries = streams[k] else { return }
            totalBytes -= entries[i].bytes
            entries.remove(at: i)
            streams[k] = entries.isEmpty ? nil : entries
        }
    }

    /// Cached on-screen intervals of one stream, ascending (tests/diagnostics).
    func intervals(url: URL, stream: Int) -> [(start: CMTime, end: CMTime)] {
        (streams[StreamKey(url: url, stream: stream)] ?? []).map { ($0.start, $0.end) }
    }

    mutating func removeAll() {
        streams.removeAll()
        totalBytes = 0
    }
}
