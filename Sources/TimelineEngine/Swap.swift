import Foundation
import TSCProjKit

// MARK: - Replacing values anywhere in the tree

/// Remembers values an `apply` replaced (at paths ending in an object key or
/// an array index) so `revert` can put the originals back. Like `TrackSwap`,
/// the originals are detached and never mutated, so a revert reproduces the
/// prior JSON byte for byte. A key that was missing before is removed again.
struct ValueSwap {
    private var replaced: [(path: JSONPath, old: JSON?)] = []

    var isEmpty: Bool { replaced.isEmpty }

    /// Sets each path to its new value. Every parent must exist; validated
    /// before anything changes.
    mutating func commit(_ edits: [(path: JSONPath, new: JSON)], in project: Project) throws {
        var olds: [JSON?] = []
        for e in edits {
            guard let last = e.path.steps.last,
                  let parent = JSONPath(steps: Array(e.path.steps.dropLast())).resolve(in: project.root)
            else { throw EditError.invalid("path not found") }
            switch last {
            case .key(let k):
                guard let o = parent.object else { throw EditError.invalid("path not found") }
                olds.append(o[k])
            case .index(let i):
                guard let a = parent.array, a.items.indices.contains(i) else { throw EditError.invalid("path not found") }
                olds.append(a[i])
            }
        }
        for e in edits { try Self.set(e.path, e.new, in: project) }
        replaced = zip(edits, olds).map { ($0.path, $1) }
    }

    mutating func restore(in project: Project) throws {
        guard !replaced.isEmpty else { throw EditError.invalid("nothing to revert") }
        for r in replaced.reversed() { try Self.set(r.path, r.old, in: project) }
        replaced = []
    }

    private static func set(_ path: JSONPath, _ value: JSON?, in project: Project) throws {
        guard let last = path.steps.last,
              let parent = JSONPath(steps: Array(path.steps.dropLast())).resolve(in: project.root)
        else { throw EditError.invalid("path not found") }
        switch last {
        case .key(let k):
            guard let o = parent.object else { throw EditError.invalid("path not found") }
            o[k] = value
        case .index(let i):
            guard let a = parent.array, a.items.indices.contains(i), let value else {
                throw EditError.invalid("path not found")
            }
            a[i] = value
        }
    }
}

// MARK: - Editing several tracks at once

/// Collects edits to tracks (top level or inside groups) on deep copies of
/// the top-level tracks that contain them, then swaps those copies in with
/// one `TrackSwap`. Paths are resolved against the *unedited* tree, so when
/// one edit changes indices on an ancestor track, edit the deepest tracks
/// first.
struct TrackEdits {
    let project: Project
    private var tops: [Int: JSONObject] = [:]
    private var order: [Int] = []

    init(_ project: Project) { self.project = project }

    private static let prefix = JSONPath.sceneTracks.steps.count

    /// The editable copy of the track at `path` (an element of some `tracks` array).
    mutating func track(at path: JSONPath) throws -> JSONObject {
        guard path.steps.count > Self.prefix, Array(path.steps.prefix(Self.prefix)) == JSONPath.sceneTracks.steps,
              case .index(let top) = path.steps[Self.prefix]
        else { throw EditError.invalid("not a track path") }
        let root: JSONObject
        if let t = tops[top] {
            root = t
        } else {
            guard let o = JSONPath.sceneTracks.appending(.index(top)).resolve(in: project.root)?.object else {
                throw EditError.trackNotFound(top)
            }
            root = o.copy()
            tops[top] = root
            order.append(top)
        }
        let rest = JSONPath(steps: Array(path.steps.dropFirst(Self.prefix + 1)))
        guard let o = rest.resolve(in: root)?.object else { throw EditError.invalid("track not found") }
        return o
    }

    /// The editable copy of top-level track `index`.
    mutating func topTrack(_ index: Int) throws -> JSONObject {
        try track(at: JSONPath.sceneTracks.appending(.index(index)))
    }

    var isEmpty: Bool { tops.isEmpty }

    func commit(_ swap: inout TrackSwap) throws {
        try swap.commit(order.compactMap { i in tops[i].map { (JSONPath.sceneTracks.appending(.index(i)), $0) } },
                        in: project)
    }
}

extension ClipLocation {
    /// Path of the clip object itself.
    var clipPath: JSONPath { trackPath.appending(.key("medias"), .index(index)) }
    /// Nesting depth of the clip's track (0 = top level).
    var depth: Int { trackPath.steps.count }
}

extension JSONPath {
    func hasPrefix(_ p: JSONPath) -> Bool {
        steps.count >= p.steps.count && Array(steps.prefix(p.steps.count)) == p.steps
    }
}

// MARK: - JSON building

enum J {
    static func int(_ v: Int64) -> JSON { .number(JSONNumber(v)) }
    static func int(_ v: Int) -> JSON { .number(JSONNumber(v)) }
    static func dbl(_ v: Double) -> JSON { .number(JSONNumber(v)) }
    static func arr(_ v: [JSON]) -> JSON { .array(JSONArray(v)) }
    static func obj(_ pairs: [(String, JSON)]) -> JSON { .object(JSONObject(pairs)) }
    static var emptyObject: JSON { .object(JSONObject()) }
    static var emptyArray: JSON { .array(JSONArray()) }
    /// `{"type": "bool", "value": v}` (clip metadata style).
    static func typedBool(_ v: Bool) -> JSON { obj([("type", .string("bool")), ("value", .bool(v))]) }
    /// v10 animatable parameter with a constant value.
    static func param(_ v: Double, interp: String = "eioe") -> JSON {
        obj([("type", .string("double")), ("defaultValue", dbl(v)), ("interp", .string(interp))])
    }
}

/// `yyyyMMdd'T'HHmmss` (UTC), as `lastMod`; with `.SSSSSS` as `timeAdded` [obs].
enum Stamp {
    static func string(_ date: Date, micro: Bool) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let micros = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
        let secs = micros >= 0 ? micros / 1_000_000 : (micros - 999_999) / 1_000_000
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                   from: Date(timeIntervalSince1970: TimeInterval(secs)))
        func p(_ v: Int64, _ n: Int) -> String {
            let s = String(v); return String(repeating: "0", count: max(0, n - s.count)) + s
        }
        func q(_ v: Int?, _ n: Int) -> String { p(Int64(v ?? 0), n) }
        var s = q(c.year, 4) + q(c.month, 2) + q(c.day, 2) + "T" + q(c.hour, 2) + q(c.minute, 2) + q(c.second, 2)
        if micro { s += "." + p(micros - secs * 1_000_000, 6) }
        return s
    }
}
