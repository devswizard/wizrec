import Foundation
import TSCProjKit

/// Copied clips, independent of the project they came from.
///
/// `data` is a small JSON document written with TSCProjKit (put it on the
/// pasteboard as is):
/// `{"wizrecClipboard": 1, "editRate": n, "items": [{"track", "start", "clip"}],
///   "transitions": [{"track", "transition"}], "sources": [sourceBin entries]}`.
/// `track`/`start` are offsets from the top-most-left copied clip (lowest
/// track index, earliest start); `start` offsets are project-timeline ticks,
/// also for clips copied from inside a group (mapped out through every
/// enclosing group, floored to a tick). Transitions are kept only when every
/// clip they reference was copied and sits on the transition's track.
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
    /// The clips may sit on top-level tracks or on the inner tracks of a
    /// group (any depth), but all of them in one container: the scene's
    /// tracks or one group's inner tracks [WizRec: a selection spanning
    /// containers throws]. A clip from inside a group is copied as is: its
    /// own keyframes, effects and metadata (e.g. `ShaderVidSource`) are kept;
    /// the enclosing group's keys (`RevBackground`, group speed) are not
    /// [WizRec]. Its `start` offset is converted to project-timeline time.
    @MainActor
    public static func copy(clipIDs: [Int64], from project: Project) throws -> ClipboardPayload {
        guard !clipIDs.isEmpty else { throw EditError.invalid("nothing to copy") }
        var seen = Set<Int64>()
        let locs = try clipIDs.filter { seen.insert($0).inserted }.map { try Locator.locate($0, in: project) }
        let container = JSONPath(steps: Array(locs[0].trackPath.steps.dropLast()))
        guard locs.allSatisfy({ JSONPath(steps: Array($0.trackPath.steps.dropLast())) == container }) else {
            throw EditError.invalid("clips from different groups cannot be copied together")
        }
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
        let doc = J.obj([
            ("wizrecClipboard", J.int(1)), ("editRate", J.int(project.timebase.editRate)),
            ("items", J.arr(items)), ("transitions", J.arr(transitions)), ("sources", J.arr(sources)),
        ])
        return try ClipboardPayload(data: doc.serialized())
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
/// - Target tracks must exist; overlaps throw, except on magnetic tracks,
///   where clips are inserted at the nearest boundary.
/// - Group paste (`init(_:group:track:at:)`): `track` is an inner track of
///   group `groupID`. The anchor (top-most-left) clip goes to `time` mapped
///   to the group's inner timeline (`GroupTiming`, floored, frame-snapped)
///   and must start inside the group's visible window, as for
///   `InsertClipInGroup`. Every other clip goes to the inner time of the
///   anchor's timeline time plus its offset [WizRec]. Clips keep their own
///   `duration`/`scalar`; the target group's speed applies on top [WizRec].
///   The group and its enclosing groups grow to show the pasted clips, as
///   `InsertClipInGroup` does.
@MainActor
public final class PasteClips: EditCommand {
    public let name = "Paste"
    public let payload: ClipboardPayload
    /// Target track index: a top-level track, or an inner track of `groupID`.
    public let track: Int
    /// Ticks: the project-timeline paste time; for a group paste, the raw value of `groupTime`.
    public let start: Int64
    /// The (open) group pasted into; nil for a top-level paste.
    public let groupID: Int64?
    /// Paste time of a group paste; nil for a top-level paste.
    public let groupTime: GroupTime?
    /// Ids of the pasted top-level clips, in payload order, after `apply`.
    public private(set) var pastedIDs: [Int64] = []
    private var tracks = TrackSwap()
    private var values = ValueSwap()

    public init(_ payload: ClipboardPayload, track: Int, at start: Int64) {
        self.payload = payload; self.track = track; self.start = start
        groupID = nil; groupTime = nil
    }

    /// Pastes onto inner track `track` (0 = bottom) of group `groupID` at `time`.
    public init(_ payload: ClipboardPayload, group groupID: Int64, track: Int, at time: GroupTime) {
        self.payload = payload; self.track = track; self.groupID = groupID; self.groupTime = time
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
        var items: [(track: Int, offset: Int64, clip: JSONObject)] = []
        for item in doc["items"]?.array?.items.compactMap(\.object) ?? [] {
            guard let c = item["clip"]?.object?.copy() else { continue }
            idMap.merge(IDs.remap(.object(c), next: &next)) { a, _ in a }
            Self.remapSources(c, srcMap)
            let ti: Int = track + Int(item["track"]?.int ?? 0)
            items.append((ti, item["start"]?.int ?? 0, c))
        }
        guard !items.isEmpty else { throw EditError.invalid("clipboard is empty") }

        let target = try Target(groupID, project)
        let starts = try target.starts(items.map(\.offset), groupTime ?? .timeline(start), project)
        var edits = TrackEdits(project)
        var dests: [JSONObject] = []
        for (i, it) in items.enumerated() {
            let path = try target.trackPath(it.track, project)
            Magnetic.shift(it.clip, by: starts[i] - (it.clip["start"]?.int ?? 0))
            let dest = try edits.track(at: path)
            if Magnetic.isMagnetic(project, path: path) {
                Magnetic.insert(it.clip, into: dest, start: starts[i])
            } else {
                let duration: Int64 = it.clip["duration"]?.int ?? 0
                _ = try M2.trackForInsert(dest, start: starts[i], duration: duration, track: it.track)
                try M2.insertSorted(it.clip, into: dest)
            }
            if !dests.contains(where: { $0 === dest }) { dests.append(dest) }
        }
        for t in doc["transitions"]?.array?.items.compactMap(\.object) ?? [] {
            guard let tr = t["transition"]?.object?.copy(),
                  let path = try? target.trackPath(track + Int(t["track"]?.int ?? 0), project) else { continue }
            for k in ["leftMedia", "rightMedia"] {
                if let old = tr[k]?.int, let new = idMap[old] { tr[k] = J.int(new) }
            }
            TransitionEdit.transitions(try edits.track(at: path)).items.append(.object(tr))
        }
        if let loc = target.group {
            for t in dests { try GroupEdit.grow(loc, toFit: t, &edits, project) }
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
    }

    public func revert(on project: Project) throws {
        if !values.isEmpty { try values.restore(in: project) }
        try tracks.restore(in: project)
        pastedIDs = []
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

        init(_ groupID: Int64?, _ project: Project) throws {
            self.groupID = groupID
            group = try groupID.map { try GroupChain.locateGroup($0, in: project) }
        }

        /// Path of target track `index`; throws `trackNotFound` when missing.
        func trackPath(_ index: Int, _ project: Project) throws -> JSONPath {
            let path: JSONPath = group.map { $0.clipPath.appending(.key("tracks"), .index(index)) }
                ?? JSONPath.sceneTracks.appending(.index(index))
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
            let anchor: Int64
            switch time {
            case .inner(let t):
                anchor = grid.nearest(t)
            case .timeline(let t):
                let inner = try GroupTiming.innerTime(group: groupID, timeline: t, in: project)
                anchor = grid.nearest(Exact.floor(inner))
            }
            let gt = try Timing(group.clip)
            let visibleEnd = try Exact.add(gt.mediaStart, gt.mediaDuration)
            guard anchor >= 0, !Exact.less(Rational(anchor), gt.mediaStart), !Exact.less(visibleEnd, Rational(anchor)) else {
                throw EditError.invalid("time is outside the group's visible range")
            }
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
