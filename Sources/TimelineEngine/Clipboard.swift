import Foundation
import TSCProjKit

/// Copied clips, independent of the project they came from.
///
/// `data` is a small JSON document written with TSCProjKit (put it on the
/// pasteboard as is):
/// `{"wizrecClipboard": 2, "editRate": n, ["space": [tx, ty, sx, sy]],
///   "items": [{"track", "start", "clip"}], "transitions": [{"track", "transition"}],
///   "sources": [sourceBin entries]}`.
/// `track`/`start` are offsets from the top-most-left copied clip (lowest
/// track index, earliest start); `start` offsets are project-timeline ticks,
/// also for clips copied from inside a group (mapped out through every
/// enclosing group, floored to a tick). Transitions are kept only when every
/// clip they reference was copied and sits on the transition's track.
///
/// `space` (present only when it is not the identity) is the constant
/// position (canvas px) and scale the enclosing groups apply to the copied
/// clips: each clip's canvas transform is `t + s × its own`
/// (`translation0/1`, `scale0/1`) [obs, group-edits.md §8.2]. The clips are
/// stored as they are in the project; `PasteClips` composes `space` in.
///
/// Only each group's **constant** position and scale are composed (bare value or
/// `defaultValue`) [WizRec]. A group's rotation, crop, opacity, effects and the keyframes of
/// an animated position/scale are not carried over to the copied clip: the clip keeps its own
/// values for those [WizRec; Camtasia's composition of rotation is [?], group-edits.md §6].
/// Version 1 payloads (before `space`) paste with their transforms untouched.
public struct ClipboardPayload: Sendable, Equatable {
    /// The serialised payload (UTF-8 JSON).
    public let data: Data

    /// Validates `data` (from the pasteboard).
    public init(data: Data) throws {
        guard let o = try JSON.parse(data).object, o["wizrecClipboard"] != nil else {
            throw EditError.invalid("not a WizRec clipboard payload")
        }
        self.data = data
    }

    /// Number of top-level clips in the payload.
    public var clipCount: Int {
        ((try? JSON.parse(data))?.object?["items"]?.array?.count) ?? 0
    }

    /// Copies clips `clipIDs` (any tracks) with their sources.
    ///
    /// - The clips may sit on top-level tracks or on the inner tracks of a
    ///   group (any depth), but all of them in one container: the scene's
    ///   tracks or one group's inner tracks [obs: Camtasia shows one
    ///   container at a time, group-edits.md §8.1]; a selection spanning
    ///   containers throws.
    /// - Clips inside Rev media (a group with `metadata.groupType`
    ///   `"revMedia"`, at any level) can't be copied: Camtasia never opens
    ///   Rev media [obs §8.1; refusal inf].
    /// - A clip from inside a group keeps its own timing (`duration`,
    ///   `mediaStart`, `scalar`), keyframes, effects and metadata (e.g.
    ///   `ShaderVidSource`); the enclosing group's keys (`RevBackground`) are
    ///   not copied [obs §8.2, §8.4]. Its transform is carried in canvas
    ///   space (the payload's `space`) [obs §8.2]. Its `start` offset is
    ///   converted to project-timeline time.
    @MainActor
    public static func copy(clipIDs: [Int64], from project: Project) throws -> ClipboardPayload {
        guard !clipIDs.isEmpty else { throw EditError.invalid("nothing to copy") }
        var seen = Set<Int64>()
        let locs = try clipIDs.filter { seen.insert($0).inserted }.map { try Locator.locate($0, in: project) }
        let container = JSONPath(steps: Array(locs[0].trackPath.steps.dropLast()))
        guard locs.allSatisfy({ JSONPath(steps: Array($0.trackPath.steps.dropLast())) == container }) else {
            throw EditError.invalid("clips from different groups cannot be copied together")
        }
        let enclosing: [JSONObject] = GroupChain.enclosingClipPaths(locs[0].trackPath)
            .compactMap { $0.resolve(in: project.root)?.object }
        guard !enclosing.contains(where: GroupChain.isRevMedia) else {
            throw EditError.invalid("clips inside Rev media can't be copied; unpack it first")
        }
        let space = GroupSpace.of(enclosing)
        var entries: [(track: Int, start: Int64, clip: JSONObject)] = []
        for l in locs {
            guard case .index(let ti)? = l.trackPath.steps.last else { throw EditError.invalid("bad track path") }
            let inner: Int64 = l.clip["start"]?.int ?? 0
            let t: Int64 = l.trackPath.isTopLevelTrack ? inner
                : Exact.floor(try GroupTiming.timelineTime(inner: inner, onTrack: l.trackPath, in: project))
            entries.append((ti, t, l.clip))
        }
        let minTrack: Int = entries.map(\.track).min() ?? 0
        let minStart: Int64 = entries.map(\.start).min() ?? 0
        entries.sort { ($0.track, $0.start) < ($1.track, $1.start) }
        var items: [JSON] = []
        var sourceIDs: [Int64] = []
        for e in entries {
            items.append(J.obj([("track", J.int(e.track - minTrack)), ("start", J.int(e.start - minStart)),
                                ("clip", .object(e.clip.copy()))]))
            for s in Clip(e.clip).referencedSourceIDs.sorted() where !sourceIDs.contains(s) { sourceIDs.append(s) }
        }
        var transitions: [JSON] = []
        let tracks: [JSON] = container.resolve(in: project.root)?.array?.items ?? []
        for ti in Set(entries.map(\.track)).sorted() {
            guard tracks.indices.contains(ti), let track = tracks[ti].object else { continue }
            let onTrack = Set(trackClips(track).compactMap(\.clipID))
            for t in track["transitions"]?.array?.items ?? [] {
                guard let o = t.object else { continue }
                let refs: [Int64] = [o["leftMedia"]?.int, o["rightMedia"]?.int].compactMap { $0 }
                guard !refs.isEmpty, refs.allSatisfy({ seen.contains($0) && onTrack.contains($0) }) else { continue }
                transitions.append(J.obj([("track", J.int(ti - minTrack)), ("transition", .object(o.copy()))]))
            }
        }
        let sources = sourceIDs.compactMap { id in project.source(id: id).map { JSON.object($0.object.copy()) } }
        var pairs: [(String, JSON)] = [("wizrecClipboard", J.int(2)),("editRate", J.int(project.timebase.editRate))]
        if !space.isIdentity { pairs.append(("space", space.json)) }
        pairs += [("items", J.arr(items)), ("transitions", J.arr(transitions)), ("sources", J.arr(sources))]
        return try ClipboardPayload(data: J.obj(pairs).serialized())
    }
}

/// Pastes a `ClipboardPayload` with its top-most-left clip on `track` at
/// `start` (ticks, frame-snapped); the other clips keep their track and time
/// offsets.
///
/// - Every pasted object gets a fresh id above `Project.maxID`; transitions
///   copied with the clips are relinked.
/// - Sources: a payload source whose `src` equals an existing `sourceBin`
///   entry's `src` uses that entry; otherwise the entry is copied with a new
///   id and its `src` **unchanged** — when pasting across projects the app
///   must import or relink those files (`ProjectBundle.missingMedia()`).
/// - The payload's `editRate` must equal the project's.
/// - Transform: the payload's canvas-space transform (`space` composed with
///   each clip's own) is re-expressed relative to the target container
///   (every group enclosing the target track): `t' = (space.t + space.s × t −
///   target.t) / target.s`, `s' = space.s × s / target.s` per axis, keyframe
///   values too [obs, group-edits.md §8.2; the inverse of the §6 ungroup
///   composition, inf]. Pasted back into its own group the clip is unchanged;
///   otherwise the changed `translation0/1`/`scale0/1` are written in the long
///   form [obs §3, §8.2]. Audio clips are not touched. As for `space`, only
///   the target groups' constant position and scale count [WizRec]; version 1
///   payloads keep their transforms.
/// - Top-level paste (`init(_:track:at:)`): target tracks must exist;
///   overlaps throw, except on magnetic tracks, where clips are inserted at
///   the nearest boundary.
/// - Group paste (`init(_:group:at:)`, Camtasia's paste into an open group,
///   group-edits.md §8.3):
///   - The anchor (top-most-left) clip goes to `time` mapped to the group's
///     inner timeline (`GroupTiming`, floored, frame-snapped), **clamped** to
///     the group's window `[mediaStart, mediaStart + mediaDuration]`: a time
///     before the window lands at the window start, one at or after its end
///     lands at the end (hidden) [obs]. Every other clip goes to the inner
///     time of the anchor's timeline time plus its offset [WizRec].
///   - Each payload track goes to the lowest inner track free for all of its
///     clips' spans [obs for one clip; "lowest" inf]; when none is free, a new
///     inner track is added on top [obs]. Further payload tracks go above the
///     previous one's choice, keeping their order [WizRec]. A magnetic inner
///     track that is free takes the clip with a magnetic insert.
///   - The group and its enclosing groups **never grow**; a clip running
///     past the window is hidden [obs].
///   - Clips keep their own `duration`/`scalar`; the target group's speed
///     applies on top [obs §8.2: groups have no speed in Camtasia].
///   - Rev media (`groupType` `"revMedia"`, the target or any enclosing
///     group) is refused: Camtasia can't open it [obs §8.1; refusal inf].
/// - Group paste on a fixed track (`init(_:group:track:at:)`, WizRec only):
///   as above, but payload track `r` goes to inner track `track + r`, which
///   must exist; overlaps throw except on magnetic tracks.
@MainActor
public final class PasteClips: EditCommand {
    public let name = "Paste"
    public let payload: ClipboardPayload
    /// Target track index: a top-level track, or an inner track of `groupID`
    /// (unused when `choosesTrack`).
    public let track: Int
    /// Ticks: the project-timeline paste time; for a group paste, the raw value of `groupTime`.
    public let start: Int64
    /// The (open) group pasted into; nil for a top-level paste.
    public let groupID: Int64?
    /// Paste time of a group paste; nil for a top-level paste.
    public let groupTime: GroupTime?
    /// True when the paste picks the group's inner tracks itself (`init(_:group:at:)`).
    public let choosesTrack: Bool
    /// Ids of the pasted top-level clips, in payload order, after `apply`.
    public private(set) var pastedIDs: [Int64] = []
    /// Track index (top-level, or inner track of `groupID`) of each pasted clip, in
    /// `pastedIDs` order, after `apply`.
    public private(set) var pastedTracks: [Int] = []
    private var tracks = TrackSwap()
    private var values = ValueSwap()

    public init(_ payload: ClipboardPayload, track: Int, at start: Int64) {
        self.payload = payload; self.track = track; self.start = start
        groupID = nil; groupTime = nil; choosesTrack = false
    }

    /// Pastes into open group `groupID` at `time`, on the inner tracks Camtasia would use.
    public init(_ payload: ClipboardPayload, group groupID: Int64, at time: GroupTime) {
        self.payload = payload; track = 0; self.groupID = groupID; self.groupTime = time; choosesTrack = true
        switch time {
        case .timeline(let t), .inner(let t): start = t
        }
    }

    /// Pastes onto inner track `track` (0 = bottom) of group `groupID` at `time` [WizRec].
    public init(_ payload: ClipboardPayload, group groupID: Int64, track: Int, at time: GroupTime) {
        self.payload = payload; self.track = track; self.groupID = groupID; self.groupTime = time
        choosesTrack = false
        switch time {
        case .timeline(let t), .inner(let t): start = t
        }
    }

    public func apply(to project: Project) throws {
        guard let doc = try JSON.parse(payload.data).object else { throw EditError.invalid("bad payload") }
        guard doc["editRate"]?.int == project.timebase.editRate else {
            throw EditError.invalid("clipboard editRate differs from the project's")
        }
        guard track >= 0 else { throw EditError.invalid("paste position must be ≥ 0") }
        var next = project.maxID

        // Sources first: reuse by src, else add.
        var srcMap: [Int64: Int64] = [:]
        var bin = project.root["sourceBin"]?.array?.items ?? []
        let existing = project.sourceBin
        for s in doc["sources"]?.array?.items.compactMap(\.object) ?? [] {
            guard let old = s["id"]?.int else { continue }
            let src = s["src"]?.string ?? ""
            if let match = existing.first(where: { $0.src == src }) {
                srcMap[old] = match.id
            } else {
                let c = s.copy()
                next += 1
                c["id"] = J.int(next)
                srcMap[old] = next
                bin.append(.object(c))
            }
        }

        var idMap: [Int64: Int64] = [:]
        var items: [Item] = []
        for item in doc["items"]?.array?.items.compactMap(\.object) ?? [] {
            guard let c = item["clip"]?.object?.copy() else { continue }
            idMap.merge(IDs.remap(.object(c), next: &next)) { a, _ in a }
            Self.remapSources(c, srcMap)
            items.append(Item(row: Int(item["track"]?.int ?? 0), offset: item["start"]?.int ?? 0, clip: c))
        }
        guard !items.isEmpty else { throw EditError.invalid("clipboard is empty") }

        let target = try Target(groupID, project)
        if (doc["wizrecClipboard"]?.int ?? 1) >= 2 {
            guard let rel = target.space.relative(from: GroupSpace(doc["space"]) ?? .identity) else {
                throw EditError.invalid("the target group has a zero scale")
            }
            for it in items { GroupGeometry.reexpress(it.clip, x: rel.x, y: rel.y) }
        }
        let starts = try target.starts(items.map(\.offset), groupTime ?? .timeline(start), project)
        for (i, it) in items.enumerated() { Magnetic.shift(it.clip, by: starts[i] - (it.clip["start"]?.int ?? 0)) }

        var edits = TrackEdits(project)
        let rows: [Int] = Array(Set(items.map(\.row))).sorted()
        var trackOf: [Int: Int] = [:]
        if choosesTrack, let loc = target.group {
            trackOf = try Self.chooseTracks(rows, items, loc, &edits)
        } else {
            for r in rows { trackOf[r] = track + r }
        }
        func path(_ row: Int) throws -> JSONPath {
            let index: Int = trackOf[row] ?? (track + row)
            return choosesTrack ? target.innerPath(index) : try target.trackPath(index, project)
        }

        let paths: [JSONPath] = try items.map { try path($0.row) }  // missing tracks throw first
        var dests: [JSONObject] = []
        for (i, it) in items.enumerated() {
            let p = paths[i]
            let at: Int64 = it.clip["start"]?.int ?? 0
            let dest = try edits.track(at: p)
            if Magnetic.isMagnetic(project, path: p) {
                Magnetic.insert(it.clip, into: dest, start: at)
            } else {
                let duration: Int64 = it.clip["duration"]?.int ?? 0
                _ = try M2.trackForInsert(dest, start: at, duration: duration, track: trackOf[it.row] ?? it.row)
                try M2.insertSorted(it.clip, into: dest)
            }
            if !dests.contains(where: { $0 === dest }) { dests.append(dest) }
        }
        for t in doc["transitions"]?.array?.items.compactMap(\.object) ?? [] {
            guard let tr = t["transition"]?.object?.copy(),
                  let p = try? path(Int(t["track"]?.int ?? 0)) else { continue }
            for k in ["leftMedia", "rightMedia"] {
                if let old = tr[k]?.int, let new = idMap[old] { tr[k] = J.int(new) }
            }
            TransitionEdit.transitions(try edits.track(at: p)).items.append(.object(tr))
        }
        try edits.packMagnetic()
        let addsSources = bin.count != (project.root["sourceBin"]?.array?.count ?? 0)
        try edits.commit(&tracks)
        if addsSources {
            do {
                try values.commit([(M2.sourceBinPath, J.arr(bin))], in: project)
            } catch {
                try tracks.restore(in: project)
                throw error
            }
        }
        pastedIDs = items.map { $0.clip.clipID ?? -1 }
        pastedTracks = items.map { trackOf[$0.row] ?? (track + $0.row) }
    }

    public func revert(on project: Project) throws {
        if !values.isEmpty { try values.restore(in: project) }
        try tracks.restore(in: project)
        pastedIDs = []
        pastedTracks = []
    }

    /// One payload clip: its payload track (`row`), its time offset and its (remapped) copy.
    private struct Item {
        var row: Int
        var offset: Int64
        var clip: JSONObject
    }

    /// Inner track of the group at `loc` for each payload row (ascending): the lowest
    /// track at or above the previous row's choice + 1 that is free for every clip of the
    /// row (their `start` already set), else a new track appended on top of the group's
    /// editable copy.
    private static func chooseTracks(_ rows: [Int], _ items: [Item], _ loc: ClipLocation,
                                     _ edits: inout TrackEdits) throws -> [Int: Int] {
        let g = try GroupEdit.group(loc, &edits)
        guard let inner = g["tracks"]?.array else { throw EditError.invalid("group has no tracks") }
        var out: [Int: Int] = [:]
        var lowest = 0
        for r in rows {
            let spans: [(Int64, Int64)] = items.filter { $0.row == r }.map { (it: Item) -> (Int64, Int64) in
                let s: Int64 = it.clip["start"]?.int ?? 0
                return (s, s + (it.clip["duration"]?.int ?? 0))
            }
            var chosen: Int? = nil
            var i = lowest
            while chosen == nil, i < inner.count {
                if let t = inner.items[i].object, isFree(t, spans) { chosen = i }
                i += 1
            }
            let pick: Int = chosen ?? inner.count
            if chosen == nil { inner.items.append(.object(ProjectTemplate.groupTrack(index: pick))) }
            out[r] = pick
            lowest = pick + 1
        }
        return out
    }

    /// True when no clip of `track` overlaps any of `spans` (`[start, end)` ticks).
    private static func isFree(_ track: JSONObject, _ spans: [(Int64, Int64)]) -> Bool {
        for o in trackClips(track) {
            let s: Int64 = o["start"]?.int ?? 0
            let e: Int64 = s + (o["duration"]?.int ?? 0)
            if spans.contains(where: { s < $0.1 && $0.0 < e }) { return false }
        }
        return true
    }

    /// Rewrites the `src` source ids of every clip object (objects with `_type`) in `clip`.
    static func remapSources(_ clip: JSONObject, _ map: [Int64: Int64]) {
        func walk(_ v: JSON) {
            if let o = v.object {
                if o["_type"] != nil, let s = o["src"]?.int, let n = map[s] { o["src"] = J.int(n) }
                o.entries.forEach { walk($0.value) }
            } else if let a = v.array {
                a.items.forEach(walk)
            }
        }
        walk(.object(clip))
    }

    /// Where a paste goes: the scene's tracks, or one group's inner tracks.
    @MainActor private struct Target {
        let groupID: Int64?
        /// The target group (in the unedited tree); nil for a top-level paste.
        let group: ClipLocation?
        /// What the groups enclosing the target tracks apply to a clip (identity at top level).
        let space: GroupSpace

        init(_ groupID: Int64?, _ project: Project) throws {
            self.groupID = groupID
            guard let groupID else { group = nil; space = .identity; return }
            group = try GroupChain.locateGroup(groupID, in: project)
            let chain = try GroupChain.groups(to: groupID, in: project)
            guard !chain.contains(where: GroupChain.isRevMedia) else {
                throw EditError.invalid("Rev media can't be opened; unpack it to paste into it")
            }
            space = GroupSpace.of(chain)
        }

        /// Path of inner track `index` of the target group (may not exist yet).
        func innerPath(_ index: Int) -> JSONPath {
            group.map { $0.clipPath.appending(.key("tracks"), .index(index)) }
                ?? JSONPath.sceneTracks.appending(.index(index))
        }

        /// Path of target track `index`; throws `trackNotFound` when missing.
        func trackPath(_ index: Int, _ project: Project) throws -> JSONPath {
            let path = innerPath(index)
            guard index >= 0, path.resolve(in: project.root)?.object != nil else { throw EditError.trackNotFound(index) }
            return path
        }

        /// Start (ticks, in the target tracks' time) of each payload offset.
        func starts(_ offsets: [Int64], _ time: GroupTime, _ project: Project) throws -> [Int64] {
            let grid = FrameGrid(project)
            guard let groupID, let group else {
                guard case .timeline(let t) = time else { throw EditError.invalid("inner time without a group") }
                let at = grid.nearest(t)
                guard at >= 0 else { throw EditError.invalid("paste position must be ≥ 0") }
                return offsets.map { (o: Int64) -> Int64 in at + o }
            }
            var anchor: Int64
            switch time {
            case .inner(let t):
                anchor = grid.nearest(t)
            case .timeline(let t):
                let inner = try GroupTiming.innerTime(group: groupID, timeline: t, in: project)
                anchor = grid.nearest(Exact.floor(inner))
            }
            // Clamp to the visible window [obs, group-edits.md §8.3].
            let gt = try Timing(group.clip)
            let windowEnd = try Exact.add(gt.mediaStart, gt.mediaDuration)
            if Exact.less(Rational(anchor), gt.mediaStart) {
                let f = Exact.floor(gt.mediaStart)
                anchor = Exact.less(Rational(f), gt.mediaStart) ? f + 1 : f
            } else if Exact.less(windowEnd, Rational(anchor)) {
                anchor = Exact.floor(windowEnd)
            }
            guard anchor >= 0 else { throw EditError.invalid("paste position must be ≥ 0") }
            let anchorTimeline = try GroupTiming.timelineTime(group: groupID, inner: anchor, in: project)
            return try offsets.map { (o: Int64) -> Int64 in
                guard o != 0 else { return anchor }
                let at = try Exact.add(anchorTimeline, Rational(o))
                let inner = try GroupTiming.innerTime(group: groupID, timeline: at, in: project)
                let s = grid.nearest(Exact.floor(inner))
                guard s >= 0 else { throw EditError.invalid("pasted clip would start before the group's inner time 0") }
                return s
            }
        }
    }
}
