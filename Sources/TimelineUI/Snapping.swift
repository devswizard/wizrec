import Foundation

/// Result of snapping: add `delta` ticks to the dragged edges; draw a guide at `guide` (ticks).
public struct TimelineSnap: Sendable, Equatable {
    public var delta: Int64
    public var guide: Int64
    public init(delta: Int64, guide: Int64) { self.delta = delta; self.guide = guide }
}

/// Custom snap rule for the timeline view. Times in ticks. Optional: by default the view
/// uses TimelineEngine's `Snapping` (clip edges, playhead, markers, tick 0).
public protocol TimelineSnapping: Sendable {
    /// The snap that moves one of `edges` onto the closest target within `tolerance`
    /// ticks, or nil. Clips in `excluding` (the ones being dragged) are not targets.
    func snap(edges: [Int64], tolerance: Int64, snapshot: TimelineSnapshot, playhead: Int64,
              excluding: Set<Int64>) -> TimelineSnap?
}

/// Simple rule on a snapshot: top-level clip starts and ends, the playhead and tick 0 (no markers).
public struct EdgeSnapper: TimelineSnapping {
    public init() {}

    public func targets(snapshot: TimelineSnapshot, playhead: Int64, excluding: Set<Int64>) -> [Int64] {
        var out: [Int64] = [0, playhead]
        for t in snapshot.tracks {
            for c in t.clips where !excluding.contains(c.id) { out.append(c.start); out.append(c.end) }
        }
        return out
    }

    public func snap(edges: [Int64], tolerance: Int64, snapshot: TimelineSnapshot, playhead: Int64,
                     excluding: Set<Int64>) -> TimelineSnap? {
        guard tolerance > 0, !edges.isEmpty else { return nil }
        var best: TimelineSnap?
        var bestDistance = tolerance + 1
        for target in targets(snapshot: snapshot, playhead: playhead, excluding: excluding) {
            for e in edges {
                let d = target - e
                if abs(d) < bestDistance { bestDistance = abs(d); best = TimelineSnap(delta: d, guide: target) }
            }
        }
        return best
    }
}

extension TimelineSnapshot {
    /// `t` rounded to the nearest output frame.
    public func quantize(_ t: Int64) -> Int64 {
        let f = frameTicks
        guard f > 1 else { return t }
        let q = (Double(t) / Double(f)).rounded()
        return Int64(q) * f
    }
}
