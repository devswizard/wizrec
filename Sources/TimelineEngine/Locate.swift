import Foundation
import TSCProjKit

// MARK: - Paths into the JSON tree

/// One step of a path from the project root: an object key or an array index.
enum PathStep: Equatable {
    case key(String)
    case index(Int)
}

/// Location of a JSON value relative to `Project.root`. Commands remember
/// paths rather than object references, because undoing a later command can
/// swap in different (restored) container objects at the same place.
struct JSONPath: Equatable {
    var steps: [PathStep]

    static let sceneTracks = JSONPath(steps: [
        .key("timeline"), .key("sceneTrack"), .key("scenes"), .index(0), .key("csml"), .key("tracks"),
    ])

    func appending(_ s: PathStep...) -> JSONPath { JSONPath(steps: steps + s) }

    func resolve(in root: JSONObject) -> JSON? {
        var cur = JSON.object(root)
        for s in steps {
            switch s {
            case .key(let k):
                guard let next = cur.object?[k] else { return nil }
                cur = next
            case .index(let i):
                guard let a = cur.array, a.items.indices.contains(i) else { return nil }
                cur = a[i]
            }
        }
        return cur
    }

    /// Replaces the value at this path. Throws if the parent is missing.
    func replace(in root: JSONObject, with value: JSON) throws {
        guard let last = steps.last,
              let parent = JSONPath(steps: Array(steps.dropLast())).resolve(in: root)
        else { throw EditError.invalid("path not found") }
        switch last {
        case .key(let k):
            guard let o = parent.object, o[k] != nil else { throw EditError.invalid("path not found") }
            o[k] = value
        case .index(let i):
            guard let a = parent.array, a.items.indices.contains(i) else {
                throw EditError.invalid("path not found")
            }
            a[i] = value
        }
    }
}

// MARK: - Finding clips

/// Where a clip sits: the track object holding it and its index in
/// `track.medias`. Times of the clip are in its track's coordinates (the
/// project timeline for top-level tracks, the group's inner timeline for
/// tracks inside a `Group`).
struct ClipLocation {
    /// Path to the track object (an element of some `tracks` array).
    let trackPath: JSONPath
    let track: JSONObject
    /// Index of the clip in `track.medias`.
    let index: Int
    let clip: JSONObject
    /// Index in the scene's `tracks` when the clip is on a top-level track.
    let topLevelTrack: Int?
}

enum Locator {
    /// Top-level tracks of the first scene, with their paths.
    static func sceneTracks(_ project: Project) -> [(path: JSONPath, track: JSONObject)] {
        guard let a = JSONPath.sceneTracks.resolve(in: project.root)?.array else { return [] }
        return a.items.enumerated().compactMap { i, v in
            v.object.map { (JSONPath.sceneTracks.appending(.index(i)), $0) }
        }
    }

    /// Finds an editable clip (an entry of some track's `medias`, top level or
    /// inside groups). Throws `.invalid` for the halves of a `UnifiedMedia` and
    /// the segments of a `StitchedMedia`, which are edited through their parent.
    static func locate(_ id: Int64, in project: Project) throws -> ClipLocation {
        var nestedPart = false
        func search(_ tracks: [(path: JSONPath, track: JSONObject)], top: Bool) -> ClipLocation? {
            for (ti, (path, track)) in tracks.enumerated() {
                let medias = track["medias"]?.array?.items ?? []
                for (mi, m) in medias.enumerated() {
                    guard let clip = m.object else { continue }
                    if clip["id"]?.int == id {
                        return ClipLocation(trackPath: path, track: track, index: mi, clip: clip,
                                            topLevelTrack: top ? ti : nil)
                    }
                    for k in ["video", "audio"] where clip[k]?.object?["id"]?.int == id { nestedPart = true }
                    for s in clip["medias"]?.array?.items ?? [] where s.object?["id"]?.int == id {
                        nestedPart = true
                    }
                    if let inner = clip["tracks"]?.array {
                        let base = path.appending(.key("medias"), .index(mi), .key("tracks"))
                        let sub = inner.items.enumerated().compactMap { i, v in
                            v.object.map { (base.appending(.index(i)), $0) }
                        }
                        if let found = search(sub, top: false) { return found }
                    }
                }
            }
            return nil
        }
        if let found = search(sceneTracks(project), top: true) { return found }
        if nestedPart {
            throw EditError.invalid("clip \(id) is part of a UnifiedMedia or StitchedMedia; edit its parent")
        }
        throw EditError.clipNotFound(id)
    }
}

// MARK: - Clip field access

/// Raw timing of one clip object, read with Camtasia defaults for missing keys.
struct Timing {
    var start: Int64
    var duration: Int64
    var mediaStart: Rational
    var mediaDuration: Rational
    /// `mediaDuration × scalar = duration` (scalar = 1 / speed).
    var scalar: Rational

    init(_ o: JSONObject) throws {
        start = o["start"]?.int ?? 0
        duration = o["duration"]?.int ?? 0
        mediaStart = Rational(o["mediaStart"]) ?? Rational(0)
        scalar = Rational(o["scalar"]) ?? Rational(1)
        guard scalar.num > 0 else { throw EditError.invalid("clip has a non-positive scalar") }
        mediaDuration = try Rational(o["mediaDuration"]) ?? Exact.div(Rational(duration), scalar)
    }

    var end: Int64 { start + duration }

    /// Media ticks consumed by `ticks` of timeline.
    func media(_ ticks: Int64) throws -> Rational { try Exact.div(Rational(ticks), scalar) }
}

extension JSONObject {
    var clipType: String { self["_type"]?.string ?? "" }
    var clipID: Int64? { self["id"]?.int }
}

/// Clips of a track's `medias` with their timing, for neighbour checks.
func trackClips(_ track: JSONObject) -> [JSONObject] {
    track["medias"]?.array?.items.compactMap(\.object) ?? []
}

// MARK: - New ids

enum IDs {
    /// Gives every object with an `id` in `value` a fresh id above `next`
    /// (depth-first, key order), then rewrites `leftMedia`/`rightMedia`
    /// references inside the subtree (transitions on a group's inner tracks)
    /// that point at remapped ids. Returns the old → new mapping.
    @discardableResult
    static func remap(_ value: JSON, next: inout Int64) -> [Int64: Int64] {
        var map: [Int64: Int64] = [:]
        func assign(_ v: JSON) {
            if let o = v.object {
                if let old = o["id"]?.int, o["id"]?.number?.isInteger == true {
                    next += 1
                    map[old] = next
                    o["id"] = .number(JSONNumber(next))
                }
                for (_, child) in o.entries { assign(child) }
            } else if let a = v.array {
                a.items.forEach(assign)
            }
        }
        func relink(_ v: JSON) {
            if let o = v.object {
                for k in ["leftMedia", "rightMedia"] {
                    if let old = o[k]?.int, let new = map[old] { o[k] = .number(JSONNumber(new)) }
                }
                for (_, child) in o.entries { relink(child) }
            } else if let a = v.array {
                a.items.forEach(relink)
            }
        }
        assign(value)
        relink(value)
        return map
    }
}

// MARK: - Available media

enum MediaExtent {
    /// Length of the media a clip object can show, in its media-time units
    /// (project ticks for files; inner-timeline ticks for groups and stitched
    /// clips). `nil` means unbounded or unknown (images, callouts, shader
    /// sources with an open range, missing metadata).
    static func length(of clip: JSONObject, in project: Project) -> Rational? {
        switch clip.clipType {
        case "VMFile", "ScreenVMFile", "AMFile":
            guard let src = clip["src"]?.int, let source = project.source(id: src) else { return nil }
            let streams = source.tracks
            let n = Int(clip["trackNumber"]?.int ?? 0)
            guard streams.indices.contains(n) else { return nil }
            let st = streams[n], r = st.range
            guard r.count == 2, st.editRate > 0 else { return nil }
            let (len, o1) = r[1].subtractingReportingOverflow(r[0])
            let (ticks, o2) = len.multipliedReportingOverflow(by: project.timebase.editRate)
            guard !o1, !o2, len >= 0 else { return nil }
            return Rational(ticks, st.editRate)
        case "Group":
            let ends = (clip["tracks"]?.array?.items ?? []).compactMap(\.object)
                .flatMap(trackClips).map { ($0["start"]?.int ?? 0) + ($0["duration"]?.int ?? 0) }
            return ends.max().map { Rational($0) }
        case "StitchedMedia":
            let ends = (clip["medias"]?.array?.items ?? []).compactMap(\.object)
                .map { ($0["start"]?.int ?? 0) + ($0["duration"]?.int ?? 0) }
            return ends.max().map { Rational($0) }
        default:
            return nil
        }
    }

    /// Earliest media time a clip may start at: `minMediaStart` for stitched
    /// clips [inf], otherwise 0.
    static func lowerBound(of clip: JSONObject) -> Rational {
        let m = Rational(clip["minMediaStart"]) ?? Rational(0)
        return Exact.less(m, Rational(0)) ? Rational(0) : m
    }
}

// MARK: - Committing track replacements

/// Remembers the track objects an `apply` swapped out so `revert` can put
/// the originals back. The originals are detached from the tree after
/// `apply` and never mutated, so restoring them reproduces the prior JSON
/// byte for byte (same keys, order and number lexemes).
struct TrackSwap {
    private var replaced: [(path: JSONPath, old: JSONObject)] = []

    var isEmpty: Bool { replaced.isEmpty }

    /// Replaces each track at its path with the edited copy. Validates every
    /// path before changing anything.
    mutating func commit(_ edits: [(path: JSONPath, new: JSONObject)], in project: Project) throws {
        var olds: [JSONObject] = []
        for e in edits {
            guard let o = e.path.resolve(in: project.root)?.object else {
                throw EditError.invalid("track not found")
            }
            olds.append(o)
        }
        for e in edits { try e.path.replace(in: project.root, with: .object(e.new)) }
        replaced = zip(edits, olds).map { ($0.path, $1) }
    }

    mutating func restore(in project: Project) throws {
        guard !replaced.isEmpty else { throw EditError.invalid("nothing to revert") }
        for r in replaced.reversed() { try r.path.replace(in: project.root, with: .object(r.old)) }
        replaced = []
    }
}
