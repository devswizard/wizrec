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
}
