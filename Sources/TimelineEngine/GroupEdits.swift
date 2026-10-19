import Foundation
import TSCProjKit

// Editing the inner timeline of a `Group` clip: adding and removing inner
// tracks, and dropping media onto an inner track.
//
// Group structure [obs: demo group (format 10), ThemeEditorDemo group
// (older format)]: `group.tracks[]` holds the inner tracks, bottom to top,
// with `trackIndex` equal to the array position. Inner tracks carry their UI
// flags inline (`ident, audioMuted, videoHidden, magnetic, matte, solo`);
// they have no `timeline.trackAttributes` entry, so these commands never
// touch `trackAttributes`.

// MARK: - Group time mapping

/// A time for dropping media into a group.
public enum GroupTime: Sendable, Equatable {
    /// Ticks on the project timeline (top-level track time). Mapped through
    /// every enclosing group to the target group's inner timeline.
    case timeline(Int64)
    /// Ticks on the target group's inner timeline (the units of its inner
    /// clips' `start`).
    case inner(Int64)
}

/// Converts between project-timeline ticks and a group's inner-timeline
/// ticks, through every enclosing group: `inner = mediaStart + (t − start) /
/// scalar` per level (time-mapping.md §4). Results are exact rationals.
@MainActor
public enum GroupTiming {
    /// Inner-timeline time of group `groupID` at project time `timeline` (ticks).
    public static func innerTime(group groupID: Int64, timeline: Int64, in project: Project) throws -> Rational {
        var t = Rational(timeline)
        for g in try GroupChain.groups(to: groupID, in: project) {
            let tm = try Timing(g)
            t = try Exact.add(tm.mediaStart, Exact.div(Exact.sub(t, Rational(tm.start)), tm.scalar))
        }
        return t
    }

    /// Project-timeline time (ticks) of inner time `inner` of group `groupID`.
    public static func timelineTime(group groupID: Int64, inner: Int64, in project: Project) throws -> Rational {
        var t = Rational(inner)
        for g in try GroupChain.groups(to: groupID, in: project).reversed() {
            let tm = try Timing(g)
            t = try Exact.add(Rational(tm.start), Exact.mul(Exact.sub(t, tm.mediaStart), tm.scalar))
        }
        return t
    }
}

/// The chain of `Group` clips from the outermost one down to a given group.
@MainActor
enum GroupChain {
    /// Paths of every clip in `trackPath` (a track path) that encloses it,
    /// outermost first: each `medias[i]` step followed by `tracks`.
    static func enclosingClipPaths(_ trackPath: JSONPath) -> [JSONPath] {
        let s = trackPath.steps
        var out: [JSONPath] = []
        for i in s.indices where i + 1 < s.count {
            if case .index = s[i], i > 0, s[i - 1] == .key("medias"), s[i + 1] == .key("tracks") {
                out.append(JSONPath(steps: Array(s[...i])))
            }
        }
        return out
    }

    /// The group `groupID` (must be a `Group`) and its location.
    static func locateGroup(_ groupID: Int64, in project: Project) throws -> ClipLocation {
        let loc = try Locator.locate(groupID, in: project)
        guard loc.clip.clipType == "Group" else { throw EditError.invalid("clip \(groupID) is not a group") }
        return loc
    }

    /// Group objects from the outermost enclosing group down to `groupID` itself.
    static func groups(to groupID: Int64, in project: Project) throws -> [JSONObject] {
        let loc = try locateGroup(groupID, in: project)
        let outer = enclosingClipPaths(loc.trackPath).compactMap { $0.resolve(in: project.root)?.object }
        return outer + [loc.clip]
    }
}

// MARK: - Add / remove inner tracks

/// Inserts an empty track inside group `groupID` at inner index `index`
/// (0 = bottom, `count` = new top). The new track has the demo's inline
/// flags, all off [obs]. Inner `trackIndex` fields are renumbered to the
/// array position. The group's timing is unchanged.
@MainActor
public final class AddGroupTrack: EditCommand {
    public let name = "Add Track"
    public let groupID: Int64
    /// Inner track index the new track gets (0 = bottom).
    public let index: Int
    private var swap = TrackSwap()

    public init(group groupID: Int64, at index: Int) { self.groupID = groupID; self.index = index }

    public func apply(to project: Project) throws {
        let loc = try GroupChain.locateGroup(groupID, in: project)
        var edits = TrackEdits(project)
        let g = try GroupEdit.group(loc, &edits)
        var items = g["tracks"]?.array?.items ?? []
        guard (0...items.count).contains(index) else { throw EditError.trackNotFound(index) }
        items.insert(.object(ProjectTemplate.groupTrack(index: index)), at: index)
        g["tracks"] = .array(M2.renumbered(items))
        try edits.commit(&swap)
    }

    public func revert(on project: Project) throws { try swap.restore(in: project) }
}

/// Removes inner track `index` of group `groupID` with its clips and
/// transitions. Remaining inner `trackIndex` fields are renumbered. A group
/// keeps at least one track (removing the last throws) [inf]. The group's
/// timing is unchanged, even when the removed clips were the latest [inf].
@MainActor
public final class RemoveGroupTrack: EditCommand {
    public let name = "Remove Track"
    public let groupID: Int64
    /// Inner track index to remove (0 = bottom).
    public let index: Int
    private var swap = TrackSwap()

    public init(group groupID: Int64, at index: Int) { self.groupID = groupID; self.index = index }

    public func apply(to project: Project) throws {
        let loc = try GroupChain.locateGroup(groupID, in: project)
        var edits = TrackEdits(project)
        let g = try GroupEdit.group(loc, &edits)
        var items = g["tracks"]?.array?.items ?? []
        guard items.indices.contains(index) else { throw EditError.trackNotFound(index) }
        guard items.count > 1 else { throw EditError.invalid("a group keeps at least one track") }
        items.remove(at: index)
        g["tracks"] = .array(M2.renumbered(items))
        try edits.commit(&swap)
    }

    public func revert(on project: Project) throws { try swap.restore(in: project) }
}

// MARK: - Dropping media into a group

/// Places a source on inner track `track` of group `groupID`, as the clip
/// type `InsertClip` would make (same ids rule: above `Project.maxID`).
///
/// - `at` is mapped to the group's inner timeline (`GroupTiming`), floored
///   to a tick and snapped to the nearest frame.
/// - The clip must start inside the group's visible window
///   `[mediaStart, mediaStart + mediaDuration]` [our choice: a clip left of
///   it would be hidden]. Overlap on a non-magnetic inner track throws; a
///   magnetic inner track takes the clip at the insertion point and packs.
/// - When the clip (after packing) ends past the visible window, the group's
///   `mediaDuration` grows to the clip end and `duration` follows
///   (`duration = ceil(mediaDuration × scalar)`); enclosing groups grow the
///   same way. Growing must not overlap the next clip on the group's own
///   track (throws) unless that track is magnetic (packed) [inf: Camtasia
///   groups end at their latest child, demo]. `attributes.maxDurationAttr`
///   is left as is (meaning unknown).
@MainActor
public final class InsertClipInGroup: EditCommand {
    public let name = "Add to Timeline"
    public let sourceID: Int64
    public let groupID: Int64
    /// Inner track index (0 = bottom).
    public let track: Int
    public let time: GroupTime
    /// Id of the new clip, set by `apply`.
    public private(set) var clipID: Int64?
    private var swap = TrackSwap()

    public init(sourceID: Int64, group groupID: Int64, track: Int, at time: GroupTime) {
        self.sourceID = sourceID; self.groupID = groupID; self.track = track; self.time = time
    }

    public func apply(to project: Project) throws {
        let loc = try GroupChain.locateGroup(groupID, in: project)
        let innerTrackPath = loc.clipPath.appending(.key("tracks"), .index(track))
        guard innerTrackPath.resolve(in: project.root)?.object != nil else { throw EditError.trackNotFound(track) }

        let raw: Int64
        switch time {
        case .inner(let t): raw = t
        case .timeline(let t): raw = Exact.floor(try GroupTiming.innerTime(group: groupID, timeline: t, in: project))
        }
        let start = FrameGrid(project).nearest(raw)
        let gt = try Timing(loc.clip)
        let visibleEnd = try Exact.add(gt.mediaStart, gt.mediaDuration)
        guard start >= 0, !Exact.less(Rational(start), gt.mediaStart), !Exact.less(visibleEnd, Rational(start)) else {
            throw EditError.invalid("time is outside the group's visible range")
        }

        let clip = try M2.newClip(sourceID: sourceID, start: start, project)
        let duration = clip["duration"]?.int ?? 0

        // Editable copies: the inner track, then the group's own track and
        // every enclosing track (deepest first, as TrackEdits requires).
        var edits = TrackEdits(project)
        let inner = try edits.track(at: innerTrackPath)
        if Magnetic.isMagnetic(project, path: innerTrackPath) {
            Magnetic.insert(clip, into: inner, start: start)
        } else {
            for o in trackClips(inner) {
                let s = o["start"]?.int ?? 0, e = s + (o["duration"]?.int ?? 0)
                if s < start + duration && start < e {
                    throw EditError.invalid("clip would overlap clip \(o.clipID ?? -1) on group track \(track)")
                }
            }
            try M2.insertSorted(clip, into: inner)
        }
        try GroupEdit.grow(loc, toFit: inner, &edits, project)
        try edits.packMagnetic()
        try edits.commit(&swap)
        clipID = clip.clipID
    }

    public func revert(on project: Project) throws { try swap.restore(in: project); clipID = nil }
}

@MainActor
enum GroupEdit {
    /// The editable copy of the group at `loc`.
    static func group(_ loc: ClipLocation, _ edits: inout TrackEdits) throws -> JSONObject {
        let t = try edits.track(at: loc.trackPath)
        guard let g = t["medias"]?.array?[loc.index].object, g.clipType == "Group" else {
            throw EditError.invalid("group not found")
        }
        return g
    }

    /// Grows the group at `loc` (and its enclosing groups) so `track`'s
    /// latest clip end is visible. `track` is an edited inner track of it.
    static func grow(_ loc: ClipLocation, toFit track: JSONObject, _ edits: inout TrackEdits,
                     _ project: Project) throws {
        var contentEnd = trackClips(track).map { ($0["start"]?.int ?? 0) + ($0["duration"]?.int ?? 0) }.max() ?? 0
        // Group clip paths, innermost first; each with the track path holding it.
        let chain = (GroupChain.enclosingClipPaths(loc.trackPath) + [loc.clipPath]).reversed()
        for clipPath in chain {
            guard case .index(let mi)? = clipPath.steps.last else { throw EditError.invalid("bad group path") }
            let holder = JSONPath(steps: Array(clipPath.steps.dropLast(2)))
            let parent = try edits.track(at: holder)
            guard let g = parent["medias"]?.array?[mi].object else { throw EditError.invalid("group not found") }
            let tm = try Timing(g)
            let visibleEnd = try Exact.add(tm.mediaStart, tm.mediaDuration)
            guard Exact.less(visibleEnd, Rational(contentEnd)) else { return }
            let md = try Exact.sub(Rational(contentEnd), tm.mediaStart)
            let scaled = try Exact.mul(md, tm.scalar)
            let newDuration = Exact.floor(scaled) + (scaled.den == 1 ? 0 : 1)
            let newMD = scaled.den == 1 ? md : try Exact.div(Rational(newDuration), tm.scalar)
            let newEnd = tm.start + newDuration
            if !Magnetic.isMagnetic(project, path: holder) {
                for o in trackClips(parent) where o !== g {
                    let s = o["start"]?.int ?? 0, e = s + (o["duration"]?.int ?? 0)
                    if s < newEnd && tm.start < e {
                        throw EditError.invalid("group \(g.clipID ?? -1) would grow into clip \(o.clipID ?? -1)")
                    }
                }
            }
            TimeWriter.set(newMD, "mediaDuration", in: g)
            TimeWriter.set(newDuration, "duration", in: g)
            contentEnd = trackClips(parent).map { ($0["start"]?.int ?? 0) + ($0["duration"]?.int ?? 0) }.max() ?? 0
            if Magnetic.isMagnetic(project, path: holder) {
                // Packing happens at commit; after it the track ends at the sum of durations.
                contentEnd = trackClips(parent).reduce(0) { $0 + ($1["duration"]?.int ?? 0) }
            }
        }
    }
}
