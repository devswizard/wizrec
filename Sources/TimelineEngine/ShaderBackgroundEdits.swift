import Foundation
import TSCProjKit

// Editing shader backgrounds on the timeline (`docs/specs/shader-backgrounds.md` §1, §6):
// the clip's `sourceEffect` parameters, and the metadata that records where a background
// was placed from (`ShaderVidSource` on the clip, `RevBackground` on a Rev group).

/// One assignment to a shader clip's `sourceEffect` parameter.
///
/// `name` is the clip-side key: `<Color>-red|-green|-blue|-alpha` (0–1), `<Position>.x|.y`
/// (pixels of the 1920×1080 frame) or a double's own name (the file's units; radians for
/// angles). `keyframeAt` is clip media time in ticks for a keyframe, nil for a constant.
public struct SourceEffectChange: Sendable, Equatable {
    public var name: String
    public var value: Double
    public var keyframeAt: Int64?
    public init(_ name: String, _ value: Double, keyframeAt: Int64? = nil) {
        self.name = name; self.value = value; self.keyframeAt = keyframeAt
    }
}

/// Sets parameters of a shader background clip's `sourceEffect` as one undo step: each a
/// constant, or a keyframe at clip media time `keyframeAt` (the `SetParameter` keyframe rule;
/// new keyframes take the parameter's `interp`, `linr` for these [obs]).
///
/// Rules:
/// - The clip (top level or nested) must have a `sourceEffect`, or play a `.tscshadervid`
///   source with an `effectDef`; then the `sourceEffect` is first created at the defaults, as
///   `InsertClip` would [inf].
/// - A parameter missing from `sourceEffect.parameters` is added at the end as
///   `{type: "double", defaultValue: <effectDef default>, interp: "linr"}` [obs form, §6]
///   before the change; with no `effectDef` entry its default is the new value [inf].
/// - Bare-number parameters stay bare; string parameters (`sourceFileType`) are rejected.
/// - `animationTracks` is not changed: whether Camtasia lists `sourceEffect` keyframe windows
///   there is unknown [?] (QUESTION to main, 2026-10-20).
@MainActor public final class SetSourceEffectParameters: EditCommand {
    public let name = "Change Background"
    public let clipID: Int64
    public let changes: [SourceEffectChange]
    private var swap = TrackSwap()

    public init(clipID: Int64, changes: [SourceEffectChange]) {
        self.clipID = clipID; self.changes = changes
    }

    public func apply(to project: Project) throws {
        guard !changes.isEmpty else { throw EditError.invalid("no parameter changes") }
        for c in changes where c.name.isEmpty || !c.value.isFinite {
            throw EditError.invalid("bad background parameter \(c.name)")
        }
        let grid = FrameGrid(project)
        try Effects.editClip(project, clipID, &swap) { clip in
            let params = try ShaderBackground.sourceEffectParameters(clip, project)
            let visible = Exact.floor(Rational(clip["mediaStart"]) ?? Rational(0))
            for c in changes {
                if params[c.name] == nil {
                    let base = ShaderBackground.effectDefDefault(c.name, clip: clip, project) ?? c.value
                    params[c.name] = J.param(base, interp: "linr")
                } else if params[c.name]?.string != nil {
                    throw EditError.invalid("\(c.name) is not a number")
                }
                if let at = c.keyframeAt {
                    let m = grid.nearest(at)
                    guard m >= 0 else { throw EditError.invalid("keyframe time must be ≥ 0") }
                    if params[c.name]?.number != nil {
                        // A bare number becomes an animatable object to hold keyframes.
                        params[c.name] = J.param(params[c.name]?.double ?? c.value, interp: "linr")
                    }
                    ParamWriter.setKeyframe(params, c.name, c.value, at: m, visibleStart: visible)
                } else {
                    ParamWriter.setConstant(params, c.name, c.value)
                }
            }
        }
    }

    public func revert(on project: Project) throws { try swap.restore(in: project) }
}

/// Records which library file a shader background clip was placed from
/// (`docs/specs/shader-backgrounds.md` §1 [obs, demo project]):
///
/// - the clip's `metadata.ShaderVidSource` = `path`, the absolute path of the library
///   `.tscshadervid` the bundle copy came from;
/// - when the clip sits on inner track 0 of a Rev group (`metadata.groupType` `"revMedia"`),
///   that group's `metadata.RevBackground` = `revBackground`, the file named relative to the
///   library root (`backgrounds/<file>`). Other groups and top-level clips get no
///   `RevBackground` [obs: only the one Rev group of the 13 groups on disk has Rev keys; the
///   track-0 condition is [WizRec], from the demo's layout].
///
/// Metadata keys are inserted in sorted (byte) order, as Camtasia writes them [obs]; an
/// existing key keeps its position and gets the new value. A clip without `metadata` gets one
/// before `animationTracks` [inf].
///
/// Timeline rules [WizRec unless tagged; Camtasia's are unknown]: both keys are plain metadata,
/// so `ShaderVidSource` travels with the clip (split halves, copies and moves keep it,
/// ungrouping keeps it on the clip) and `RevBackground` stays with its group (deleting or
/// moving the background clip leaves it as it is; ungrouping drops it with the group).
/// Media-bin imports and drops write neither [obs: Camtasia-imported backgrounds have none].
@MainActor public final class SetShaderVidSource: EditCommand {
    public let name = "Add Background"
    public let clipID: Int64
    public let path: String
    public let revBackground: String?
    private var swap = TrackSwap()

    public init(clipID: Int64, path: String, revBackground: String? = nil) {
        self.clipID = clipID; self.path = path; self.revBackground = revBackground
    }

    public func apply(to project: Project) throws {
        guard !path.isEmpty else { throw EditError.invalid("empty background path") }
        let loc = try Locator.locate(clipID, in: project)
        var edits = TrackEdits(project)
        let track = try edits.track(at: loc.trackPath)
        guard let clip = track["medias"]?.array?[loc.index].object else { throw EditError.clipNotFound(clipID) }
        guard ShaderBackground.isShaderClip(clip, project) else {
            throw EditError.invalid("clip \(clipID) is not a shader background")
        }
        ShaderBackground.setMetadata(clip, "ShaderVidSource", .string(path))
        if let rev = revBackground, !rev.isEmpty, let group = try ShaderBackground.revGroup(of: loc, &edits) {
            ShaderBackground.setMetadata(group, "RevBackground", .string(rev))
        }
        try edits.commit(&swap)
    }

    public func revert(on project: Project) throws { try swap.restore(in: project) }
}

@MainActor
enum ShaderBackground {
    /// The source entry a clip plays, if any.
    static func source(of clip: JSONObject, _ project: Project) -> JSONObject? {
        guard let src = clip["src"]?.int else { return nil }
        return project.root["sourceBin"]?.array?.items.lazy.compactMap(\.object).first { $0["id"]?.int == src }
    }

    /// A `VMFile` with a `sourceEffect`, or playing a `.tscshadervid` source.
    static func isShaderClip(_ clip: JSONObject, _ project: Project) -> Bool {
        if clip["sourceEffect"]?.object != nil { return true }
        return source(of: clip, project)?["src"]?.string?.lowercased().hasSuffix(".tscshadervid") == true
    }

    /// The clip's `sourceEffect.parameters`, creating the `sourceEffect` from the source's
    /// `effectDef` (after `parameters`) when it is missing.
    static func sourceEffectParameters(_ clip: JSONObject, _ project: Project) throws -> JSONObject {
        if let se = clip["sourceEffect"]?.object {
            if se["parameters"]?.object == nil { se["parameters"] = J.emptyObject }
            if let p = se["parameters"]?.object { return p }
        }
        guard let source = source(of: clip, project), let made = ShaderSource.sourceEffect(for: source) else {
            throw EditError.invalid("clip \(clip.clipID ?? -1) has no background parameters")
        }
        var pairs = clip.entries.map { ($0.key, $0.value) }
        let at = (pairs.firstIndex { $0.0 == "parameters" }).map { $0 + 1 } ?? pairs.count
        pairs.insert(("sourceEffect", made), at: at)
        let rebuilt = JSONObject(pairs)
        for k in clip.keys { clip[k] = nil }
        for (k, v) in rebuilt.entries { clip[k] = v }
        guard let p = clip["sourceEffect"]?.object?["parameters"]?.object else {
            throw EditError.invalid("no background parameters")
        }
        return p
    }

    /// The `effectDef` default of clip-side parameter `name` (`Color0-green` → green of
    /// `Color0`, `Pos.y` → y of `Pos`, a double → its own default).
    static func effectDefDefault(_ name: String, clip: JSONObject, _ project: Project) -> Double? {
        let entries = source(of: clip, project)?["effectDef"]?.array?.items.compactMap(\.object) ?? []
        func entry(_ n: String) -> JSONObject? { entries.first { $0["name"]?.string == n } }
        let channels = ["-red": 0, "-green": 1, "-blue": 2, "-alpha": 3]
        for (suffix, i) in channels where name.hasSuffix(suffix) {
            let base = String(name.dropLast(suffix.count))
            if let e = entry(base), e["type"]?.string == "Color" {
                let v = e["defaultValue"]?.array?.items ?? []
                return v.indices.contains(i) ? v[i].double : (i == 3 ? 1 : 0)
            }
        }
        for (suffix, i) in [(".x", 0), (".y", 1)] where name.hasSuffix(suffix) {
            let base = String(name.dropLast(suffix.count))
            if let e = entry(base), e["type"]?.string == "Position" {
                let v = e["defaultValue"]?.array?.items ?? []
                return v.indices.contains(i) ? v[i].double : 0
            }
        }
        return entry(name)?["defaultValue"]?.double
    }

    /// The Rev group holding the clip at `loc` on its inner track 0 (editable copy), or nil.
    static func revGroup(of loc: ClipLocation, _ edits: inout TrackEdits) throws -> JSONObject? {
        let s = loc.trackPath.steps
        guard s.count >= 4, case .index(let inner) = s[s.count - 1], inner == 0, s[s.count - 2] == .key("tracks"),
              case .index(let mi) = s[s.count - 3], s[s.count - 4] == .key("medias") else { return nil }
        let holder = JSONPath(steps: Array(s.dropLast(4)))
        let parent = try edits.track(at: holder)
        guard let g = parent["medias"]?.array?[mi].object, g.clipType == "Group",
              g["metadata"]?.object?["groupType"]?.string == "revMedia" else { return nil }
        return g
    }

    /// Sets `metadata[key]` on `owner`, inserting a new key in sorted byte order.
    static func setMetadata(_ owner: JSONObject, _ key: String, _ value: JSON) {
        guard let md = owner["metadata"]?.object else {
            var pairs = owner.entries.map { ($0.key, $0.value) }
            let at = pairs.firstIndex { $0.0 == "animationTracks" } ?? pairs.count
            pairs.insert(("metadata", J.obj([(key, value)])), at: at)
            let rebuilt = JSONObject(pairs)
            for k in owner.keys { owner[k] = nil }
            for (k, v) in rebuilt.entries { owner[k] = v }
            return
        }
        if md[key] != nil { md[key] = value; return }
        var pairs = md.entries.map { ($0.key, $0.value) }
        let at = pairs.firstIndex { Array(key.utf8).lexicographicallyPrecedes(Array($0.0.utf8)) } ?? pairs.count
        pairs.insert((key, value), at: at)
        let rebuilt = JSONObject(pairs)
        for k in md.keys { md[k] = nil }
        for (k, v) in rebuilt.entries { md[k] = v }
    }
}
