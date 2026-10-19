import Foundation
import TSCProjKit
import TimelineEngine

/// A path from `Project.root` through object keys and array indices.
struct TreePath: Equatable {
    enum Step: Equatable { case key(String), index(Int) }
    var steps: [Step]

    static let sourceBin = TreePath(steps: [.key("sourceBin")])
    static let sceneTracks = TreePath(steps: [
        .key("timeline"), .key("sceneTrack"), .key("scenes"), .index(0), .key("csml"), .key("tracks"),
    ])

    func appending(_ s: Step...) -> TreePath { TreePath(steps: steps + s) }
    var parent: TreePath { TreePath(steps: Array(steps.dropLast())) }

    func resolve(in root: JSONObject) -> JSON? {
        var cur = JSON.object(root)
        for s in steps {
            switch s {
            case .key(let k): guard let n = cur.object?[k] else { return nil }; cur = n
            case .index(let i): guard let a = cur.array, a.items.indices.contains(i) else { return nil }; cur = a[i]
            }
        }
        return cur
    }
}

/// Replaces values at paths and puts the detached originals back on revert, so a revert
/// reproduces the prior JSON byte for byte. A key that was missing before is removed again.
/// New values must be freshly built (or deep copies): they are inserted as is.
struct Swap {
    private var replaced: [(path: TreePath, old: JSON?)] = []

    var isEmpty: Bool { replaced.isEmpty }

    /// Validates every parent first, then sets all values (in order).
    mutating func commit(_ edits: [(path: TreePath, new: JSON)], in project: Project) throws {
        guard replaced.isEmpty else { throw EditError.invalid("command already applied") }
        var olds: [JSON?] = []
        for e in edits { olds.append(try Self.current(e.path, in: project)) }
        for e in edits { try Self.set(e.path, e.new, in: project) }
        replaced = zip(edits, olds).map { ($0.path, $1) }
    }

    mutating func restore(in project: Project) throws {
        guard !replaced.isEmpty else { throw EditError.invalid("nothing to revert") }
        for r in replaced.reversed() { try Self.set(r.path, r.old, in: project) }
        replaced = []
    }

    private static func current(_ path: TreePath, in project: Project) throws -> JSON? {
        guard let last = path.steps.last, let parent = path.parent.resolve(in: project.root) else {
            throw EditError.invalid("path not found")
        }
        switch last {
        case .key(let k):
            guard let o = parent.object else { throw EditError.invalid("path not found") }
            return o[k]
        case .index(let i):
            guard let a = parent.array, a.items.indices.contains(i) else { throw EditError.invalid("path not found") }
            return a[i]
        }
    }

    private static func set(_ path: TreePath, _ value: JSON?, in project: Project) throws {
        guard let last = path.steps.last, let parent = path.parent.resolve(in: project.root) else {
            throw EditError.invalid("path not found")
        }
        switch last {
        case .key(let k):
            guard let o = parent.object else { throw EditError.invalid("path not found") }
            o[k] = value
        case .index(let i):
            guard let a = parent.array, a.items.indices.contains(i), let value else { throw EditError.invalid("path not found") }
            a[i] = value
        }
    }
}

/// JSON building shorthands.
enum J {
    static func int(_ v: Int64) -> JSON { .number(JSONNumber(v)) }
    static func dbl(_ v: Double) -> JSON { .number(JSONNumber(v)) }
    static func str(_ v: String) -> JSON { .string(v) }
    static func arr(_ v: [JSON]) -> JSON { .array(JSONArray(v)) }
    static func obj(_ pairs: [(String, JSON)]) -> JSON { .object(JSONObject(pairs)) }
    /// `{"type": "bool", "value": v}` (clip metadata style).
    static func typedBool(_ v: Bool) -> JSON { obj([("type", .string("bool")), ("value", .bool(v))]) }
}

/// A copy of `o` with `key` set to `value`; a new key is inserted before `before` when that key
/// exists (else appended). Existing keys keep their position.
func withKey(_ o: JSONObject, setting key: String, to value: JSON, before: String? = nil) -> JSONObject {
    if o[key] != nil || before.map({ o[$0] == nil }) ?? true {
        let c = o.copy(); c[key] = value; return c
    }
    var pairs: [(String, JSON)] = []
    for (k, v) in o.entries {
        if k == before { pairs.append((key, value)) }
        pairs.append((k, v.copy()))
    }
    return JSONObject(pairs)
}

/// Clips on the top-level tracks with their paths.
struct TopClip {
    let path: TreePath
    let track: Int
    let object: JSONObject
    var clip: Clip { Clip(object) }
}

@MainActor
enum Tree {
    static func topTracks(_ project: Project) -> [(path: TreePath, track: JSONObject)] {
        guard let a = TreePath.sceneTracks.resolve(in: project.root)?.array else { return [] }
        return a.items.enumerated().compactMap { i, v in v.object.map { (TreePath.sceneTracks.appending(.index(i)), $0) } }
    }

    static func topClips(_ project: Project) -> [TopClip] {
        topTracks(project).enumerated().flatMap { ti, t in
            (t.track["medias"]?.array?.items ?? []).enumerated().compactMap { i, v in
                v.object.map { TopClip(path: t.path.appending(.key("medias"), .index(i)), track: ti, object: $0) }
            }
        }
    }

    /// Index of the `sourceBin` entry with `id`.
    static func sourceIndex(_ project: Project, id: Int64) -> Int? {
        project.root["sourceBin"]?.array?.items.firstIndex { $0.object?["id"]?.int == id }
    }

    /// Ticks per output frame when that is an integer (`editRate / videoFormatFrameRate`), else nil.
    static func frameTicks(_ project: Project) -> Int64? {
        let fps = project.frameRate
        guard fps.num > 0 else { return nil }
        let (q, r) = (project.timebase.editRate * fps.den).quotientAndRemainder(dividingBy: fps.num)
        return r == 0 && q > 0 ? q : nil
    }

    /// Seconds → ticks, rounded to the nearest output frame when frames are whole ticks.
    static func ticks(_ seconds: Double, _ project: Project) -> Int64 {
        let t = project.timebase.ticks(seconds: max(0, seconds))
        guard let f = frameTicks(project) else { return t }
        return Int64((Double(t) / Double(f)).rounded()) * f
    }
}
