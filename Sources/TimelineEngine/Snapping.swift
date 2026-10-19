import Foundation
import TSCProjKit

/// What a snap landed on.
public enum SnapKind: Sendable, Equatable, Hashable {
    /// Start edge of the top-level clip with this id.
    case clipStart(Int64)
    /// End edge of the top-level clip with this id.
    case clipEnd(Int64)
    case playhead
    /// A timeline marker (`timeline.parameters.toc`).
    case marker
    /// Tick 0.
    case timelineStart
}

/// A snap target: where to draw the guide line, in ticks.
public struct SnapGuide: Sendable, Equatable, Hashable {
    public let tick: Int64
    public let kind: SnapKind
    public init(tick: Int64, kind: SnapKind) { self.tick = tick; self.kind = kind }
}

/// Result of snapping one position (ticks). `guide` is nil when nothing was
/// within tolerance (the tick is then only frame-snapped).
public struct SnapResult: Sendable, Equatable {
    public let tick: Int64
    public let guide: SnapGuide?
    public init(tick: Int64, guide: SnapGuide?) { self.tick = tick; self.guide = guide }
}

/// Pure snapping helper for timeline gestures. Built once per gesture from
/// the project; the snapshot is a value type and can be used off the main actor.
///
/// Targets: tick 0, the playhead, timeline markers, and the start/end edges
/// of every top-level clip not in `excluding`. The nearest target within
/// `tolerance` ticks wins; on a tie the order is playhead, marker, clip
/// edges, timeline start. Without a target the position snaps to the output
/// frame grid (unless `frameSnap` is false or the project allows sub-frame
/// editing).
public struct Snapping: Sendable {
    /// All targets, sorted by tick.
    public let targets: [SnapGuide]
    private let grid: FrameGrid?

    @MainActor
    public init(project: Project, playhead: Int64? = nil, excluding: Set<Int64> = [], frameSnap: Bool = true) {
        var t: [SnapGuide] = [SnapGuide(tick: 0, kind: .timelineStart)]
        if let playhead { t.append(SnapGuide(tick: playhead, kind: .playhead)) }
        for m in Markers.timeline(project) { t.append(SnapGuide(tick: m.time, kind: .marker)) }
        for track in project.tracks {
            for c in track.clips where !excluding.contains(c.id) {
                t.append(SnapGuide(tick: c.start, kind: .clipStart(c.id)))
                t.append(SnapGuide(tick: c.end, kind: .clipEnd(c.id)))
            }
        }
        targets = t.sorted { ($0.tick, Self.rank($0.kind)) < ($1.tick, Self.rank($1.kind)) }
        grid = frameSnap ? FrameGrid(project) : nil
    }

    private static func rank(_ k: SnapKind) -> Int {
        switch k {
        case .playhead: 0
        case .marker: 1
        case .clipStart, .clipEnd: 2
        case .timelineStart: 3
        }
    }

    /// Nearest target to `tick` within `tolerance`, if any.
    public func nearest(_ tick: Int64, tolerance: Int64) -> SnapGuide? {
        var best: SnapGuide?
        var bestD = Int64.max
        for g in targets {
            let d = (g.tick - tick).magnitude
            guard d <= tolerance.magnitude else { continue }
            if Int64(d) < bestD || (Int64(d) == bestD && Self.rank(g.kind) < Self.rank(best?.kind ?? .timelineStart)) {
                best = g; bestD = Int64(d)
            }
        }
        return best
    }

    /// Snaps one position (playhead drag, trim edge, split point).
    public func snap(_ tick: Int64, tolerance: Int64) -> SnapResult {
        if let g = nearest(tick, tolerance: tolerance) { return SnapResult(tick: g.tick, guide: g) }
        return SnapResult(tick: grid?.nearest(tick) ?? tick, guide: nil)
    }

    /// Snaps a moving clip by whichever of its edges is closer to a target;
    /// returns the snapped **start**.
    public func snap(start: Int64, duration: Int64, tolerance: Int64) -> SnapResult {
        guard let (delta, g) = snap(edges: [start, start + duration], tolerance: tolerance) else {
            return SnapResult(tick: grid?.nearest(start) ?? start, guide: nil)
        }
        return SnapResult(tick: start + delta, guide: g)
    }

    /// Multi-clip drags: the edge closest to any target wins; returns the
    /// shift to apply to every edge and the guide, or nil when none is in range.
    public func snap(edges: [Int64], tolerance: Int64) -> (delta: Int64, guide: SnapGuide)? {
        var best: (delta: Int64, guide: SnapGuide)?
        for e in edges {
            guard let g = nearest(e, tolerance: tolerance) else { continue }
            let d = g.tick - e
            if let b = best {
                let better = d.magnitude < b.delta.magnitude
                    || (d.magnitude == b.delta.magnitude && Self.rank(g.kind) < Self.rank(b.guide.kind))
                if !better { continue }
            }
            best = (d, g)
        }
        return best
    }
}
