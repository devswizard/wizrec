import Foundation
import TSCProjKit

/// Sendable copy of one numeric project parameter (constant or keyframed).
///
/// Same semantics as `TSCProjKit.Parameter.value(at:)`: each keyframe animates
/// from the previous value (the first from `defaultValue`) to its own `value`
/// across `[time, endTime]`; between keyframes the value holds. Times are ticks
/// on the clip's keyframe axis (`Conventions.keyframeTime`).
struct SParam: Sendable, Equatable {
    struct Key: Sendable, Equatable {
        var time: Double
        var endTime: Double
        var value: Double?
        var easeInOut: Bool
    }

    var base: Double?
    var keys: [Key]

    init(base: Double?, keys: [Key] = []) { self.base = base; self.keys = keys }

    /// Reads a parameter entry. Bools become 1/0; strings and vectors are dropped (nil).
    init?(_ raw: JSON) {
        func num(_ j: JSON?) -> Double? {
            switch j {
            case .number(let n)?: n.double
            case .bool(let b)?: b ? 1 : 0
            default: nil
            }
        }
        if let o = raw.object {
            let kfs = o["keyframes"]?.array?.items.compactMap(\.object) ?? []
            let paramInterp = o["interp"]?.string
            let keys = kfs.map { k -> Key in
                let t = k["time"]?.double ?? 0
                let interp = k["interp"]?.string ?? paramInterp ?? Conventions.defaultInterp
                return Key(time: t, endTime: k["endTime"]?.double ?? t, value: num(k["value"]),
                           easeInOut: interp == "eioe")
            }
            let base = num(o["defaultValue"])
            if base == nil && keys.allSatisfy({ $0.value == nil }) { return nil }
            self.init(base: base, keys: keys)
        } else {
            guard let v = num(raw) else { return nil }
            self.init(base: v)
        }
    }

    var isAnimated: Bool { !keys.isEmpty }

    /// Value at clip-relative `ticks`.
    func value(at ticks: Double) -> Double? {
        guard !keys.isEmpty else { return base }
        var current = base ?? keys[0].value ?? 0
        for k in keys {
            guard let target = k.value else { continue }
            if ticks < k.time { return current }
            if ticks >= k.endTime || k.endTime == k.time { current = target; continue }
            let t = (ticks - k.time) / (k.endTime - k.time)
            return current + (target - current) * Easing.apply(t, easeInOut: k.easeInOut)
        }
        return current
    }
}

/// Easing curves. `eioe` is approximated by smoothstep, matching TSCProjKit,
/// until `docs/specs/animation.md` gives the measured curve.
enum Easing {
    static func apply(_ t: Double, easeInOut: Bool) -> Double {
        easeInOut ? t * t * (3 - 2 * t) : t
    }
}

/// Sendable, ordered parameter dictionary.
struct SParams: Sendable, Equatable {
    var names: [String] = []
    var values: [String: SParam] = [:]

    init() {}

    init(_ object: JSONObject?) {
        guard let object else { return }
        for (k, v) in object.entries {
            if let p = SParam(v) { names.append(k); values[k] = p }
        }
    }

    subscript(_ name: String) -> SParam? { values[name] }

    func value(_ name: String, at t: Double, default d: Double) -> Double {
        values[name]?.value(at: t) ?? d
    }

    /// All parameters evaluated at `t`; parameters without a numeric value are left out.
    func evaluated(at t: Double) -> [String: Double] {
        var out: [String: Double] = [:]
        for n in names { if let v = values[n]?.value(at: t) { out[n] = v } }
        return out
    }
}

/// Sendable copy of an `effects[]` entry.
struct SEffect: Sendable, Equatable {
    var name: String
    var bypassed: Bool
    var parameters: SParams

    func instance(at t: Double) -> EffectInstance {
        EffectInstance(name: name, parameters: parameters.evaluated(at: t), bypassed: bypassed)
    }
}
