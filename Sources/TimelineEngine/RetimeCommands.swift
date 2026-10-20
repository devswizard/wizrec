import Foundation
import TSCProjKit

/// Ripple trim: like `TrimClip`, but neighbours never block the edge and
/// later clips on the same track shift by the change in length, so no gap
/// or overlap appears. Dragging the start edge keeps the clip's `start` and
/// moves only its in-point (`mediaStart`), like a ripple edit [inf].
/// Timeline markers (`timeline.parameters.toc`) are not moved [obs for
/// ripple delete, markers.md X8; inf for ripple trim].
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
/// - One-sided transitions on the clip travel with it; a two-sided one is
///   split into a one-sided half that stays on the other clip and one that
///   travels with this clip ([obs] for Cut/Paste, transitions.md TR2; [inf]
///   for ripple move).
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
            tr.items = tr.items.compactMap { t in
                guard let o = t.object else { return t }
                let l = o["leftMedia"]?.int, r = o["rightMedia"]?.int
                guard l == clipID || r == clipID else { return t }
                if l == nil || r == nil { travelling.append(t); return nil }
                // Two-sided: split into one-sided halves (transitions.md TR2).
                let stays = o.copy(), moves = o.copy()
                stays[l == clipID ? "leftMedia" : "rightMedia"] = nil
                moves[l == clipID ? "rightMedia" : "leftMedia"] = nil
                travelling.append(.object(moves))
                return .object(stays)
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
/// Shape [obs, edit-semantics.md ED1]: the clip becomes a `StitchedMedia`
/// (new id, `StitchClips.parent`, parameters gain
/// `smoothCursorAcrossEditDuration` 0) holding two segments: the original
/// clip (id kept) and an `IMFile` on the **same video source** whose
/// `mediaStart` is the media time of the clip's last output frame,
/// `mediaDuration` 1 (the image convention), `trimStartSum` 0 and
/// `attributes.ident` "Frame of <ident>". The frame segment's `duration` is
/// the hold [inf; Camtasia wrote a much longer segment that the outer
/// duration cuts]. Its crops are copied from the clip [inf].
///
/// - `VMFile`/`ScreenVMFile` [obs]; `UnifiedMedia` [inf]: the frame comes
///   from the `video` child, the whole clip is the first segment.
/// - `StitchedMedia` [inf]: the window must end at its last segment's end; a
///   trailing frame segment grows, otherwise a frame segment is appended.
///
/// Transitions on the clip are relinked to the stitched id. Later clips on
/// the track shift right by `duration` [inf].
@MainActor
public final class ExtendFrame: EditCommand {
    public let clipID: Int64
    /// Hold length, ticks (frame-snapped, > 0).
    public let duration: Int64
    public var name: String { "Extend Frame" }
    /// Id of the frame (`IMFile`) segment after `apply`.
    public private(set) var freezeID: Int64?
    /// Id of the `StitchedMedia` holding the clip and its frame after `apply`.
    public private(set) var stitchedID: Int64?
    private var swap = TrackSwap()

    public init(clipID: Int64, duration: Int64) { self.clipID = clipID; self.duration = duration }

    public func apply(to project: Project) throws {
        let grid = FrameGrid(project)
        let d = grid.nearest(duration)
        guard d > 0 else { throw EditError.invalid("hold must be at least one frame") }
        let loc = try Locator.locate(clipID, in: project)
        var edits = TrackEdits(project)
        let track = try edits.track(at: loc.trackPath)
        guard let medias = track["medias"]?.array, let clip = medias[loc.index].object else {
            throw EditError.clipNotFound(clipID)
        }
        let frame = grid.ceil(1)
        let end = (clip["start"]?.int ?? 0) + (clip["duration"]?.int ?? 0)
        var next = project.maxID
        let result: JSONObject
        if clip.clipType == "StitchedMedia" {
            result = clip.copy()
            freezeID = try Self.extendStitched(result, hold: d, frame: frame, next: &next)
        } else {
            let freeze = try Self.frameSegment(of: clip, hold: d, frame: frame, next: &next)
            next += 1
            result = StitchClips.parent(id: next, segments: [clip, freeze],
                                        extraParameters: [("smoothCursorAcrossEditDuration", J.int(0))])
            freezeID = freeze.clipID
            if let tr = track["transitions"]?.array {
                for t in tr.items.compactMap(\.object) {
                    if t["leftMedia"]?.int == clipID { t["leftMedia"] = J.int(next) }
                    if t["rightMedia"]?.int == clipID { t["rightMedia"] = J.int(next) }
                }
            }
        }
        medias.items[loc.index] = .object(result)
        TrimClip.shiftLater(in: track, except: loc.index, from: end, by: d)
        try edits.packMagnetic()
        try edits.commit(&swap)
        stitchedID = result.clipID
    }

    public func revert(on project: Project) throws { try swap.restore(in: project); freezeID = nil; stitchedID = nil }

    /// The `IMFile` showing the last output frame of `clip` (a video leaf or
    /// `UnifiedMedia`), `hold` ticks long, with a new id from `next`.
    static func frameSegment(of clip: JSONObject, hold: Int64, frame: Int64, next: inout Int64) throws -> JSONObject {
        let video: JSONObject
        switch clip.clipType {
        case "VMFile", "ScreenVMFile": video = clip
        case "UnifiedMedia":
            guard let v = clip["video"]?.object else { throw EditError.invalid("UnifiedMedia has no video") }
            video = v
        default: throw EditError.invalid("extend frame needs a video clip")
        }
        guard let src = video["src"] else { throw EditError.invalid("video clip has no source") }
        let t = try Timing(video)
        let mediaEnd = try Exact.add(t.mediaStart, t.mediaDuration)
        let last = try Exact.sub(mediaEnd, t.media(frame))
        let ident = Clip(video).name ?? Clip(clip).name ?? ""
        let crops = (video["parameters"]?.object?.entries ?? [])
            .filter { $0.key.hasPrefix("geometryCrop") || $0.key.hasPrefix("sourceCrop") }
            .map { ($0.key, $0.value.copy()) }
        next += 1
        let f = JSONObject([
            ("id", J.int(next)), ("_type", .string("IMFile")), ("src", src.copy()),
            ("trackNumber", video["trackNumber"]?.copy() ?? J.int(0)), ("trimStartSum", J.int(0)),
            ("attributes", J.obj([("ident", .string("Frame of \(ident)"))])),
            ("parameters", J.obj(crops)), ("effects", J.emptyArray),
            ("start", J.int(t.end)), ("duration", J.int(hold)), ("mediaStart", J.int(0)),
            ("mediaDuration", J.int(1)), ("scalar", J.int(1)), ("animationTracks", J.emptyObject),
        ])
        TimeWriter.set(Exact.less(last, t.mediaStart) ? t.mediaStart : last, "mediaStart", in: f)
        return f
    }

    /// Extends a `StitchedMedia` (edited in place) by `hold`; returns the frame segment's id.
    static func extendStitched(_ s: JSONObject, hold: Int64, frame: Int64, next: inout Int64) throws -> Int64 {
        let t = try Timing(s)
        guard t.scalar == Rational(1) else { throw EditError.invalid("extending a sped-up stitched clip is not supported") }
        guard let segs = s["medias"]?.array, let lastSeg = segs.items.last?.object else {
            throw EditError.invalid("stitched clip has no segments")
        }
        let segEnd = (lastSeg["start"]?.int ?? 0) + (lastSeg["duration"]?.int ?? 0)
        guard try Exact.add(t.mediaStart, t.mediaDuration) == Rational(segEnd) else {
            throw EditError.invalid("the stitched clip does not end at its last segment")
        }
        let id: Int64
        if lastSeg.clipType == "IMFile" {
            TimeWriter.set(Rational((lastSeg["duration"]?.int ?? 0) + hold), "duration", in: lastSeg)
            id = lastSeg.clipID ?? -1
        } else {
            let f = try frameSegment(of: lastSeg, hold: hold, frame: frame, next: &next)
            segs.items.append(.object(f))
            id = f.clipID ?? -1
        }
        TimeWriter.set(Rational(t.duration + hold), "duration", in: s)
        TimeWriter.set(try Exact.add(t.mediaDuration, Rational(hold)), "mediaDuration", in: s)
        return id
    }
}
