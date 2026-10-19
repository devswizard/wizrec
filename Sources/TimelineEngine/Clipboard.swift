import Foundation
import TSCProjKit

/// Copied clips, independent of the project they came from.
///
/// `data` is a small JSON document written with TSCProjKit (put it on the
/// pasteboard as is):
/// `{"wizrecClipboard": 1, "editRate": n, "items": [{"track", "start", "clip"}],
///   "transitions": [{"track", "transition"}], "sources": [sourceBin entries]}`.
/// `track`/`start` are offsets from the top-most-left copied clip (lowest
/// track index, earliest start). Transitions are kept only when every clip
/// they reference was copied and sits on the transition's track.
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

    /// Copies top-level clips `clipIDs` (any tracks) with their sources.
    @MainActor
    public static func copy(clipIDs: [Int64], from project: Project) throws -> ClipboardPayload {
        guard !clipIDs.isEmpty else { throw EditError.invalid("nothing to copy") }
        var seen = Set<Int64>()
        let locs = try clipIDs.filter { seen.insert($0).inserted }.map { try Locator.locate($0, in: project) }
        guard locs.allSatisfy({ $0.topLevelTrack != nil }) else {
            throw EditError.invalid("only top-level clips can be copied")
        }
        let minTrack = locs.compactMap(\.topLevelTrack).min() ?? 0
        let minStart = locs.map { $0.clip["start"]?.int ?? 0 }.min() ?? 0
        let sorted = locs.sorted { ($0.topLevelTrack ?? 0, $0.clip["start"]?.int ?? 0) < ($1.topLevelTrack ?? 0, $1.clip["start"]?.int ?? 0) }
        var items: [JSON] = []
        var sourceIDs: [Int64] = []
        for l in sorted {
            items.append(J.obj([("track", J.int((l.topLevelTrack ?? 0) - minTrack)),
                                ("start", J.int((l.clip["start"]?.int ?? 0) - minStart)),
                                ("clip", .object(l.clip.copy()))]))
            for s in Clip(l.clip).referencedSourceIDs.sorted() where !sourceIDs.contains(s) { sourceIDs.append(s) }
        }
        var transitions: [JSON] = []
        let tracks = Locator.sceneTracks(project)
        for ti in Set(locs.compactMap(\.topLevelTrack)).sorted() {
            for t in tracks[ti].track["transitions"]?.array?.items ?? [] {
                guard let o = t.object else { continue }
                let refs = [o["leftMedia"]?.int, o["rightMedia"]?.int].compactMap { $0 }
                let onTrack = Set(trackClips(tracks[ti].track).compactMap(\.clipID))
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
@MainActor
public final class PasteClips: EditCommand {
    public let name = "Paste"
    public let payload: ClipboardPayload
    public let track: Int
    public let start: Int64
    /// Ids of the pasted top-level clips, in payload order, after `apply`.
    public private(set) var pastedIDs: [Int64] = []
    private var tracks = TrackSwap()
    private var values = ValueSwap()

    public init(_ payload: ClipboardPayload, track: Int, at start: Int64) {
        self.payload = payload; self.track = track; self.start = start
    }

    public func apply(to project: Project) throws {
        guard let doc = try JSON.parse(payload.data).object else { throw EditError.invalid("bad payload") }
        guard doc["editRate"]?.int == project.timebase.editRate else {
            throw EditError.invalid("clipboard editRate differs from the project's")
        }
        let at = FrameGrid(project).nearest(start)
        guard at >= 0, track >= 0 else { throw EditError.invalid("paste position must be ≥ 0") }
        let topTracks = Locator.sceneTracks(project)
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

        var edits = TrackEdits(project)
        var idMap: [Int64: Int64] = [:]
        var pasted: [Int64] = []
        var placed: [(track: Int, clip: JSONObject)] = []
        for item in doc["items"]?.array?.items.compactMap(\.object) ?? [] {
            guard let c = item["clip"]?.object?.copy() else { continue }
            let ti = track + Int(item["track"]?.int ?? 0)
            guard topTracks.indices.contains(ti) else { throw EditError.trackNotFound(ti) }
            idMap.merge(IDs.remap(.object(c), next: &next)) { a, _ in a }
            Self.remapSources(c, srcMap)
            Magnetic.shift(c, by: at + (item["start"]?.int ?? 0) - (c["start"]?.int ?? 0))
            placed.append((ti, c))
            pasted.append(c.clipID ?? -1)
        }
        guard !placed.isEmpty else { throw EditError.invalid("clipboard is empty") }
        for (ti, c) in placed {
            let dest = try edits.topTrack(ti)
            let s = c["start"]?.int ?? 0
            if Magnetic.isMagnetic(project, track: ti) {
                Magnetic.insert(c, into: dest, start: s)
            } else {
                _ = try M2.trackForInsert(dest, start: s, duration: c["duration"]?.int ?? 0, track: ti)
                try M2.insertSorted(c, into: dest)
            }
        }
        for t in doc["transitions"]?.array?.items.compactMap(\.object) ?? [] {
            guard let tr = t["transition"]?.object?.copy() else { continue }
            let ti = track + Int(t["track"]?.int ?? 0)
            guard topTracks.indices.contains(ti) else { continue }
            for k in ["leftMedia", "rightMedia"] {
                if let old = tr[k]?.int, let new = idMap[old] { tr[k] = J.int(new) }
            }
            TransitionEdit.transitions(try edits.topTrack(ti)).items.append(.object(tr))
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
        pastedIDs = pasted
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
}
