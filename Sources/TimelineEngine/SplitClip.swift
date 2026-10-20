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
/// - `Group`: both halves hold a full copy of the inner timeline (the right
///   one with new ids); only the window moves [obs, group-edits.md §5].
/// - `StitchedMedia`: both halves keep every segment (new ids on the right);
///   only the outer window moves [obs, edit-semantics.md X7 #1].
/// - `IMFile`: `mediaStart`/`mediaDuration` stay (images have no media
///   time); the right half's `trimStartSum` grows by `d` (`Retime`) [obs, X7 #5].
///
/// Keyframes, effect windows and `animationTracks` are on the media time axis
/// (time-mapping.md §6–7), so both halves keep them unchanged and unpruned
/// [obs, X7 #4].
///
/// Transitions on the clip's track: one whose `leftMedia` is the clip (at its
/// end) now points at the right half; `rightMedia` (at its start) stays on
/// the left half [obs, X7 #3].
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
        default:
            break  // Group and StitchedMedia: inner content copied whole. Leaf clips: done.
        }
    }
}
