import Foundation
import TSCProjKit

/// Ripple trim: like `TrimClip`, but neighbours never block the edge and
/// later clips on the same track shift by the change in length, so no gap
/// or overlap appears. Dragging the start edge keeps the clip's `start` and
/// moves only its in-point (`mediaStart`), like a ripple edit [inf].
/// Timeline markers are not moved [inf].
@MainActor
public final class RippleTrim: EditCommand {
    public let clipID: Int64
    public let edge: TrimEdge
    /// Requested edge position in the clip's track coordinates (ticks), as for `TrimClip`.
    public let target: Int64
    public var name: String { "Ripple Trim" }
    /// Edge position applied by the last `apply` (before the ripple shift for a start edge).
    public private(set) var appliedEdge: Int64?
    private var swap = TrackSwap()

    public init(clipID: Int64, edge: TrimEdge, to target: Int64) {
        self.clipID = clipID; self.edge = edge; self.target = target
    }

    public func apply(to project: Project) throws {
        appliedEdge = try TrimClip.trim(clipID, edge, target, ripple: true, project: project, swap: &swap)
    }

    public func revert(on project: Project) throws {
        try swap.restore(in: project)
        appliedEdge = nil
    }
}

/// Ripple move: takes a top-level clip out of its track (closing the gap:
/// later clips shift left by its duration) and inserts it at `start` on
/// `toTrack`, pushing the clips at or after `start` right by its duration.
///
/// - `start` is read **after** the gap has closed, i.e. in the destination
///   track's coordinates without the clip [inf, our choice; the UI computes
///   the drop point on that layout].
/// - A destination clip that straddles `start` makes `apply` throw (drop on
///   a clip edge). On a magnetic track the clip goes to the nearest boundary.
/// - One-sided transitions on the clip travel with it; two-sided ones that
///   reference it are removed.
@MainActor
public final class RippleMove: EditCommand {
    public let clipID: Int64
    public let toTrack: Int
    public let start: Int64
    public var name: String { "Ripple Move" }
    private var swap = TrackSwap()

    public init(clipID: Int64, toTrack: Int, start: Int64) {
        self.clipID = clipID; self.toTrack = toTrack; self.start = start
    }

    public func apply(to project: Project) throws {
        let loc = try Locator.locate(clipID, in: project)
        let destPath = try Locator.siblingTrack(of: loc, toTrack, in: project)
        let at = FrameGrid(project).nearest(start)
        guard at >= 0 else { throw EditError.invalid("start must be ≥ 0") }

        var edits = TrackEdits(project)
        let source = try edits.track(at: loc.trackPath)
        guard let medias = source["medias"]?.array, let clip = medias[loc.index].object else {
            throw EditError.clipNotFound(clipID)
        }
        let duration = clip["duration"]?.int ?? 0
        let oldEnd = (clip["start"]?.int ?? 0) + duration
        medias.items.remove(at: loc.index)
        TrimClip.shiftLater(in: source, except: -1, from: oldEnd, by: -duration)

        var travelling: [JSON] = []
        if let tr = source["transitions"]?.array {
            tr.items.removeAll { t in
                guard let o = t.object else { return false }
                let l = o["leftMedia"]?.int, r = o["rightMedia"]?.int
                guard l == clipID || r == clipID else { return false }
                if l == nil || r == nil { travelling.append(t) }
                return true
            }
        }

        let dest = try edits.track(at: destPath)
        Magnetic.shift(clip, by: at - (clip["start"]?.int ?? 0))
        if Magnetic.isMagnetic(project, path: destPath) {
            Magnetic.insert(clip, into: dest, start: at)
        } else {
            for o in trackClips(dest) {
                let s = o["start"]?.int ?? 0, e = s + (o["duration"]?.int ?? 0)
                if s < at && at < e { throw EditError.invalid("start \(at) is inside clip \(o.clipID ?? -1)") }
            }
            TrimClip.shiftLater(in: dest, except: -1, from: at, by: duration)
            try M2.insertSorted(clip, into: dest)
        }
        if !travelling.isEmpty { TransitionEdit.transitions(dest).items.append(contentsOf: travelling) }
        if destPath != loc.trackPath, !loc.trackPath.isTopLevelTrack, Magnetic.isMagnetic(project, path: loc.trackPath) {
            Magnetic.pack(source)
        }
        try edits.packMagnetic()
        try edits.commit(&swap)
    }

    public func revert(on project: Project) throws { try swap.restore(in: project) }
}

/// Changes a clip's speed. `scalar = 1 / speed` and
/// `mediaDuration × scalar = duration` (time-mapping.md §3): the media range
/// stays, `duration` becomes `mediaDuration / speed` rounded down to a frame
/// (at least one), and `mediaDuration` is then recomputed exactly as
/// `duration / scalar` (so it may become a rational string, as in Camtasia's
/// files [obs]). `UnifiedMedia` halves get the same fields. Keyframes stay
/// on the media axis (time-mapping.md §6, X4 open).
///
/// `metadata.clipSpeedAttribute.value` = speed ≠ 1 and `effectApplied` =
/// `"Clip Speed"` [obs, vlog]; back to speed 1 sets `"none"` when it said
/// "Clip Speed" [inf]. If the clip grows into its right neighbour, `apply`
/// throws unless `ripple` (later clips then shift by the length change;
/// with `ripple` a shrinking clip also pulls them left). Images and callouts
/// have no media time and throw.
@MainActor
public final class SetClipSpeed: EditCommand {
    public let clipID: Int64
    /// Playback speed, e.g. 2 for 2× (must be > 0).
    public let speed: Rational
    public let ripple: Bool
    public var name: String { "Clip Speed" }
    private var swap = TrackSwap()

    public init(clipID: Int64, speed: Rational, ripple: Bool = false) {
        self.clipID = clipID; self.speed = speed; self.ripple = ripple
    }

    public func apply(to project: Project) throws {
        guard speed.num > 0, speed.den > 0 else { throw EditError.invalid("speed must be > 0") }
        let loc = try Locator.locate(clipID, in: project)
        guard !["IMFile", "Callout"].contains(loc.clip.clipType) else {
            throw EditError.invalid("clip \(clipID) has no media time to speed up")
        }
        let grid = FrameGrid(project)
        let t = try Timing(loc.clip)
        let scalar = try Exact.div(Rational(1), speed)
        let newDuration = max(grid.floor(Exact.floor(try Exact.mul(t.mediaDuration, scalar))),
                              grid.ceil(1))
        let mediaDuration = try Exact.div(Rational(newDuration), scalar)
        let delta = newDuration - t.duration

        let magnetic = Magnetic.isMagnetic(project, path: loc.trackPath)
        var edits = TrackEdits(project)
        let track = try edits.track(at: loc.trackPath)
        guard let clip = track["medias"]?.array?[loc.index].object else { throw EditError.clipNotFound(clipID) }
        if delta > 0 && !ripple && !magnetic {
            for (i, o) in trackClips(track).enumerated() where i != loc.index {
                let s = o["start"]?.int ?? 0
                if s >= t.end && s < t.end + delta {
                    throw EditError.invalid("clip \(clipID) would overlap clip \(o.clipID ?? -1)")
                }
            }
        }
        for p in TrimClip.timedParts(clip) {
            TimeWriter.set(scalar, "scalar", in: p)
            TimeWriter.set(newDuration, "duration", in: p)
            TimeWriter.set(mediaDuration, "mediaDuration", in: p)
        }
        if let md = clip["metadata"]?.object {
            let changed = speed != Rational(1)
            if let attr = md["clipSpeedAttribute"]?.object { attr["value"] = .bool(changed) }
            if changed { md["effectApplied"] = .string("Clip Speed") }
            else if md["effectApplied"]?.string == "Clip Speed" { md["effectApplied"] = .string("none") }
        }
        if ripple || magnetic { TrimClip.shiftLater(in: track, except: loc.index, from: t.end, by: delta) }
        try edits.packMagnetic()
        try edits.commit(&swap)
    }

    public func revert(on project: Project) throws { try swap.restore(in: project) }
}

/// Extend frame: holds a clip's last frame for `duration` ticks after it.
///
/// **[inf] JSON shape, needs a Camtasia check:** we insert a new clip right
/// after the original — a copy of the video clip (the `video` half for a
/// `UnifiedMedia`, which keeps the parent's `metadata`) whose media range is
/// the last output frame (`mediaStart` = media end − 1 frame, `mediaDuration`
/// = 1 frame) and whose `scalar` = `duration` / 1 frame, i.e. a slowed-down
/// single frame. This plays correctly under the documented time mapping.
/// Later clips on the track shift right by `duration`. Isolated in
/// `freezeClip` so it can change once the real shape is known.
@MainActor
public final class ExtendFrame: EditCommand {
    public let clipID: Int64
    /// Hold length, ticks (frame-snapped, > 0).
    public let duration: Int64
    public var name: String { "Extend Frame" }
    /// Id of the inserted hold clip after `apply`.
    public private(set) var freezeID: Int64?
    private var swap = TrackSwap()

    public init(clipID: Int64, duration: Int64) { self.clipID = clipID; self.duration = duration }

    public func apply(to project: Project) throws {
        let grid = FrameGrid(project)
        let d = grid.nearest(duration)
        guard d > 0 else { throw EditError.invalid("hold must be at least one frame") }
        let loc = try Locator.locate(clipID, in: project)
        var edits = TrackEdits(project)
        let track = try edits.track(at: loc.trackPath)
        guard let clip = track["medias"]?.array?[loc.index].object else { throw EditError.clipNotFound(clipID) }
        let frame = Rational(grid.ceil(1))
        var next = project.maxID
        let freeze = try Self.freezeClip(clip, hold: d, frame: frame, next: &next)
        let end = (clip["start"]?.int ?? 0) + (clip["duration"]?.int ?? 0)
        TrimClip.shiftLater(in: track, except: loc.index, from: end, by: d)
        track["medias"]?.array?.items.insert(.object(freeze), at: loc.index + 1)
        try edits.packMagnetic()
        try edits.commit(&swap)
        freezeID = freeze.clipID
    }

    public func revert(on project: Project) throws { try swap.restore(in: project); freezeID = nil }

    static func freezeClip(_ clip: JSONObject, hold: Int64, frame: Rational, next: inout Int64) throws -> JSONObject {
        let source: JSONObject
        switch clip.clipType {
        case "VMFile", "ScreenVMFile":
            source = clip
        case "UnifiedMedia":
            guard let v = clip["video"]?.object else { throw EditError.invalid("UnifiedMedia has no video") }
            source = v
        default:
            throw EditError.invalid("extend frame needs a video clip")
        }
        let t = try Timing(source)
        let f = source.copy()
        if clip !== source, let md = clip["metadata"]?.object, f["metadata"] == nil {
            // Top-level clips carry metadata; keep the key order of a leaf (before animationTracks).
            let anim = f["animationTracks"]
            f["animationTracks"] = nil
            f["metadata"] = .object(md.copy())
            if let anim { f["animationTracks"] = anim }
        }
        let mediaEnd = try Exact.add(t.mediaStart, t.mediaDuration)
        let last = try Exact.sub(mediaEnd, frame)
        TimeWriter.set(Exact.less(last, t.mediaStart) ? t.mediaStart : last, "mediaStart", in: f)
        TimeWriter.set(frame, "mediaDuration", in: f)
        TimeWriter.set(try Exact.div(Rational(hold), frame), "scalar", in: f)
        TimeWriter.set(t.end, "start", in: f)
        TimeWriter.set(hold, "duration", in: f)
        IDs.remap(.object(f), next: &next)
        return f
    }
}
