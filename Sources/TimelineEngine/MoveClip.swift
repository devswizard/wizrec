import Foundation
import TSCProjKit

/// Moves a clip to a position on a track of the same container (the same
/// track or another).
///
/// - `toTrack` is the index in the scene's `tracks` array (0 = bottom) for a
///   top-level clip, or in its group's inner `tracks` for a clip inside a
///   group; `start` is then on the group's inner timeline. Moving between
///   containers is not supported (throws). The group's own timing is not
///   changed [inf]; inner clips outside its window are simply not shown.
/// - The clip must not overlap any other clip on the destination track; if it
///   would, `apply` throws `.invalid` and nothing changes. (Ripple and
///   magnetic tracks come in M3.) On a magnetic destination track the clip
///   is inserted at the nearest clip boundary instead and the track is packed
///   (`Magnetic`); a magnetic source track closes the gap.
/// - The clip object moves unchanged except `start` (and the `start` of
///   `UnifiedMedia` halves, which mirror the parent's); it is inserted into the
///   destination `medias` in start order.
///
/// Transitions referencing the clip on its source track (assumptions):
/// - one-sided (fade in/out: only `leftMedia` or only `rightMedia`, and it
///   is this clip) travel with the clip; a destination track without a
///   `transitions` key gets one appended;
/// - two-sided ones stay only if the move is within the same track and the
///   clip still touches the other clip on that side; otherwise they are
///   removed.
@MainActor
public final class MoveClip: EditCommand {
    public let clipID: Int64
    /// Destination index in the clip's container: the scene's top-level
    /// `tracks`, or the group's inner `tracks` for a nested clip.
    public let toTrack: Int
    /// Requested `start` on the destination track, in project ticks. Snapped
    /// to the nearest output frame unless sub-frame editing is on.
    public let start: Int64
    public var name: String { "Move" }

    private var swap = TrackSwap()

    public init(clipID: Int64, toTrack: Int, start: Int64) {
        self.clipID = clipID
        self.toTrack = toTrack
        self.start = start
    }

    public func apply(to project: Project) throws {
        let loc = try Locator.locate(clipID, in: project)
        let destPath = try Locator.siblingTrack(of: loc, toTrack, in: project)
        let start = FrameGrid(project).nearest(self.start)
        guard start >= 0 else { throw EditError.invalid("start must be ≥ 0") }

        let duration = loc.clip["duration"]?.int ?? 0
        let end = start + duration
        let sameTrack = destPath == loc.trackPath

        var trackEdits = TrackEdits(project)
        let source = try trackEdits.track(at: loc.trackPath)
        let dest = sameTrack ? source : try trackEdits.track(at: destPath)
        guard let srcMedias = source["medias"]?.array, let clip = srcMedias[loc.index].object else {
            throw EditError.clipNotFound(clipID)
        }
        srcMedias.items.remove(at: loc.index)

        let destMagnetic = Magnetic.isMagnetic(project, path: destPath)
        let destClips = trackClips(dest)
        for o in destClips where !destMagnetic {
            let s = o["start"]?.int ?? 0, e = s + (o["duration"]?.int ?? 0)
            if s < end && start < e {
                throw EditError.invalid("clip \(clipID) would overlap clip \(o.clipID ?? -1) on track \(toTrack)")
            }
        }
        // UnifiedMedia halves carry the parent's start [obs], so they move too.
        let oldStart = clip["start"]?.int ?? 0
        for part in TrimClip.timedParts(clip) {
            TimeWriter.set(start + ((part["start"]?.int ?? oldStart) - oldStart), "start", in: part)
        }
        if destMagnetic {
            Magnetic.insert(clip, into: dest, start: start)
        } else {
            if dest["medias"]?.array == nil { dest["medias"] = .array(JSONArray()) }
            guard let destMedias = dest["medias"]?.array else { throw EditError.trackNotFound(toTrack) }
            let at = destMedias.items.firstIndex { ($0.object?["start"]?.int ?? 0) > start } ?? destMedias.count
            destMedias.items.insert(.object(clip), at: at)
        }
        if !sameTrack && Magnetic.isMagnetic(project, path: loc.trackPath) { Magnetic.pack(source) }

        if let transitions = source["transitions"]?.array {
            var travelling: [JSON] = []
            transitions.items = transitions.items.filter { tr in
                guard let o = tr.object else { return true }
                let l = o["leftMedia"]?.int, r = o["rightMedia"]?.int
                guard l == clipID || r == clipID else { return true }
                if l == nil || r == nil {
                    if sameTrack { return true }
                    travelling.append(tr)
                    return false
                }
                guard sameTrack else { return false }
                let otherID = l == clipID ? r : l
                guard let other = destClips.first(where: { $0.clipID == otherID }) else { return false }
                let os = other["start"]?.int ?? 0, oe = os + (other["duration"]?.int ?? 0)
                return l == clipID ? end == os : oe == start
            }
            if !travelling.isEmpty {
                if dest["transitions"]?.array == nil { dest["transitions"] = .array(JSONArray()) }
                dest["transitions"]?.array?.items.append(contentsOf: travelling)
            }
        }

        try trackEdits.commit(&swap)
    }

    public func revert(on project: Project) throws {
        try swap.restore(in: project)
    }
}
