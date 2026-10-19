import Foundation
import TSCProjKit

/// Which edge of a clip a trim moves.
public enum TrimEdge: Sendable, Equatable {
    /// The in-point: moves `start` and `mediaStart` together.
    case start
    /// The out-point: changes `duration` only.
    case end
}

/// Moves a clip's start or end edge to a tick (snapped to the nearest output
/// frame unless sub-frame editing is on), clamped so the clip
/// - never overlaps its neighbours on the same track,
/// - never starts before tick 0 of its track,
/// - never shows media before its lower bound (0, or `minMediaStart` for a
///   stitched clip) or past the end of the available media: file streams from
///   `sourceTracks[trackNumber].range`, a group's inner timeline, a stitched
///   clip's segments. Images, callout ends and open-ended sources (shader
///   `range` up to 2^63−1) are unbounded. Media limits are rounded inward to
///   whole frames (time-mapping.md §2: a whole-source clip is the source
///   length rounded down to a frame).
/// - keeps a positive duration (otherwise `apply` throws `.invalid`).
///
/// Limits only stop a clip from growing: a clip that already violates one
/// (e.g. media metadata shorter than the clip) can still shrink.
///
/// Media maths is exact (`mediaDuration × scalar = duration`): moving the
/// start by `δ` ticks moves `mediaStart` by `δ / scalar`. `UnifiedMedia` trims
/// its `video` and `audio` halves to the same edge, each with its own fields,
/// and is limited by the shorter one. Group and stitched contents are not
/// changed; only the clip's window into them moves. Images keep
/// `mediaStart`/`mediaDuration` and move `trimStartSum` instead (`Retime`).
///
/// Keyframes, effect windows and `animationTracks` are on the media time axis
/// and stay unchanged (time-mapping.md §6–7). Transitions stay as they are.
@MainActor
public final class TrimClip: EditCommand {
    public let clipID: Int64
    public let edge: TrimEdge
    /// Requested edge position in the clip's track coordinates (ticks).
    public let target: Int64
    public var name: String { "Trim" }

    /// Edge position actually applied by the last `apply`, after snapping and
    /// clamping.
    public private(set) var appliedEdge: Int64?

    private var swap = TrackSwap()

    public init(clipID: Int64, edge: TrimEdge, to target: Int64) {
        self.clipID = clipID
        self.edge = edge
        self.target = target
    }

    public func apply(to project: Project) throws {
        appliedEdge = try Self.trim(clipID, edge, target, ripple: false, project: project, swap: &swap)
    }

    /// Shared by `TrimClip` and `RippleTrim`. Without `ripple`, neighbours
    /// limit growth (except on a magnetic top-level track, which ripples and
    /// is packed). With `ripple`, neighbours never limit: later clips on the
    /// track shift by the length change, and a start-edge trim keeps the
    /// clip's `start` (only its in-point moves). Returns the applied edge
    /// position (for a rippled start edge: where the edge would sit without
    /// the ripple shift).
    static func trim(_ clipID: Int64, _ edge: TrimEdge, _ target: Int64, ripple wantRipple: Bool,
                     project: Project, swap: inout TrackSwap) throws -> Int64 {
        let loc = try Locator.locate(clipID, in: project)
        let magnetic = loc.topLevelTrack.map { Magnetic.isMagnetic(project, track: $0) } ?? false
        let ripple = wantRipple || magnetic
        let t = try Timing(loc.clip)
        let grid = FrameGrid(project)
        let want = grid.nearest(target)
        let others = trackClips(loc.track).enumerated().filter { $0.offset != loc.index }.map(\.element)
        let parts = Self.timedParts(loc.clip)

        let track = loc.track.copy()
        guard let clip = track["medias"]?.array?[loc.index].object else { throw EditError.clipNotFound(clipID) }

        let edgeTick: Int64
        switch edge {
        case .end:
            var limit = Int64.max
            for o in others where !ripple && (o["start"]?.int ?? 0) >= t.start {
                limit = min(limit, o["start"]?.int ?? 0)
            }
            for p in parts where !Retime.isStill(p) {
                guard let len = MediaExtent.length(of: p, in: project) else { continue }
                let pt = try Timing(p)
                // end ≤ start + (length − mediaStart) × scalar
                let room = Exact.floor(try Exact.mul(Exact.sub(len, pt.mediaStart), pt.scalar))
                limit = min(limit, grid.floor(pt.start + room))
            }
            // Limits only stop growth; a clip already past a limit may still shrink.
            let newEnd = want > t.end ? min(want, max(limit, t.end)) : want
            guard newEnd > t.start else { throw EditError.invalid("trim leaves clip \(clipID) empty") }
            edgeTick = newEnd
            for p in Self.timedParts(clip) { try Self.setEnd(p, to: newEnd) }
            if ripple { shiftLater(in: track, except: loc.index, from: t.end, by: newEnd - t.end) }
        case .start:
            // A track starts at tick 0; a rippled start edge does not move the clip, so no floor.
            var limit: Int64 = ripple ? Int64.min / 4 : 0
            for o in others where !ripple && (o["start"]?.int ?? 0) < t.start {
                limit = max(limit, (o["start"]?.int ?? 0) + (o["duration"]?.int ?? 0))
            }
            for p in parts where !Retime.isStill(p) {
                let pt = try Timing(p)
                // start ≥ start − (mediaStart − lowerBound) × scalar
                let spare = try Exact.mul(Exact.sub(pt.mediaStart, MediaExtent.lowerBound(of: p)), pt.scalar)
                limit = max(limit, grid.ceil(pt.start - Exact.floor(spare)))
            }
            let newStart = want < t.start ? max(want, min(limit, t.start)) : want
            guard newStart < t.end else { throw EditError.invalid("trim leaves clip \(clipID) empty") }
            edgeTick = newStart
            for p in Self.timedParts(clip) { try Self.setStart(p, to: newStart) }
            if ripple {
                let delta = newStart - t.start
                Magnetic.shift(clip, by: -delta)
                shiftLater(in: track, except: loc.index, from: t.end, by: -delta)
            }
        }
        if magnetic { Magnetic.pack(track) }
        try swap.commit([(loc.trackPath, track)], in: project)
        return edgeTick
    }

    /// Shifts every clip of `track` (except `medias[index]`) that starts at
    /// or after `from` by `delta` ticks.
    static func shiftLater(in track: JSONObject, except index: Int, from: Int64, by delta: Int64) {
        guard delta != 0 else { return }
        for (i, m) in (track["medias"]?.array?.items ?? []).enumerated() where i != index {
            guard let o = m.object, (o["start"]?.int ?? 0) >= from else { continue }
            Magnetic.shift(o, by: delta)
        }
    }

    public func revert(on project: Project) throws {
        try swap.restore(in: project)
        appliedEdge = nil
    }

    /// The clip and, for `UnifiedMedia`, its `video`/`audio` halves.
    static func timedParts(_ clip: JSONObject) -> [JSONObject] {
        guard clip.clipType == "UnifiedMedia" else { return [clip] }
        return [clip] + ["video", "audio"].compactMap { clip[$0]?.object }
    }

    /// Moves the end edge to track time `end`; `mediaDuration` changes by
    /// `Δduration / scalar`.
    static func setEnd(_ o: JSONObject, to end: Int64) throws {
        let t = try Timing(o)
        let newDuration = end - t.start
        guard newDuration != t.duration else { return }
        guard newDuration > 0 else { throw EditError.invalid("trim leaves clip \(o.clipID ?? -1) empty") }
        TimeWriter.set(newDuration, "duration", in: o)
        guard !Retime.isStill(o) else { return }
        let dm = try t.media(newDuration - t.duration)
        TimeWriter.set(try Exact.add(t.mediaDuration, dm), "mediaDuration", in: o)
    }

    /// Moves the start edge to track time `start`.
    static func setStart(_ o: JSONObject, to start: Int64) throws {
        let t = try Timing(o)
        let delta = start - t.start  // positive = shorter clip
        guard delta != 0 else { return }
        guard delta < t.duration else { throw EditError.invalid("trim leaves clip \(o.clipID ?? -1) empty") }
        TimeWriter.set(start, "start", in: o)
        TimeWriter.set(t.duration - delta, "duration", in: o)
        guard !Retime.isStill(o) else {
            Retime.moveStillStart(o, by: delta)
            return
        }
        let dm = try t.media(delta)
        TimeWriter.set(try Exact.add(t.mediaStart, dm), "mediaStart", in: o)
        TimeWriter.set(try Exact.sub(t.mediaDuration, dm), "mediaDuration", in: o)
    }
}
