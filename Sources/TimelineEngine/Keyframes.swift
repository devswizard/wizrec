import Foundation
import TSCProjKit

/// Writing constant and keyframed parameter values.
///
/// Rules (time-mapping.md §6 and the observed key shapes):
/// - A parameter is either a bare number (`"scale0": 0.71`, groups, stitched
///   clips, older files) or an object `{type, defaultValue, interp?, keyframes?}`.
///   A missing parameter is created in the style the clip already uses: bare
///   when every existing entry is bare, otherwise a v10 object.
/// - Keyframe key order: `endTime, time, value, interp, duration` [obs].
/// - A keyframe animates from the previous value to `value` across
///   `[time, endTime]`. Adding a keyframe "at" media time `m` (a point in the
///   inspector) writes `endTime = m` and `time` = the previous keyframe's
///   `endTime`, or the clip's first visible media time when it is the first
///   one — so the value eases from the previous point to the new one [inf,
///   our choice]. A later keyframe whose window started before `m` now starts
///   at `m`. A keyframe that already ends at `m` just gets the new value.
/// - Constant writes drop `keyframes` and keep `interp` and the key position.
enum ParamWriter {
    /// Camtasia default for a missing parameter (defaults.md).
    static func defaultValue(_ name: String) -> Double {
        switch name {
        case "scale0", "scale1", "scale2", "opacity", "volume": 1
        default: 0
        }
    }

    static func usesBareStyle(_ params: JSONObject) -> Bool {
        !params.entries.isEmpty && params.entries.allSatisfy { $0.value.number != nil }
    }

    static func setConstant(_ params: JSONObject, _ name: String, _ value: Double) {
        let v = JSON.number(JSONNumber(value))
        if let o = params[name]?.object {
            o["defaultValue"] = v
            o["keyframes"] = nil
        } else if params[name] != nil || usesBareStyle(params) {
            params[name] = v
        } else {
            params[name] = J.param(value)
        }
    }

    /// Adds or updates a keyframe ending at media time `m`. `visibleStart` is
    /// the media time shown at the clip's left edge.
    static func setKeyframe(_ params: JSONObject, _ name: String, _ value: Double, at m: Int64,
                            visibleStart: Int64) {
        let o: JSONObject
        if let existing = params[name]?.object {
            o = existing
        } else {
            let base = params[name]?.double ?? defaultValue(name)
            o = JSONObject([("type", .string("double")), ("defaultValue", J.dbl(base)), ("interp", .string("eioe"))])
            params[name] = .object(o)
        }
        if o["keyframes"]?.array == nil { o["keyframes"] = J.emptyArray }
        guard let kfs = o["keyframes"]?.array else { return }
        let interp = o["interp"]?.string ?? "eioe"
        let objs = kfs.items.compactMap(\.object)
        func end(_ k: JSONObject) -> Int64 { k["endTime"]?.int ?? k["time"]?.int ?? 0 }

        if let same = objs.first(where: { end($0) == m }) {
            same["value"] = J.dbl(value)
            return
        }
        let prev = objs.filter { end($0) < m }.max { end($0) < end($1) }
        let next = objs.filter { end($0) > m }.min { end($0) < end($1) }
        let time = prev.map(end) ?? min(visibleStart, m)
        if let next, (next["time"]?.int ?? 0) < m {
            next["time"] = J.int(m)
            next["duration"] = J.int(end(next) - m)
        }
        let kf = JSONObject([
            ("endTime", J.int(m)), ("time", J.int(time)), ("value", J.dbl(value)),
            ("interp", .string(interp)), ("duration", J.int(m - time)),
        ])
        let at = kfs.items.firstIndex { ($0.object.map(end) ?? 0) > m } ?? kfs.count
        kfs.items.insert(.object(kf), at: at)
    }
}

/// Keeps `animationTracks.visual` in step with the numeric keyframe windows
/// of a clip's parameters and its effects' parameters (time-mapping.md §6:
/// every window equals one entry). Entries still in use are kept as they are;
/// unused ones are removed; missing ones are added in time order. Windows of
/// zero length get no entry [inf]. The key is left untouched when nothing
/// changes.
enum AnimationSync {
    struct Window: Hashable { var time: Int64; var endTime: Int64 }

    static func windows(_ clip: JSONObject) -> [Window: String] {
        var out: [Window: String] = [:]
        func scan(_ params: JSONObject?) {
            for (_, v) in params?.entries ?? [] {
                guard let o = v.object else { continue }
                for k in o["keyframes"]?.array?.items.compactMap(\.object) ?? [] where k["value"]?.number != nil {
                    let t = k["time"]?.int ?? 0, e = k["endTime"]?.int ?? t
                    guard e > t else { continue }
                    let w = Window(time: t, endTime: e)
                    if out[w] == nil { out[w] = k["interp"]?.string ?? o["interp"]?.string ?? "eioe" }
                }
            }
        }
        scan(clip["parameters"]?.object)
        for e in clip["effects"]?.array?.items.compactMap(\.object) ?? [] { scan(e["parameters"]?.object) }
        return out
    }

    static func sync(_ clip: JSONObject) {
        let want = windows(clip)
        let existing = clip["animationTracks"]?.object?["visual"]?.array?.items ?? []
        func window(_ v: JSON) -> Window? {
            guard let o = v.object, let r = o["range"]?.array, r.count == 2, let s = r[0].int, let d = r[1].int
            else { return nil }
            return Window(time: s, endTime: s + d)
        }
        var kept: [JSON] = []
        var have = Set<Window>()
        for e in existing {
            guard let w = window(e), want[w] != nil, !have.contains(w) else { continue }
            kept.append(e); have.insert(w)
        }
        let added = want.keys.filter { !have.contains($0) }.sorted { ($0.time, $0.endTime) < ($1.time, $1.endTime) }
        if added.isEmpty && kept.count == existing.count { return }
        var all = kept
        for w in added {
            let entry = J.obj([
                ("endTime", J.int(w.endTime)), ("duration", J.int(w.endTime - w.time)),
                ("range", J.arr([J.int(w.time), J.int(w.endTime - w.time)])), ("interp", .string(want[w] ?? "eioe")),
            ])
            let at = all.firstIndex { (window($0)?.time ?? 0, window($0)?.endTime ?? 0) > (w.time, w.endTime) } ?? all.count
            all.insert(entry, at: at)
        }
        let tracks: JSONObject
        if let t = clip["animationTracks"]?.object { tracks = t } else {
            tracks = JSONObject(); clip["animationTracks"] = .object(tracks)
        }
        tracks["visual"] = all.isEmpty ? nil : J.arr(all)
    }
}
