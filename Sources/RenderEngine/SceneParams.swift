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

    /// Every key has zero length: an audio volume point envelope [obs, audio.md §4 AU1].
    var isPointEnvelope: Bool { !keys.isEmpty && keys.allSatisfy { $0.endTime == $0.time } }

    /// Point-envelope value: linear between points sorted by time, the first value before the first
    /// point, the last after the last; `defaultValue` unused. Same rule as AudioEngine and
    /// `TSCProjKit.Parameters.volume(at:)`.
    func pointValue(at ticks: Double) -> Double? {
        let pts = keys.compactMap { k in k.value.map { (t: k.time, v: $0) } }.sorted { $0.t < $1.t }
        guard let first = pts.first, let last = pts.last else { return nil }
        if ticks <= first.t { return first.v }
        for i in 1..<pts.count where ticks < pts[i].t {
            let a = pts[i - 1], b = pts[i]
            return a.v + (b.v - a.v) * (ticks - a.t) / (b.t - a.t)
        }
        return last.v
    }

    /// `volume` at `ticks`: the point envelope when every key has zero length, else `value(at:)`.
    func volume(at ticks: Double) -> Double? { isPointEnvelope ? pointValue(at: ticks) : value(at: ticks) }

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
    /// `start`/`duration` window on the keyframe axis, ticks; nil = whole clip.
    var window: (start: Double, duration: Double)? = nil
    /// `leftEdgeMods` / `rightEdgeMods` ramps: parameter, fade in (true) or out, ramp length (ticks).
    var ramps: [EdgeRamp] = []

    struct EdgeRamp: Sendable, Equatable {
        var parameter: String
        var fadeIn: Bool
        var duration: Double
    }

    static func == (a: SEffect, b: SEffect) -> Bool {
        a.name == b.name && a.bypassed == b.bypassed && a.parameters == b.parameters
            && a.window?.start == b.window?.start && a.window?.duration == b.window?.duration && a.ramps == b.ramps
    }

    /// Reads `leftEdgeMods`/`rightEdgeMods` [effects/README.md §1]: `FadeInFunc` ramps the named parameter
    /// up from 0 over `duration` at the effect's start, `FadeOutFunc` down to 0 at its end (linear [?]).
    static func ramps(_ e: JSONObject) -> [EdgeRamp] {
        var out: [EdgeRamp] = []
        for key in ["leftEdgeMods", "rightEdgeMods"] {
            for case let mod? in (e[key]?.array?.items ?? []).map(\.object) {
                let d = mod["duration"]?.double ?? 0
                guard d > 0 else { continue }
                for case let p? in (mod["parameters"]?.array?.items ?? []).map(\.object) {
                    guard let name = p["name"]?.string else { continue }
                    let fn = p["func"]?.string ?? ""
                    out.append(EdgeRamp(parameter: name, fadeIn: fn == "FadeInFunc" || (fn.isEmpty && key == "leftEdgeMods"),
                                        duration: d))
                }
            }
        }
        return out
    }

    /// Whether the effect applies at keyframe time `t` (time-mapping.md §7).
    func isActive(at t: Double) -> Bool {
        guard let w = window else { return true }
        return Conventions.effectWindowContains(start: w.start, duration: w.duration, t)
    }

    /// `span`: the clip's extent on the keyframe axis, used for edge ramps when the effect has no window.
    func instance(at t: Double, span: (lo: Double, hi: Double)? = nil) -> EffectInstance {
        var p = parameters.evaluated(at: t)
        if !ramps.isEmpty {
            let lo = window?.start ?? span?.lo ?? -.infinity
            let hi = window.map { $0.start + $0.duration } ?? span?.hi ?? .infinity
            for r in ramps {
                guard let v = p[r.parameter] else { continue }
                let k = r.fadeIn ? (t - lo) / r.duration : (hi - t) / r.duration
                p[r.parameter] = v * Conventions.clamp01(k)
            }
        }
        return EffectInstance(name: name, parameters: p, bypassed: bypassed)
    }
}

/// A `GenericBehaviorEffect` (behaviors.md). Rendered as an opacity fade over its in/out phases until
/// experiments BH1/BH2 give the motion [behaviors.md §5: visually approximate].
struct SBehavior: Sendable, Equatable {
    var preset: String
    var bypassed: Bool
    /// `start`/`duration`, keyframe axis ticks; nil = whole clip.
    var window: (start: Double, duration: Double)?
    var inPhase: Bool
    var outPhase: Bool

    static func == (a: SBehavior, b: SBehavior) -> Bool {
        a.preset == b.preset && a.bypassed == b.bypassed && a.inPhase == b.inPhase && a.outPhase == b.outPhase
            && a.window?.start == b.window?.start && a.window?.duration == b.window?.duration
    }

    init?(_ e: JSONObject) {
        guard e["_type"]?.string == "GenericBehaviorEffect" else { return nil }
        preset = e["effectName"]?.string ?? ""
        bypassed = e["bypassed"]?.bool ?? false
        window = e["duration"]?.double.map { (e["start"]?.double ?? 0, $0) }
        func on(_ k: String) -> Bool {
            let n = e[k]?.object?["attributes"]?.object?["name"]?.string ?? "none"
            return n != "none" && !n.isEmpty
        }
        inPhase = on("in"); outPhase = on("out")
    }

    /// Opacity multiplier at keyframe time `t`; `span` = the clip on the keyframe axis; `phase` = phase
    /// length, ticks.
    func opacity(at t: Double, span: (lo: Double, hi: Double), phase: Double) -> Double {
        guard !bypassed else { return 1 }
        let lo = window?.start ?? span.lo, hi = window.map { $0.start + $0.duration } ?? span.hi
        guard t >= lo, t < hi, phase > 0 else { return 1 }
        let d = min(phase, (hi - lo) / 2)
        var k = 1.0
        if inPhase { k = min(k, (t - lo) / d) }
        if outPhase { k = min(k, (hi - t) / d) }
        return Conventions.clamp01(k)
    }
}
