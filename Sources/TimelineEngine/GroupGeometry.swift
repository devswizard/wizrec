import Foundation
import TSCProjKit

/// Canvas geometry used by group create / ungroup (group-edits.md §1, §6;
/// transform.md §2–3, §8).
///
/// Positions are `translation0/1` in canvas px from the canvas (or group)
/// centre, +y up; sizes are natural layer px times `scale0/1`.
@MainActor
enum GroupGeometry {
    /// The object holding a clip's transform keys: the `video` child of a
    /// `UnifiedMedia`, otherwise the clip itself (transform.md §2).
    static func owner(_ clip: JSONObject) -> JSONObject? {
        clip.clipType == "UnifiedMedia" ? clip["video"]?.object : clip
    }

    /// Natural layer size (px) before scale; nil for audio or unknown media.
    static func naturalSize(_ clip: JSONObject, _ project: Project) -> (w: Double, h: Double)? {
        switch clip.clipType {
        case "UnifiedMedia":
            return clip["video"]?.object.flatMap { naturalSize($0, project) }
        case "StitchedMedia":
            for s in clip["medias"]?.array?.items.compactMap(\.object) ?? [] {
                if let sz = naturalSize(s, project) { return sz }
            }
            return nil
        case "Group":
            let a = clip["attributes"]?.object
            return (a?["widthAttr"]?.double ?? project.width, a?["heightAttr"]?.double ?? project.height)
        case "Callout":
            guard let d = clip["def"]?.object, let w = d["width"]?.double, let h = d["height"]?.double else { return nil }
            return (w, h)
        case "VMFile", "ScreenVMFile", "IMFile":
            guard let src = clip["src"]?.int, let source = project.source(id: src) else { return nil }
            let n = Int(clip["trackNumber"]?.int ?? 0)
            let tracks = source.tracks
            if tracks.indices.contains(n),
               let r = tracks[n].object["trackRect"]?.array?.items.compactMap(\.double), r.count == 4, r[2] > 0, r[3] > 0 {
                return (r[2], r[3])
            }
            let r = source.rect
            return r.count == 4 && r[2] > 0 && r[3] > 0 ? (r[2], r[3]) : nil
        default:
            return nil
        }
    }

    /// Constant value of a parameter (bare number or `defaultValue` of the
    /// long form); `fallback` when missing.
    static func constant(_ params: JSONObject?, _ name: String, _ fallback: Double) -> Double {
        params.flatMap { $0[name] }.flatMap { Parameter($0).defaultValue?.double } ?? fallback
    }

    /// True when the parameter has keyframes.
    static func isAnimated(_ params: JSONObject?, _ name: String) -> Bool {
        params.flatMap { $0[name] }.map { Parameter($0).isAnimated } ?? false
    }

    /// On-canvas rectangle (centre, half size) of a clip at its constant
    /// transform; rotation and crop are ignored ([?] group-edits.md §1).
    static func rect(_ clip: JSONObject, _ project: Project) -> (minX: Double, maxX: Double, minY: Double, maxY: Double)? {
        guard let size = naturalSize(clip, project), let o = owner(clip) else { return nil }
        let p = o["parameters"]?.object
        let w = size.w * abs(constant(p, "scale0", 1)) / 2, h = size.h * abs(constant(p, "scale1", 1)) / 2
        let x = constant(p, "translation0", 0), y = constant(p, "translation1", 0)
        return (x - w, x + w, y - h, y + h)
    }

    /// Transform keys in Camtasia's canonical parameter order [obs for
    /// translation0 before scale; the rest inf, group-edits.md §1a].
    static let canonical = ["translation0", "translation1", "translation2", "rotation0", "rotation1", "rotation2",
                            "scale0", "scale1", "scale2"]

    /// Inserts a new key in canonical position: before the first existing
    /// key that is not a transform key or ranks later. Existing keys keep
    /// their order.
    static func insert(_ params: JSONObject, _ name: String, _ value: JSON) {
        let rank = canonical.firstIndex(of: name) ?? canonical.count
        let entries = params.entries
        let at = entries.firstIndex { e in (canonical.firstIndex(of: e.key) ?? canonical.count) > rank } ?? entries.count
        guard at < entries.count else { params[name] = value; return }
        for e in entries[at...] { params[e.key] = nil }
        params[name] = value
        for e in entries[at...] { params[e.key] = e.value }
    }

    /// Rewrites every numeric value of `name` (constant/`defaultValue` and
    /// keyframe values) with `f`, keeping the parameter's form. A missing
    /// parameter is created from `f(default)` as a bare number in canonical
    /// position (`insert`) [obs], unless that equals the default. Each new
    /// value is a double.
    static func map(_ params: JSONObject, _ name: String, _ f: (Double) -> Double) {
        let d = ParamWriter.defaultValue(name)
        guard let v = params[name] else {
            let nv = f(d)
            if nv != d { insert(params, name, J.dbl(nv)) }
            return
        }
        if let o = v.object {
            if let dv = o["defaultValue"]?.double { o["defaultValue"] = J.dbl(f(dv)) }
            for k in o["keyframes"]?.array?.items.compactMap(\.object) ?? [] {
                if let kv = k["value"]?.double { k["value"] = J.dbl(f(kv)) }
            }
        } else if let n = v.double {
            params[name] = J.dbl(f(n))
        }
    }

    /// Parameters dict of `o`, created (empty) when missing.
    static func params(_ o: JSONObject) -> JSONObject {
        if let p = o["parameters"]?.object { return p }
        let p = JSONObject()
        o["parameters"] = .object(p)
        return p
    }

    /// Moves a clip's transform by `t' = a + b × t`, `s' = b × s` per axis (x: `translation0`/
    /// `scale0`, y: `translation1`/`scale1`), keyframe values too. Changed keys are written in the
    /// long form (`{type, defaultValue, interp}`), as Camtasia writes pasted parameters [obs,
    /// group-edits.md §3, §8.2]; a missing key is added (long form, canonical position) only when
    /// its value changes. Audio clips (`AMFile`) are left alone. No-op for the identity.
    static func reexpress(_ clip: JSONObject, x: GroupSpace.Axis, y: GroupSpace.Axis) {
        guard clip.clipType != "AMFile", let o = owner(clip) else { return }
        let ops: [(name: String, f: (Double) -> Double, active: Bool)] = [
            ("translation0", { (v: Double) -> Double in x.a + x.b * v }, x.a != 0 || x.b != 1),
            ("translation1", { (v: Double) -> Double in y.a + y.b * v }, y.a != 0 || y.b != 1),
            ("scale0", { (v: Double) -> Double in x.b * v }, x.b != 1),
            ("scale1", { (v: Double) -> Double in y.b * v }, y.b != 1),
        ]
        guard ops.contains(where: { $0.active }) else { return }
        let p = params(o)
        for op in ops where op.active { mapLong(p, op.name, op.f) }
    }

    /// `map`, writing the long form: a bare number becomes `{type: "double", defaultValue,
    /// interp: "eioe"}` in place; a missing key is inserted in that form when `f` changes the
    /// default.
    static func mapLong(_ params: JSONObject, _ name: String, _ f: (Double) -> Double) {
        let d = ParamWriter.defaultValue(name)
        guard let v = params[name] else {
            let nv = f(d)
            if nv != d { insert(params, name, J.param(nv)) }
            return
        }
        if v.object == nil, let n = v.double {
            params[name] = J.param(f(n))
        } else {
            map(params, name, f)
        }
    }
}

/// The constant position/scale a stack of groups applies to the clips inside them
/// (group-edits.md §6, §8.2): `canvas = t + s × local` per axis, `t` in canvas px, `s` a
/// factor. Rotation is not composed [?]; an animated group position or scale counts with its
/// constant (`defaultValue`) [WizRec].
struct GroupSpace: Equatable {
    /// `v' = a + b × v` on one axis.
    typealias Axis = (a: Double, b: Double)

    var tx = 0.0, ty = 0.0, sx = 1.0, sy = 1.0

    static let identity = GroupSpace()

    var isIdentity: Bool { self == .identity }

    init(tx: Double = 0, ty: Double = 0, sx: Double = 1, sy: Double = 1) {
        self.tx = tx; self.ty = ty; self.sx = sx; self.sy = sy
    }

    /// Reads `json` (`[tx, ty, sx, sy]`); nil when missing or malformed.
    init?(_ v: JSON?) {
        guard let a = v?.array?.items.compactMap(\.double), a.count == 4, a.allSatisfy(\.isFinite) else { return nil }
        self.init(tx: a[0], ty: a[1], sx: a[2], sy: a[3])
    }

    /// `[tx, ty, sx, sy]`, as stored in a clipboard payload.
    var json: JSON { J.arr([J.dbl(tx), J.dbl(ty), J.dbl(sx), J.dbl(sy)]) }

    /// This space followed by group `g` inside it.
    @MainActor func entering(_ g: JSONObject) -> GroupSpace {
        let p = g["parameters"]?.object
        let gtx = GroupGeometry.constant(p, "translation0", 0), gty = GroupGeometry.constant(p, "translation1", 0)
        let gsx = GroupGeometry.constant(p, "scale0", 1), gsy = GroupGeometry.constant(p, "scale1", 1)
        return GroupSpace(tx: tx + sx * gtx, ty: ty + sy * gty, sx: sx * gsx, sy: sy * gsy)
    }

    /// The space of clips inside `groups` (outermost first).
    @MainActor static func of(_ groups: [JSONObject]) -> GroupSpace {
        var s = GroupSpace.identity
        for g in groups { s = s.entering(g) }
        return s
    }

    /// The map that re-expresses a clip given in space `from` in this space:
    /// `local' = (from(local) − t) / s` per axis. Nil when this space has a zero scale.
    func relative(from: GroupSpace) -> (x: Axis, y: Axis)? {
        guard sx != 0, sy != 0 else { return nil }
        let x: Axis = ((from.tx - tx) / sx, from.sx / sx)
        let y: Axis = ((from.ty - ty) / sy, from.sy / sy)
        return (x, y)
    }
}
