import Foundation

// How a `.tscshadervid` background is described inside a project, as Camtasia writes it on import
// (`docs/specs/shader-backgrounds.md` §6, SH2 code table [obs]). WizRec uses this layout when it
// writes a new shader source, so its projects look like Camtasia's.

/// One entry of a shader source's `sourceBin` `effectDef` array, in the project's numeric form.
public struct ShaderSourceEntry: Sendable, Hashable {
    /// A default value as written in the project.
    public enum Value: Sendable, Hashable {
        /// `[r, g, b, a]`, 0–1.
        case color([Double])
        case double(Double)
        /// `[x, y, 0]`: the file's pixel position with a z of 0 appended.
        case position([Double])
        case string(String)
    }

    /// `minValue` / `maxValue`: numbers for doubles, `""` for the synthetic string entry.
    public enum Bound: Sendable, Hashable {
        case double(Double)
        case string(String)
    }

    public var name: String
    /// `"Color"`, `"double"`, `"Position"` or `"string"`.
    public var type: String
    public var scalingType: Int
    public var unitType: Int
    public var userInterfaceType: Int
    public var defaultValue: Value
    public var minValue: Bound?
    public var maxValue: Bound?

    /// The clip's `uiHints` for this parameter: doubles only (colours and positions have none) [obs].
    public var clipUIHints: (userInterfaceType: Int, unitType: Int)? {
        type == "double" ? (userInterfaceType, unitType) : nil
    }

    /// The clip's `sourceEffect.parameters` keys and defaults for this entry, in order: a colour as
    /// `<name>-red/-green/-blue/-alpha`, a position as `<name>.x` / `<name>.y` (no z), a double under
    /// its name, the synthetic entry as `sourceFileType` (a bare string) [obs, §6].
    public var clipParameters: [(key: String, value: Value)] {
        switch defaultValue {
        case .color(let c):
            return zip(["red", "green", "blue", "alpha"], c).map { ("\(name)-\($0)", .double($1)) }
        case .position(let p):
            return [("\(name).x", .double(p.first ?? 0)), ("\(name).y", .double(p.count > 1 ? p[1] : 0))]
        case .double, .string:
            return [(name, defaultValue)]
        }
    }
}

/// Maps a `.tscshadervid` file's `effectDef` to its project form.
public enum ShaderSourceLayout {
    /// Length of a background clip dropped on the timeline, seconds [obs, SH2].
    public static let clipDurationSeconds = 60.0
    /// The synthetic last entry's name and value.
    public static let sourceFileTypeName = "sourceFileType"
    public static let sourceFileTypeValue = "tscshadervid"

    /// `unitType` codes: none 0, percentage 1, radians 3 [obs].
    static func unitCode(_ s: String?) -> Int {
        switch s?.lowercased() {
        case "percentage": 1
        case "radians": 3
        default: 0
        }
    }

    /// The `sourceBin` `effectDef` entries for a shader file, in file order, ending with the
    /// synthetic `sourceFileType` entry. Entries of unknown type or without a name are skipped.
    public static func entries(shaderVid data: Data) throws -> [ShaderSourceEntry] {
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        guard let utf8 = text?.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: utf8) as? [String: Any] else {
            throw AssetError.invalid("not a shader-video file")
        }
        func num(_ v: Any?) -> Double? {
            if let n = v as? NSNumber { return n.doubleValue }
            if let s = v as? String { return Double(s) }
            return nil
        }
        var out: [ShaderSourceEntry] = []
        for case let e as [String: Any] in obj["effectDef"] as? [Any] ?? [] {
            guard let name = e["name"] as? String else { continue }
            switch e["type"] as? String {
            case "Color":
                let c = (e["value"] as? String).flatMap(AssetColor.init(shaderText:)) ?? AssetColor(0, 0, 0)
                out.append(ShaderSourceEntry(name: name, type: "Color", scalingType: 3, unitType: 0, userInterfaceType: 6,
                                             defaultValue: .color([c.red, c.green, c.blue, c.alpha])))
            case "Position":
                let v = (e["value"] as? [Any])?.compactMap(num) ?? []
                out.append(ShaderSourceEntry(name: name, type: "Position", scalingType: 1, unitType: 0, userInterfaceType: 5,
                                             defaultValue: .position([v.first ?? 0, v.count > 1 ? v[1] : 0, 0])))
            case "double":
                let b = e["valueBounds"] as? [String: Any]
                let d = num(e["defaultValue"]) ?? num(b?["defaultValue"]) ?? 0
                let lo = num(e["minValue"]) ?? num(b?["minValue"]), hi = num(e["maxValue"]) ?? num(b?["maxValue"])
                let unit = unitCode((e["unitType"] ?? e["UIUnitType"]) as? String)
                let ui = (e["userInterfaceType"] as? String)?.lowercased() == "directional" ? 2 : 0
                // A missing range is written as 0 / 0 [obs for directional; inf otherwise].
                out.append(ShaderSourceEntry(name: name, type: "double", scalingType: 0, unitType: unit, userInterfaceType: ui,
                                             defaultValue: .double(d), minValue: .double(lo ?? 0), maxValue: .double(hi ?? 0)))
            default:
                continue
            }
        }
        out.append(ShaderSourceEntry(name: sourceFileTypeName, type: "string", scalingType: 0, unitType: 0,
                                     userInterfaceType: 0, defaultValue: .string(sourceFileTypeValue),
                                     minValue: .string(""), maxValue: .string("")))
        return out
    }
}

extension AssetColor {
    /// A shader file's colour text [shader-backgrounds.md §6, SH2]: exactly six hex digits (optional
    /// `#`) are RGB with alpha 1 [obs]; any other hex text (spaces dropped, at most 8 digits) is one
    /// hexadecimal number laid out as RRGGBBAA, so `" 130939"` → bytes 00 13 09 39 [obs value, inf rule].
    public init?(shaderText s: String) {
        let body = s.hasPrefix("#") ? String(s.dropFirst()) : s
        func byte(_ v: UInt32, _ shift: UInt32) -> Double { Double((v >> shift) & 0xFF) / 255 }
        if body.count == 6, body.allSatisfy(\.isHexDigit), let v = UInt32(body, radix: 16) {
            self.init(byte(v, 16), byte(v, 8), byte(v, 0), 1)
            return
        }
        let digits = body.filter { $0 != " " }
        guard !digits.isEmpty, digits.count <= 8, digits.allSatisfy(\.isHexDigit), let v = UInt32(digits, radix: 16)
        else { return nil }
        self.init(byte(v, 24), byte(v, 16), byte(v, 8), byte(v, 0))
    }
}

extension BackgroundAsset {
    /// This background's `sourceBin` `effectDef` entries (project form).
    public func sourceBinEntries() throws -> [ShaderSourceEntry] {
        try ShaderSourceLayout.entries(shaderVid: shaderVidData())
    }
}
