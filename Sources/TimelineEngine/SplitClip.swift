import Foundation
import TSCProjKit

/// Splits a clip in two at a tick strictly inside it.
///
/// The left half keeps the clip's id and object position; the right half is
/// a deep copy inserted right after it, with every nested `id` renumbered
/// above `Project.maxID` (and transitions inside a copied group relinked).
///
/// The split point is snapped to the nearest output frame unless the project
/// allows sub-frame editing (`FrameGrid`). Timing, with `d = at − start` and
/// `mediaDuration × scalar = duration`:
/// - left: `duration = d`, `mediaDuration = d / scalar`;
/// - right: `start = at`, `duration −= d`, `mediaStart += d / scalar`,
///   `mediaDuration −= d / scalar`.
///
/// Maths is exact (`Rational`); each key keeps its number style (see
/// `TimeWriter`). Per kind:
/// - `UnifiedMedia`: `video` and `audio` are split at the same track time,
///   each with its own fields (time-mapping.md §4).
/// - `Group`: the inner timeline is copied unchanged; only `mediaStart` moves.
/// - `StitchedMedia`: segments are partitioned. The left half drops segments
///   that start at or after its media end; the right half drops segments that
///   end at or before its media start, and the remaining segments are rebased
///   so the first starts at 0 (`mediaStart` reduced to match). Segment
///   durations are not trimmed, matching how Camtasia stores trimmed stitched
///   clips [obs]. Partitioning itself is an assumption.
/// - `IMFile`: `mediaStart`/`mediaDuration` stay (images have no media
///   time); the right half's `trimStartSum` grows by `d` (`Retime`).
///
/// Keyframes, effect windows and `animationTracks` are on the media time axis
/// (time-mapping.md §6–7), so both halves keep them unchanged.
///
/// Transitions on the clip's track: one whose `leftMedia` is the clip (at its
/// end) now points at the right half; `rightMedia` (at its start) stays on
/// the left half.
@MainActor
public final class SplitClip: EditCommand {
    public let clipID: Int64
    /// Requested split point in the clip's track coordinates (project ticks
    /// for top-level tracks, the group's inner timeline inside a group).
    public let time: Int64
    public var name: String { "Split" }

    /// Id given to the right half by the last successful `apply`.
    public private(set) var rightID: Int64?
    /// Split point actually used by the last `apply` (after frame snapping).
    public private(set) var appliedTime: Int64?

    private var swap = TrackSwap()

    public init(clipID: Int64, at time: Int64) {
        self.clipID = clipID
        self.time = time
    }

    public func apply(to project: Project) throws {
        let loc = try Locator.locate(clipID, in: project)
        let timing = try Timing(loc.clip)
        let at = FrameGrid(project).nearest(time)
        guard timing.start < at, at < timing.end else {
            throw EditError.invalid("split point \(at) is not inside clip \(clipID)")
        }

        let track = loc.track.copy()
        guard let medias = track["medias"]?.array, let left = medias[loc.index].object else {
            throw EditError.clipNotFound(clipID)
        }
        let right = left.copy()
        try Self.split(left: left, right: right, at: at)

        var next = project.maxID
        IDs.remap(.object(right), next: &next)
        guard let newID = right.clipID else { throw EditError.invalid("clip has no id") }
        medias.items.insert(.object(right), at: loc.index + 1)

        for t in track["transitions"]?.array?.items ?? [] {
            if let o = t.object, o["leftMedia"]?.int == clipID { o["leftMedia"] = .number(JSONNumber(newID)) }
        }

        try swap.commit([(loc.trackPath, track)], in: project)
        rightID = newID
        appliedTime = at
    }

    public func revert(on project: Project) throws {
        try swap.restore(in: project)
        rightID = nil
        appliedTime = nil
    }

    /// Splits `left` (the original) and `right` (its copy) at track time `at`.
    static func split(left: JSONObject, right: JSONObject, at: Int64) throws {
        let t = try Timing(left)
        let d = at - t.start
        guard d > 0, d < t.duration else {
            throw EditError.invalid("split point \(at) is outside clip \(left.clipID ?? -1)")
        }
        TimeWriter.set(d, "duration", in: left)
        TimeWriter.set(at, "start", in: right)
        TimeWriter.set(t.duration - d, "duration", in: right)

        if Retime.isStill(left) {
            Retime.moveStillStart(right, by: d)
            return
        }
        let md = try t.media(d)
        let boundary = try Exact.add(t.mediaStart, md)
        TimeWriter.set(md, "mediaDuration", in: left)
        TimeWriter.set(boundary, "mediaStart", in: right)
        TimeWriter.set(try Exact.sub(t.mediaDuration, md), "mediaDuration", in: right)

        switch left.clipType {
        case "UnifiedMedia":
            for k in ["video", "audio"] {
                guard let l = left[k]?.object, let r = right[k]?.object else { continue }
                try split(left: l, right: r, at: at)
            }
        case "StitchedMedia":
            try partition(left: left, right: right, boundary: boundary)
        default:
            break  // Group: inner timeline untouched. Leaf clips: done.
        }
    }


    /// Keeps in each half only the stitched segments its media window uses.
    /// `boundary` is the split point in the stitched clip's inner time (the
    /// left half's media end and the right half's media start).
    private static func partition(left: JSONObject, right: JSONObject, boundary: Rational) throws {
        func span(_ s: JSON) -> (start: Int64, end: Int64)? {
            guard let o = s.object else { return nil }
            let st = o["start"]?.int ?? 0
            return (st, st + (o["duration"]?.int ?? 0))
        }
        if let segs = left["medias"]?.array {
            let kept = segs.items.filter { s in span(s).map { Exact.less(Rational($0.start), boundary) } ?? true }
            if !kept.isEmpty { segs.items = kept }
        }
        guard let segs = right["medias"]?.array else { return }
        let kept = segs.items.filter { s in span(s).map { Exact.less(boundary, Rational($0.end)) } ?? true }
        guard !kept.isEmpty else { return }
        segs.items = kept
        guard let shift = kept.first.flatMap(span)?.start, shift > 0 else { return }
        for s in kept {
            if let o = s.object, let st = o["start"]?.int { TimeWriter.set(st - shift, "start", in: o) }
        }
        TimeWriter.set(try Exact.sub(boundary, Rational(shift)), "mediaStart", in: right)
    }
}
