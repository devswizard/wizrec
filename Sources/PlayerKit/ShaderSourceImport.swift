import Foundation
import MediaEngine
import TimelineEngine
import WizRecAssets

/// Import of `.tscshadervid` backgrounds: the source's `sourceBin` `effectDef` in Camtasia's
/// layout (`docs/specs/shader-backgrounds.md` §6, SH2), written by `SetSourceEffectDef` in the
/// same undo step as `AddSource`. Clips placed from the source then get a `sourceEffect`
/// (`InsertClip`).
enum ShaderSourceImport {
    /// The `effectDef` entries for a shader file (`info.kind == .shader`) at `url`; nil for
    /// other media or a file whose JSON can't be read (the source is then added without one).
    static func entries(info: MediaInfo, url: URL) -> [ShaderEffectDefEntry]? {
        guard info.kind == .shader, let data = try? Data(contentsOf: url),
              let e = try? ShaderSourceLayout.entries(shaderVid: data) else { return nil }
        return e.map(ShaderEffectDefEntry.init)
    }

    /// The `SetSourceEffectDef` step for the source added by step `addIndex`; none when `entries` is nil.
    @MainActor
    static func steps(addIndex: Int, _ entries: [ShaderEffectDefEntry]?) -> [CompoundCommand.Builder] {
        guard let entries else { return [] }
        return [{ _, done in
            guard let id = (done[addIndex] as? AddSource)?.sourceID else { throw EditError.invalid("no source id") }
            return SetSourceEffectDef(sourceID: id, entries: entries)
        }]
    }
}

extension ShaderEffectDefEntry {
    /// WizRecAssets' project-form entry as TimelineEngine's value type (same fields).
    init(_ e: ShaderSourceEntry) {
        let value: Value = switch e.defaultValue {
        case .color(let c): .color(c)
        case .double(let d): .double(d)
        case .position(let p): .position(p)
        case .string(let s): .string(s)
        }
        func bound(_ b: ShaderSourceEntry.Bound?) -> Bound? {
            switch b {
            case .double(let d): .double(d)
            case .string(let s): .string(s)
            case nil: nil
            }
        }
        self.init(name: e.name, type: e.type, scalingType: e.scalingType, unitType: e.unitType,
                  userInterfaceType: e.userInterfaceType, defaultValue: value,
                  minValue: bound(e.minValue), maxValue: bound(e.maxValue))
    }
}
