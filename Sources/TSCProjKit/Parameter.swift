import Foundation

/// Interpolation codes seen in `.tscproj` keyframes and parameters.
public enum Interpolation: String {
    /// Ease in / ease out (Camtasia's default for transforms).
    case easeInOut = "eioe"
    case linear = "linr"
    /// Unknown codes are preserved as-is in the JSON; this is only the decode.
    case unknown

    init(code: String?) { self = code.flatMap(Interpolation.init(rawValue:)) ?? .linear }
}

/// One keyframe. `value` can be a number, a point array (`[x, y, z]`), a
/// string (caption words) or `null`.
public struct Keyframe {
    public var time: Int64
    public var endTime: Int64
    public var duration: Int64
    public var value: JSON
    public var interp: Interpolation

    init(_ o: JSONObject) {
        time = o["time"]?.int ?? 0
        endTime = o["endTime"]?.int ?? time
        duration = o["duration"]?.int ?? 0
        value = o["value"] ?? .null
        interp = Interpolation(code: o["interp"]?.string)
    }

    public var number: Double? { value.double }
    public var vector: [Double]? { value.array?.items.compactMap(\.double) }
}

/// Read view over one entry of a `parameters` dict.
///
/// The same key appears in two shapes:
/// - bare scalar: `"translation0": 172.7`
/// - animated object: `{"type": "double", "defaultValue": 0.0, "interp": "eioe", "keyframes": [...]}`
///
/// Keyframe `time` values are relative to the owning clip's start.
public struct Parameter {
    public let raw: JSON

    public init(_ raw: JSON) { self.raw = raw }

    public var isAnimated: Bool { !(raw.object?["keyframes"]?.array?.items.isEmpty ?? true) }
    public var type: String? { raw.object?["type"]?.string }
    public var interp: Interpolation { Interpolation(code: raw.object?["interp"]?.string) }

    /// The constant value, or `defaultValue` for an object parameter.
    public var defaultValue: JSON? {
        if let o = raw.object { return o["defaultValue"] }
        return raw
    }

    public var keyframes: [Keyframe] {
        raw.object?["keyframes"]?.array?.items.compactMap(\.object).map(Keyframe.init) ?? []
    }

    /// Value at clip-relative `ticks` for numeric parameters.
    ///
    /// Each keyframe animates from the previous value to its own `value`
    /// across `[time, endTime]`; between keyframes the value holds.
    public func value(at ticks: Int64) -> Double? {
        let base = defaultValue?.double
        let kfs = keyframes
        guard !kfs.isEmpty else { return base }
        var current = base ?? kfs[0].number ?? 0
        for kf in kfs {
            guard let target = kf.number else { continue }
            if ticks < kf.time { return current }
            if ticks >= kf.endTime || kf.endTime == kf.time { current = target; continue }
            let t = Double(ticks - kf.time) / Double(kf.endTime - kf.time)
            return current + (target - current) * Parameter.ease(t, kf.interp)
        }
        return current
    }

    static func ease(_ t: Double, _ i: Interpolation) -> Double {
        switch i {
        case .easeInOut: t * t * (3 - 2 * t)  // smoothstep; exact Camtasia curve unverified
        default: t
        }
    }
}

/// Named view over a `parameters` dict with the transform keys used on
/// visual clips. Missing keys mean "Camtasia default".
public struct Parameters {
    public let object: JSONObject

    public init(_ object: JSONObject) { self.object = object }

    public subscript(name: String) -> Parameter? { object[name].map(Parameter.init) }
    public var names: [String] { object.keys }

    public func value(_ name: String, at ticks: Int64 = 0, default d: Double) -> Double {
        self[name]?.value(at: ticks) ?? d
    }

    /// Canvas offset from centre, in project pixels.
    public func translation(at t: Int64 = 0) -> (x: Double, y: Double, z: Double) {
        (value("translation0", at: t, default: 0), value("translation1", at: t, default: 0),
         value("translation2", at: t, default: 0))
    }

    public func scale(at t: Int64 = 0) -> (x: Double, y: Double) {
        (value("scale0", at: t, default: 1), value("scale1", at: t, default: 1))
    }

    /// Crop as fractions: left, top, right, bottom (`geometryCrop0…3`).
    public func crop(at t: Int64 = 0) -> (l: Double, t: Double, r: Double, b: Double) {
        (value("geometryCrop0", at: t, default: 0), value("geometryCrop1", at: t, default: 0),
         value("geometryCrop2", at: t, default: 0), value("geometryCrop3", at: t, default: 0))
    }

    /// Crop in source space (images, callouts, screen recordings): `sourceCrop0…3`.
    public func sourceCrop(at t: Int64 = 0) -> (l: Double, t: Double, r: Double, b: Double) {
        (value("sourceCrop0", at: t, default: 0), value("sourceCrop1", at: t, default: 0),
         value("sourceCrop2", at: t, default: 0), value("sourceCrop3", at: t, default: 0))
    }

    /// Z-axis rotation in radians (`rotation2`; 0/1 would be X/Y tilt).
    public func rotation(at t: Int64 = 0) -> Double { value("rotation2", at: t, default: 0) }
    public func opacity(at t: Int64 = 0) -> Double { value("opacity", at: t, default: 1) }
    public func volume(at t: Int64 = 0) -> Double { value("volume", at: t, default: 1) }

    /// Writes a constant, replacing any animation, keeping the key's position.
    public func set(_ name: String, _ value: Double) {
        if let o = object[name]?.object {
            o["defaultValue"] = .number(JSONNumber(value))
            o["keyframes"] = nil
        } else {
            object[name] = .number(JSONNumber(value))
        }
    }
}
