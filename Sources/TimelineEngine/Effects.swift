import Foundation
import TSCProjKit

/// One entry of a clip's effect list as `Effects.list` reports it.
public struct EffectSummary: Sendable, Equatable {
    /// `effectName`, e.g. `DropShadow`.
    public var name: String
    /// `categoryVisualEffects`, `categoryAudioEffects`, … (may be empty).
    public var category: String
    public var bypassed: Bool
}

/// Effect lists of clips.
///
/// A clip's effect list is the `effects` array of the clip object, except
/// for `UnifiedMedia`: visual effects sit on its `video` child and audio
/// effects on the parent [obs, demo]. Its list is therefore the video
/// child's effects followed by the parent's, and `effectIndex` everywhere
/// counts in that combined order.
@MainActor
public enum Effects {
    public static func list(_ project: Project, clipID: Int64) throws -> [EffectSummary] {
        let loc = try Locator.locate(clipID, in: project)
        return slots(loc.clip).map { owner, i in
            let e = owner["effects"]?.array?[i].object
            return EffectSummary(name: e?["effectName"]?.string ?? "", category: e?["category"]?.string ?? "",
                                 bypassed: e?["bypassed"]?.bool ?? false)
        }
    }

    /// Owners whose `effects` make up the clip's list, in order.
    static func owners(_ clip: JSONObject) -> [JSONObject] {
        clip.clipType == "UnifiedMedia" ? [clip["video"]?.object, clip].compactMap { $0 } : [clip]
    }

    static func slots(_ clip: JSONObject) -> [(JSONObject, Int)] {
        owners(clip).flatMap { o in (0..<(o["effects"]?.array?.count ?? 0)).map { (o, $0) } }
    }

    static func slot(_ clip: JSONObject, _ index: Int) throws -> (owner: JSONObject, index: Int) {
        let s = slots(clip)
        guard s.indices.contains(index) else { throw EditError.invalid("clip \(clip.clipID ?? -1) has no effect \(index)") }
        return s[index]
    }

    /// Edits the clip on a track copy and commits it through `swap`.
    static func editClip(_ project: Project, _ clipID: Int64, _ swap: inout TrackSwap,
                         _ body: (JSONObject) throws -> Void) throws {
        let loc = try Locator.locate(clipID, in: project)
        var edits = TrackEdits(project)
        let track = try edits.track(at: loc.trackPath)
        guard let clip = track["medias"]?.array?[loc.index].object else { throw EditError.clipNotFound(clipID) }
        try body(clip)
        try edits.commit(&swap)
    }
}

/// Adds an effect (a JSON object with at least `effectName`) to a clip's
/// effect list at `index` (combined order, see `Effects`; nil = end of its
/// owner). On a `UnifiedMedia`, an effect with category
/// `categoryAudioEffects` goes to the parent, any other to `video`.
/// `metadata.effectApplied` on the clip becomes the effect's name when the
/// clip has metadata [inf: the key always names one of the clip's effects or
/// "none" in the corpus].
@MainActor public final class AddEffect: EditCommand {
    public let name = "Add Effect"
    public let clipID: Int64
    public let effectJSON: String
    public let index: Int?
    private var swap = TrackSwap()

    public init(clipID: Int64, effectJSON: String, at index: Int? = nil) {
        self.clipID = clipID; self.effectJSON = effectJSON; self.index = index
    }

    /// Builds the effect in the format-10.0 shape: `{effectName, bypassed,
    /// category, parameters}` with each parameter as
    /// `{type: double, defaultValue, interp: linr, uiHints}` [obs, demo].
    public convenience init(clipID: Int64, name effectName: String, category: String = "categoryVisualEffects",
                            parameters: [(String, Double)], at index: Int? = nil) {
        let params = JSONObject(parameters.map { k, v in
            (k, J.obj([("type", .string("double")), ("defaultValue", J.dbl(v)), ("interp", .string("linr")),
                       ("uiHints", J.obj([("userInterfaceType", J.int(0)), ("unitType", J.int(0))]))]))
        })
        let e = J.obj([("effectName", .string(effectName)), ("bypassed", .bool(false)),
                       ("category", .string(category)), ("parameters", .object(params))])
        self.init(clipID: clipID, effectJSON: String(decoding: e.serialized(), as: UTF8.self), at: index)
    }

    public func apply(to project: Project) throws {
        guard let effect = try JSON.parse(effectJSON).object, let ename = effect["effectName"]?.string else {
            throw EditError.invalid("effect must be an object with effectName")
        }
        try Effects.editClip(project, clipID, &swap) { clip in
            let audio = effect["category"]?.string == "categoryAudioEffects"
            let owner = clip.clipType == "UnifiedMedia" ? (audio ? clip : clip["video"]?.object) : clip
            guard let owner else { throw EditError.invalid("UnifiedMedia \(clipID) has no video part") }
            if owner["effects"]?.array == nil { owner["effects"] = J.emptyArray }
            guard let list = owner["effects"]?.array else { throw EditError.invalid("no effects") }
            var at = list.count
            if let index {
                let slots = Effects.slots(clip)
                guard (0...slots.count).contains(index) else { throw EditError.invalid("bad effect index \(index)") }
                // Position inside this owner: count its slots before `index`.
                at = slots.prefix(index).filter { $0.0 === owner }.count
            }
            list.items.insert(.object(effect), at: at)
            if let md = clip["metadata"]?.object, md["effectApplied"] != nil { md["effectApplied"] = .string(ename) }
            AnimationSync.sync(owner)
        }
    }

    public func revert(on project: Project) throws { try swap.restore(in: project) }
}

/// Removes effect `index` (combined order). `metadata.effectApplied` becomes
/// the last remaining effect's name, or `"none"` [inf].
@MainActor public final class RemoveEffect: EditCommand {
    public let name = "Remove Effect"
    public let clipID: Int64
    public let index: Int
    private var swap = TrackSwap()
    public init(clipID: Int64, index: Int) { self.clipID = clipID; self.index = index }
    public func apply(to project: Project) throws {
        try Effects.editClip(project, clipID, &swap) { clip in
            let (owner, i) = try Effects.slot(clip, index)
            owner["effects"]?.array?.items.remove(at: i)
            if let md = clip["metadata"]?.object, md["effectApplied"] != nil {
                let rest = Effects.slots(clip).compactMap { o, j in o["effects"]?.array?[j].object?["effectName"]?.string }
                md["effectApplied"] = .string(rest.last ?? "none")
            }
            AnimationSync.sync(owner)
        }
    }
    public func revert(on project: Project) throws { try swap.restore(in: project) }
}

/// Reorders effects (render order) within one owner (combined indices).
@MainActor public final class MoveEffect: EditCommand {
    public let name = "Reorder Effects"
    public let clipID: Int64
    public let from: Int, to: Int
    private var swap = TrackSwap()
    public init(clipID: Int64, from: Int, to: Int) { self.clipID = clipID; self.from = from; self.to = to }
    public func apply(to project: Project) throws {
        guard from != to else { throw EditError.invalid("effect is already there") }
        try Effects.editClip(project, clipID, &swap) { clip in
            let a = try Effects.slot(clip, from), b = try Effects.slot(clip, to)
            guard a.owner === b.owner, let list = a.owner["effects"]?.array else {
                throw EditError.invalid("effects can only be reordered among the same part")
            }
            let e = list.items.remove(at: a.index)
            list.items.insert(e, at: b.index)
        }
    }
    public func revert(on project: Project) throws { try swap.restore(in: project) }
}

/// Sets an effect parameter: constant, or a keyframe at clip media time
/// `keyframeAt` (same rules as `SetParameter`).
@MainActor public final class SetEffectParameter: EditCommand {
    public let name = "Change Effect"
    public let clipID: Int64
    public let effectIndex: Int
    public let parameter: String
    public let value: Double
    public let keyframeAt: Int64?
    private var swap = TrackSwap()
    public init(clipID: Int64, effectIndex: Int, parameter: String, value: Double, keyframeAt: Int64? = nil) {
        self.clipID = clipID; self.effectIndex = effectIndex; self.parameter = parameter
        self.value = value; self.keyframeAt = keyframeAt
    }
    public func apply(to project: Project) throws {
        guard value.isFinite, !parameter.isEmpty else { throw EditError.invalid("bad parameter or value") }
        let grid = FrameGrid(project)
        try Effects.editClip(project, clipID, &swap) { clip in
            let (owner, i) = try Effects.slot(clip, effectIndex)
            guard let effect = owner["effects"]?.array?[i].object else { throw EditError.invalid("bad effect") }
            if effect["parameters"]?.object == nil { effect["parameters"] = J.emptyObject }
            guard let params = effect["parameters"]?.object else { throw EditError.invalid("no parameters") }
            if let at = keyframeAt {
                let m = grid.nearest(at)
                guard m >= 0 else { throw EditError.invalid("keyframe time must be ≥ 0") }
                let visible = Retime.isStill(owner)
                    ? owner["trimStartSum"]?.int ?? 0
                    : Exact.floor(Rational(owner["mediaStart"]) ?? Rational(0))
                ParamWriter.setKeyframe(params, parameter, value, at: m, visibleStart: visible)
            } else {
                Self.recordPluginDefault(clip, effect, params, parameter, value)
                ParamWriter.setConstant(params, parameter, value)
            }
            AnimationSync.sync(owner)
        }
    }
    public func revert(on project: Project) throws { try swap.restore(in: project) }

    /// Changing a plug-in effect's bare-number parameter (`VSTEffect-*`, e.g. AI Noise Removal's
    /// `Amount`) records the value before the change in the clip's `metadata` as the string
    /// `default-<effectName>-<parameter>` [obs, audio.md §3.3]. An existing record is kept: it
    /// names the default, so later changes don't overwrite it [inf]. The effect's opaque
    /// `metadata.ExtandableEffectData` is never touched.
    static func recordPluginDefault(_ clip: JSONObject, _ effect: JSONObject, _ params: JSONObject,
                                    _ parameter: String, _ value: Double) {
        guard let ename = effect["effectName"]?.string, ename.hasPrefix("VSTEffect-"),
              let old = params[parameter]?.number, old.double != value,
              let md = clip["metadata"]?.object else { return }
        let key = "default-\(ename)-\(parameter)"
        if md[key] == nil { md[key] = .string(old.lexeme) }
    }
}

/// Turns an effect on or off (`bypassed`).
@MainActor public final class SetEffectBypassed: EditCommand {
    public let name = "Toggle Effect"
    public let clipID: Int64
    public let effectIndex: Int
    public let bypassed: Bool
    private var swap = TrackSwap()
    public init(clipID: Int64, effectIndex: Int, bypassed: Bool) {
        self.clipID = clipID; self.effectIndex = effectIndex; self.bypassed = bypassed
    }
    public func apply(to project: Project) throws {
        try Effects.editClip(project, clipID, &swap) { clip in
            let (owner, i) = try Effects.slot(clip, effectIndex)
            guard let effect = owner["effects"]?.array?[i].object else { throw EditError.invalid("bad effect") }
            effect["bypassed"] = .bool(bypassed)
        }
    }
    public func revert(on project: Project) throws { try swap.restore(in: project) }
}
