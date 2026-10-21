import Foundation
import TSCProjKit

// Where a media-bin item dropped on the canvas or the timeline goes
// (ui-workflow.md §4, group-edits.md §8.6–§8.7, edit-semantics.md ED3).
//
// - Canvas drop: at the playhead, on the lowest track with room for the
//   whole clip from the playhead; if none has room, a new top track [obs ui1–ui3,
//   rule inf].
// - Timeline drop onto a free spot: that track, at the drop time. Above the
//   top track: a new top track [obs].
// - Timeline drop onto a busy spot, in this order [obs RT-028, order inf]:
//   (a) at or just after a clip's start: insert there and push that track's
//       later clips right, even on a non-magnetic track (in a group they may
//       leave the window);
//   (b) the lowest higher track with room for the whole clip at that time;
//   (c) a new top track. Camtasia was also seen refusing such a drop; WizRec
//       takes the forgiving variant [WizRec].
// - Inside an open group the same rules apply to its inner tracks, and the
//   group never grows (§8.6) [obs].

/// Where a media-bin drop is aimed.
public enum DropTarget: Sendable, Equatable {
    /// A drop on the timeline onto track `track` of the container (top-level
    /// tracks, or the open group's inner tracks; 0 = bottom). `track` equal to
    /// the container's track count (or larger) is the empty area above the top
    /// track. `at` is ticks: `.timeline` = project time, `.inner` = the group's
    /// inner time (the same as project time at top level).
    case timeline(track: Int, at: GroupTime)
    /// A drop on the canvas: the clip goes at the playhead, project ticks
    /// (mapped onto the group's inner timeline when a group is the container).
    case canvas(playhead: Int64)
}

/// The decision of the drop placement rules: which track, which start, and
/// how far the later clips move.
public struct DropPlacement: Sendable, Equatable {
    /// Which rule placed the clip.
    public enum Rule: Sendable, Equatable {
        /// The drop's own track, at the drop time (a free spot, or a magnetic
        /// track, which then packs as in ED3, so the final start may differ).
        case target
        /// Inserted at a clip's start on the drop's track; that clip and the
        /// later ones on the track move right by `push` (§8.7 (a)).
        case insertAtClipStart
        /// The lowest track with room for the whole clip at `start`: a higher
        /// track for a busy timeline drop (§8.7 (b)), any track for a canvas drop.
        case lowestTrackWithRoom
        /// A new track on top of the container (`track` = its track count).
        case newTopTrack
    }

    /// Which rule applied.
    public var rule: Rule
    /// Container track index (top-level, or the group's inner track; 0 = bottom).
    /// Equal to the container's track count for `newTopTrack`.
    public var track: Int
    /// Clip start, ticks in container time (project time at top level, the
    /// group's inner time in a group), on the frame grid.
    public var start: Int64
    /// Ticks the clips on `track` that end after `start` move right
    /// (`insertAtClipStart` only; 0 otherwise).
    public var push: Int64

    public init(rule: Rule, track: Int, start: Int64, push: Int64 = 0) {
        self.rule = rule; self.track = track; self.start = start; self.push = push
    }
}

/// The pure placement function for media-bin drops, shared by the hover
/// feedback (TimelineUI) and `DropClip`.
@MainActor
public enum DropRules {
    /// How far after a clip's start (seconds) a busy drop still inserts at that
    /// start, inclusive [WizRec]. Camtasia's bound is [?] (group-edits.md §8.7):
    /// it inserted ≈ 0.3 s and ≈ 0.7–1 s after a start (d5, d4), made new tracks
    /// ≈ 1.7 s and ≈ 2.7 s in (d3, g2), and both inserted (g4) and added nothing
    /// (g3) ≈ 1.7 s in. 1 s matches all but g4. The drop must also lie in the
    /// clip's first half, so a drop near a short clip's end does not insert
    /// before it [WizRec].
    public static let insertWindowSeconds: Int64 = 1

    /// The default insert window in ticks of `project`'s timebase.
    public static func insertWindow(in project: Project) -> Int64 {
        let (t, o) = insertWindowSeconds.multipliedReportingOverflow(by: project.timebase.editRate)
        return o ? Int64.max / 4 : t
    }

    /// Duration (ticks) of the clip `InsertClip` makes for source `source`.
    /// Throws when there is no such source or it has no usable stream.
    public static func clipDuration(source: Int64, in project: Project) throws -> Int64 {
        try M2.newClip(sourceID: source, start: 0, project)["duration"]?.int ?? 0
    }

    /// Where a clip of `duration` ticks dropped at `target` goes. `group` nil =
    /// the top-level tracks, else the inner tracks of that (open) group.
    ///
    /// Canvas: the lowest unlocked track with room from the playhead, else a new
    /// top track. Timeline: a free spot or a magnetic track takes the clip
    /// (`target`); a busy spot tries `insertAtClipStart`, then the lowest higher
    /// unlocked track with room, then a new top track. Camtasia sometimes
    /// refuses a busy drop with no room; WizRec always adds the new top track
    /// [WizRec, the forgiving variant of §8.7]. Locked tracks are never chosen
    /// by the searches [WizRec]. "Room" means the whole clip fits at the start
    /// (on a magnetic track: the start is the track's packed end).
    /// `insertWindow` (ticks) overrides `insertWindowSeconds`, e.g. with a
    /// zoom-dependent value; it must then be passed to `DropClip` too.
    ///
    /// Never throws on project data (missing keys read as Camtasia's defaults);
    /// throws only when `group` is not a group in `project`. Top-level starts
    /// are clamped to ≥ 0 (a top-level clip cannot start before 0); group starts
    /// are not clamped (§8.6). A track index below 0 reads as 0, one above the
    /// top as the area above the top track.
    public static func place(_ target: DropTarget, group: Int64? = nil, duration: Int64, in project: Project,
                             insertWindow: Int64? = nil) throws -> DropPlacement {
        let c = try DropContainer(project, group: group)
        let d = max(1, duration)
        switch target {
        case .canvas(let playhead):
            let s = c.start(.timeline(playhead))
            if let i = c.tracks.indices.first(where: { !c.locked($0) && c.hasRoom($0, s, d) }) {
                return DropPlacement(rule: .lowestTrackWithRoom, track: i, start: s)
            }
            return DropPlacement(rule: .newTopTrack, track: c.tracks.count, start: s)
        case .timeline(let track, let time):
            let s = c.start(time)
            let k = max(0, track)
            guard k < c.tracks.count else { return DropPlacement(rule: .newTopTrack, track: c.tracks.count, start: s) }
            if c.magnetic(k) || c.hasRoom(k, s, d) { return DropPlacement(rule: .target, track: k, start: s) }
            let window = max(0, insertWindow ?? Self.insertWindow(in: project))
            if let a = c.insertStart(k, s, window: window) {
                let push: Int64 = a.start &+ d &- a.clipStart
                return DropPlacement(rule: .insertAtClipStart, track: k, start: a.start, push: push)
            }
            if let i = c.tracks.indices.first(where: { $0 > k && !c.locked($0) && c.hasRoom($0, s, d) }) {
                return DropPlacement(rule: .lowestTrackWithRoom, track: i, start: s)
            }
            return DropPlacement(rule: .newTopTrack, track: c.tracks.count, start: s)
        }
    }
}

/// The tracks a drop can land on: the scene's top-level tracks or one group's
/// inner tracks, read from the current project.
@MainActor
struct DropContainer {
    let project: Project
    let group: JSONObject?
    let tracks: [(path: JSONPath, track: JSONObject)]
    let grid: FrameGrid

    init(_ project: Project, group groupID: Int64?) throws {
        self.project = project
        grid = FrameGrid(project)
        if let groupID {
            let loc = try GroupChain.locateGroup(groupID, in: project)
            group = loc.clip
            let base = loc.clipPath.appending(.key("tracks"))
            let items = loc.clip["tracks"]?.array?.items ?? []
            tracks = items.enumerated().compactMap { i, v in v.object.map { (base.appending(.index(i)), $0) } }
        } else {
            group = nil
            tracks = Locator.sceneTracks(project)
        }
    }

    /// Container-time start (ticks, frame grid) for `time`. Top level: ≥ 0.
    func start(_ time: GroupTime) -> Int64 {
        guard let group else {
            switch time { case .timeline(let t), .inner(let t): return max(0, grid.nearest(t)) }
        }
        switch time {
        case .inner(let t): return grid.nearest(t)
        case .timeline(let t): return grid.nearest(innerTicks(t, group))
        }
    }

    /// Project ticks `t` on the group's inner timeline (floored): through every
    /// enclosing group (`GroupTiming`); for timing that can't be read exactly
    /// (bad scalar, overflow), the speed-1 mapping `t − start + mediaStart`.
    private func innerTicks(_ t: Int64, _ group: JSONObject) -> Int64 {
        if let id = group.clipID, let r = try? GroupTiming.innerTime(group: id, timeline: t, in: project) {
            return Exact.floor(r)
        }
        let ms = Rational(group["mediaStart"]).map(Exact.floor) ?? 0
        return t &- (group["start"]?.int ?? 0) &+ ms
    }

    func magnetic(_ i: Int) -> Bool { Magnetic.isMagnetic(project, path: tracks[i].path) }

    /// `metadata.IsLocked` "True": `trackAttributes` at top level, inline on group tracks.
    func locked(_ i: Int) -> Bool {
        let attrs: JSONObject?
        if group == nil {
            let all = project.timeline?.trackAttributes ?? []
            attrs = all.indices.contains(i) ? all[i] : nil
        } else {
            attrs = tracks[i].track
        }
        return attrs?["metadata"]?.object?["IsLocked"]?.string == "True"
    }

    /// True when a clip of `d` ticks lands at `s` on track `i` and stays there:
    /// nothing overlaps `[s, s + d)`; on a magnetic track, `s` is its packed end.
    func hasRoom(_ i: Int, _ s: Int64, _ d: Int64) -> Bool {
        let clips = trackClips(tracks[i].track)
        if magnetic(i) {
            var end: Int64 = 0
            for o in clips {
                let cs: Int64 = o["start"]?.int ?? 0
                let cd: Int64 = o["duration"]?.int ?? 0
                end = max(end, cs &+ cd)
            }
            return s == end
        }
        let e = s &+ d
        return !clips.contains { o in
            let cs = o["start"]?.int ?? 0
            return cs < e && s < cs &+ (o["duration"]?.int ?? 0)
        }
    }

    /// Insert point for a busy drop at `s` on track `i`: the clip containing `s`
    /// when `s` is within `window` ticks of its start and in its first half.
    /// The new clip starts at the first frame at or after that clip's start.
    func insertStart(_ i: Int, _ s: Int64, window: Int64) -> (start: Int64, clipStart: Int64)? {
        for o in trackClips(tracks[i].track) {
            let cs = o["start"]?.int ?? 0, cd = o["duration"]?.int ?? 0
            guard cs <= s, s < cs &+ cd else { continue }
            let off = s - cs
            guard off <= window, off &* 2 < cd else { return nil }
            return (grid.ceil(cs), cs)
        }
        return nil
    }
}

// MARK: - The drop command

/// Drops source `sourceID` on the canvas or the timeline as one undo step
/// ("Add to Timeline"), placed by `DropRules.place` on the project as it is
/// when applied. `group` nil = top level, else the inner tracks of that open
/// group. The clip is the one `InsertClip` (top level) or `InsertClipInGroup`
/// (in a group: canvas-default transform re-expressed, group never grows)
/// makes; `newTopTrack` adds the track first (`AddTrack` / a new inner track),
/// and `insertAtClipStart` first moves the track's later clips right by
/// `push`. A two-sided transition between a clip that stays and one that moves
/// is split into its one-sided halves, as for clips moved apart
/// [obs transitions.md TR2]. Markers never move [obs X8].
@MainActor
public final class DropClip: EditCommand {
    public let name = "Add to Timeline"
    public let sourceID: Int64
    /// Open group whose inner tracks receive the clip; nil = top level.
    public let group: Int64?
    public let target: DropTarget
    /// Insert window override, ticks (see `DropRules.place`); nil = `insertWindowSeconds`.
    public let insertWindow: Int64?
    /// Id of the new clip, set by `apply`.
    public private(set) var clipID: Int64?
    /// The placement used by the last `apply`.
    public private(set) var placement: DropPlacement?
    private var done: [any EditCommand] = []

    public init(sourceID: Int64, group: Int64? = nil, _ target: DropTarget, insertWindow: Int64? = nil) {
        self.sourceID = sourceID; self.group = group; self.target = target; self.insertWindow = insertWindow
    }

    public func apply(to project: Project) throws {
        let d = try DropRules.clipDuration(source: sourceID, in: project)
        let p = try DropRules.place(target, group: group, duration: d, in: project, insertWindow: insertWindow)
        var steps: [any EditCommand] = []
        let insert: any EditCommand
        if let group {
            if p.rule == .insertAtClipStart {
                let loc = try GroupChain.locateGroup(group, in: project)
                steps.append(PushClips(track: loc.clipPath.appending(.key("tracks"), .index(p.track)),
                                       after: p.start, by: p.push))
            }
            insert = InsertClipInGroup(sourceID: sourceID, group: group, track: p.track, at: .inner(p.start))
        } else {
            if p.rule == .newTopTrack { steps.append(AddTrack(at: p.track)) }
            if p.rule == .insertAtClipStart {
                steps.append(PushClips(track: JSONPath.sceneTracks.appending(.index(p.track)), after: p.start, by: p.push))
            }
            insert = InsertClip(sourceID: sourceID, track: p.track, start: p.start)
        }
        steps.append(insert)
        var applied: [any EditCommand] = []
        do {
            for s in steps { try s.apply(to: project); applied.append(s) }
        } catch {
            for s in applied.reversed() { try? s.revert(on: project) }
            throw error
        }
        done = applied
        placement = p
        clipID = (insert as? InsertClip)?.clipID ?? (insert as? InsertClipInGroup)?.clipID
    }

    public func revert(on project: Project) throws {
        guard !done.isEmpty else { throw EditError.invalid("nothing to revert") }
        for s in done.reversed() { try s.revert(on: project) }
        done = []; clipID = nil; placement = nil
    }
}

/// Moves the clips of the track at `track` (any depth) that end after `after`
/// right by `by` ticks (`UnifiedMedia` halves with them), splitting two-sided
/// transitions between a staying and a moving clip into one-sided halves.
@MainActor
final class PushClips: EditCommand {
    let name = "Push Clips"
    let path: JSONPath
    let after: Int64
    let by: Int64
    private var swap = TrackSwap()

    init(track path: JSONPath, after: Int64, by: Int64) { self.path = path; self.after = after; self.by = by }

    func apply(to project: Project) throws {
        guard by > 0 else { throw EditError.invalid("push must be > 0") }
        var edits = TrackEdits(project)
        let t = try edits.track(at: path)
        var moved = Set<Int64>()
        for o in trackClips(t) {
            let cs: Int64 = o["start"]?.int ?? 0
            let cd: Int64 = o["duration"]?.int ?? 0
            guard cs &+ cd > after else { continue }
            Magnetic.shift(o, by: by)
            if let id = o.clipID { moved.insert(id) }
        }
        if let tr = t["transitions"]?.array {
            tr.items = tr.items.flatMap { v -> [JSON] in
                guard let o = v.object, let l = o["leftMedia"]?.int, let r = o["rightMedia"]?.int,
                      moved.contains(l) != moved.contains(r) else { return [v] }
                let left = o.copy(), right = o.copy()
                left["rightMedia"] = nil
                right["leftMedia"] = nil
                return [.object(left), .object(right)]
            }
        }
        try edits.commit(&swap)
    }

    func revert(on project: Project) throws { try swap.restore(in: project) }
}
