import Foundation

/// A straight-alpha sRGB colour, each channel 0–1 (sRGB-encoded, as shaders and projects store it).
public struct AssetColor: Sendable, Hashable, Codable {
    public var red, green, blue, alpha: Double

    public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    /// Parses `"RRGGBB"` or `"RRGGBBAA"` (a leading `#` is allowed). Nil when malformed.
    public init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6 || digits.count == 8, let v = UInt64(digits, radix: 16) else { return nil }
        let full = digits.count == 6 ? (v << 8) | 0xFF : v
        func byte(_ shift: UInt64) -> Double { Double((full >> shift) & 0xFF) / 255 }
        self.init(byte(24), byte(16), byte(8), byte(0))
    }

    /// `"RRGGBB"` when opaque, else `"RRGGBBAA"`.
    public var hex: String {
        func b(_ v: Double) -> String { String(format: "%02X", Int((min(max(v, 0), 1) * 255).rounded())) }
        return b(red) + b(green) + b(blue) + (alpha >= 1 ? "" : b(alpha))
    }

    public init(from decoder: any Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = AssetColor(hex: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad colour \(s)"))
        }
        self = c
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }
}

/// The value of one asset parameter.
public enum ParameterValue: Sendable, Hashable {
    case double(Double)
    case color(AssetColor)
    case bool(Bool)
    /// A point in pixels of the asset's natural frame (1920×1080 for backgrounds), top-left origin, y down.
    case position(x: Double, y: Double)
}

/// One user-adjustable parameter of an asset: a shader uniform (`_<name>`) or a preset field.
public struct AssetParameter: Sendable, Hashable {
    public enum Kind: String, Sendable, Codable {
        case double, color, bool, position
    }

    /// Display unit hint for inspectors.
    public enum Unit: String, Sendable, Codable {
        /// Plain number.
        case none
        /// A 0–1 fraction shown as a percentage.
        case percentage
        /// An angle in radians (shown as a dial).
        case radians
        /// Pixels of the asset's natural frame.
        case pixels
        /// A rate multiplier (1 = normal speed).
        case multiplier
    }

    /// Identifier; the shader uniform is `_` + `name`, e.g. `Color0` → `_Color0`.
    public var name: String
    public var displayName: String
    public var kind: Kind
    public var defaultValue: ParameterValue
    /// Allowed range for `double` parameters (inclusive); nil for other kinds.
    public var range: ClosedRange<Double>?
    public var unit: Unit

    public init(name: String, displayName: String, kind: Kind, defaultValue: ParameterValue,
                range: ClosedRange<Double>? = nil, unit: Unit = .none) {
        self.name = name; self.displayName = displayName; self.kind = kind
        self.defaultValue = defaultValue; self.range = range; self.unit = unit
    }

    /// The uniform name the shader declares.
    public var uniformName: String { "_" + name }

    /// The scalar keys this parameter takes in a project's `parameters` dictionary, with the default
    /// values: colours split into `<name>-red/-green/-blue/-alpha` (0–1), positions into
    /// `<name>-x/-y` (px), booleans as 0/1 [shader-backgrounds.md §6].
    public var projectDefaults: [(key: String, value: Double)] {
        switch defaultValue {
        case .double(let v): return [(name, v)]
        case .bool(let b): return [(name, b ? 1 : 0)]
        case .color(let c):
            return [("\(name)-red", c.red), ("\(name)-green", c.green), ("\(name)-blue", c.blue),
                    ("\(name)-alpha", c.alpha)]
        case .position(let x, let y): return [("\(name)-x", x), ("\(name)-y", y)]
        }
    }
}

// MARK: JSON form

/// `{"name", "displayName", "type", "default", "min"?, "max"?, "unit"?}` as written in our asset files.
struct ParameterRecord: Codable {
    var name: String
    var displayName: String?
    var type: AssetParameter.Kind
    var `default`: DefaultValue
    var min: Double?
    var max: Double?
    var unit: AssetParameter.Unit?

    /// `default` is a number, a hex colour string, a boolean or `[x, y]`.
    enum DefaultValue: Codable {
        case number(Double), string(String), bool(Bool), pair([Double])

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let d = try? c.decode(Double.self) { self = .number(d) }
            else if let s = try? c.decode(String.self) { self = .string(s) }
            else { self = .pair(try c.decode([Double].self)) }
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .number(let d): try c.encode(d)
            case .string(let s): try c.encode(s)
            case .bool(let b): try c.encode(b)
            case .pair(let p): try c.encode(p)
            }
        }
    }

    func parameter() throws -> AssetParameter {
        let value: ParameterValue
        switch (type, self.default) {
        case (.double, .number(let d)): value = .double(d)
        case (.bool, .bool(let b)): value = .bool(b)
        case (.color, .string(let s)):
            guard let c = AssetColor(hex: s) else { throw AssetError.invalid("parameter \(name): colour \(s)") }
            value = .color(c)
        case (.position, .pair(let p)) where p.count == 2: value = .position(x: p[0], y: p[1])
        default: throw AssetError.invalid("parameter \(name): default does not match type \(type.rawValue)")
        }
        var range: ClosedRange<Double>?
        if type == .double {
            guard let lo = min, let hi = max, lo <= hi else { throw AssetError.invalid("parameter \(name): min/max") }
            range = lo...hi
        }
        return AssetParameter(name: name, displayName: displayName ?? name, kind: type, defaultValue: value,
                              range: range, unit: unit ?? .none)
    }
}

/// Why a bundled asset could not be loaded.
public enum AssetError: Error, Equatable, CustomStringConvertible {
    case missing(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .missing(let s): "missing: \(s)"
        case .invalid(let s): "invalid: \(s)"
        }
    }
}
