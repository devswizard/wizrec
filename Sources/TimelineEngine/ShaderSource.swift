import Foundation
import TSCProjKit

// Shader backgrounds in the project (`docs/specs/shader-backgrounds.md` §6, SH2 [obs]):
// the source's `sourceBin` `effectDef` copy of the file's parameters, and the clip's
// `sourceEffect` with one animatable parameter per channel / coordinate.

/// One entry of a shader source's `sourceBin` `effectDef` array, in the project's numeric
/// form (shader-backgrounds.md §6 code table). Colours are 0–1 RGBA, positions pixels of
/// the 1920×1080 frame with a z of 0.
public struct ShaderEffectDefEntry: Sendable, Equatable {
    /// `defaultValue` as written.
    public enum Value: Sendable, Equatable {
        /// `[r, g, b, a]`, 0–1.
        case color([Double])
        case double(Double)
        /// `[x, y, 0]`, pixels.
        case position([Double])
        case string(String)
    }

    /// `minValue` / `maxValue`: numbers for doubles, `""` for the synthetic string entry.
    public enum Bound: Sendable, Equatable {
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

    public init(name: String, type: String, scalingType: Int, unitType: Int, userInterfaceType: Int,
                defaultValue: Value, minValue: Bound? = nil, maxValue: Bound? = nil) {
        self.name = name; self.type = type; self.scalingType = scalingType; self.unitType = unitType
        self.userInterfaceType = userInterfaceType; self.defaultValue = defaultValue
        self.minValue = minValue; self.maxValue = maxValue
    }

    /// The entry as written, keys in Camtasia's order: `name, type, defaultValue, maxValue,
    /// minValue, scalingType, unitType, userInterfaceType` [obs, demo project].
    var json: JSON {
        func bound(_ b: Bound) -> JSON {
            switch b {
            case .double(let d): J.dbl(d)
            case .string(let s): .string(s)
            }
        }
        let value: JSON = switch defaultValue {
        case .color(let v), .position(let v): J.arr(v.map(J.dbl))
        case .double(let d): J.dbl(d)
        case .string(let s): .string(s)
        }
        var pairs: [(String, JSON)] = [("name", .string(name)), ("type", .string(type)), ("defaultValue", value)]
        if let maxValue { pairs.append(("maxValue", bound(maxValue))) }
        if let minValue { pairs.append(("minValue", bound(minValue))) }
        pairs += [("scalingType", J.int(scalingType)), ("unitType", J.int(unitType)),
                  ("userInterfaceType", J.int(userInterfaceType))]
        return J.obj(pairs)
    }
}

/// Writes a shader source's `sourceBin` `effectDef` (replacing any), placed after
/// `sourceTracks` like Camtasia's [obs]. Clips inserted from the source afterwards get a
/// matching `sourceEffect` (see `InsertClip`).
@MainActor public final class SetSourceEffectDef: EditCommand {
    public let name = "Import Media"
    public let sourceID: Int64
    public let entries: [ShaderEffectDefEntry]
    public init(sourceID: Int64, entries: [ShaderEffectDefEntry]) {
        self.sourceID = sourceID; self.entries = entries
    }
    var swap = ValueSwap()
    public func apply(to project: Project) throws { try ShaderSource.setEffectDef(self, project) }
    public func revert(on project: Project) throws { try swap.restore(in: project) }
}

@MainActor
enum ShaderSource {
    static func setEffectDef(_ c: SetSourceEffectDef, _ project: Project) throws {
        let items = project.root["sourceBin"]?.array?.items ?? []
        guard let i = items.firstIndex(where: { $0.object?["id"]?.int == c.sourceID }),
              let old = items[i].object else { throw EditError.invalid("source \(c.sourceID) not found") }
        let def = J.arr(c.entries.map(\.json))
        var pairs = old.entries.map { ($0.key, $0.value.copy()) }
        if let at = pairs.firstIndex(where: { $0.0 == "effectDef" }) {
            pairs[at].1 = def                                   // keep an existing entry's position
        } else if let at = pairs.firstIndex(where: { $0.0 == "sourceTracks" }) {
            pairs.insert(("effectDef", def), at: at + 1)
        } else if let at = pairs.firstIndex(where: { $0.0 == "metadata" }) {
            pairs.insert(("effectDef", def), at: at)
        } else {
            pairs.append(("effectDef", def))
        }
        try c.swap.commit([(M2.sourceBinPath.appending(.index(i)), .object(JSONObject(pairs)))], in: project)
    }

    /// The clip's `sourceEffect` for a source with an `effectDef` (shader-backgrounds.md §6):
    /// a colour as `<name>-red/-green/-blue/-alpha`, a position as `<name>.x` / `<name>.y`, a
    /// double under its name with `uiHints`, a string entry as a bare string; every number an
    /// animatable `linr` parameter at its default, numbers copied verbatim. Nil when the source
    /// has no `effectDef` or it is empty.
    static func sourceEffect(for source: JSONObject) -> JSON? {
        guard let def = source["effectDef"]?.array?.items, !def.isEmpty else { return nil }
        func param(_ v: JSON, hints: JSON? = nil) -> JSON {
            var p: [(String, JSON)] = [("type", .string("double")), ("defaultValue", v), ("interp", .string("linr"))]
            if let hints { p.append(("uiHints", hints)) }
            return J.obj(p)
        }
        var params: [(String, JSON)] = []
        for case .object(let e) in def {
            guard let name = e["name"]?.string, let value = e["defaultValue"] else { continue }
            switch e["type"]?.string {
            case "Color":
                let c = value.array?.items ?? []
                for (k, ch) in ["red", "green", "blue", "alpha"].enumerated() {
                    params.append(("\(name)-\(ch)", param(c.indices.contains(k) ? c[k].copy() : J.dbl(k == 3 ? 1 : 0))))
                }
            case "Position":
                let p = value.array?.items ?? []
                params.append(("\(name).x", param(p.first?.copy() ?? J.dbl(0))))
                params.append(("\(name).y", param(p.count > 1 ? p[1].copy() : J.dbl(0))))
            case "double":
                let hints = J.obj([("userInterfaceType", e["userInterfaceType"]?.copy() ?? J.int(0)),
                                   ("unitType", e["unitType"]?.copy() ?? J.int(0))])
                params.append((name, param(value.copy(), hints: hints)))
            case "string":
                params.append((name, value.copy()))
            default:
                continue
            }
        }
        return J.obj([("effectName", .string("SourceEffect")), ("bypassed", .bool(false)),
                      ("category", .string("")), ("parameters", J.obj(params))])
    }
}
