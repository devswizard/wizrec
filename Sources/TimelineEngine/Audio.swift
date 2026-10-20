import Foundation
import TSCProjKit

// Audio edits as Camtasia 2026.2.3 writes them (docs/specs/audio.md §3–§4, AU1 runtime saves):
// the Audio Effects panel items, fades and audio points as volume keyframes, and measured
// source loudness.

/// The Audio Effects panel of Camtasia 2026.2.3, in panel order (audio.md §3.1) [obs]. There is
/// no classic Noise Removal and no Volume Leveling item; older projects that carry such effects
/// keep them untouched.
public enum AudioPanelItem: String, CaseIterable, Sendable {
    case aiNoiseRemoval, audioCompression, captions, clipSpeed, emphasize, fadeIn, fadeOut, pitch

    /// Panel label.
    public var displayName: String {
        switch self {
        case .aiNoiseRemoval: "AI Noise Removal"
        case .audioCompression: "Audio Compression"
        case .captions: "Captions"
        case .clipSpeed: "Clip Speed"
        case .emphasize: "Emphasize"
        case .fadeIn: "Fade In"
        case .fadeOut: "Fade Out"
        case .pitch: "Pitch"
        }
    }

    /// The `effectName` the item writes, or nil when it writes no effect entry (Clip Speed and
    /// fades change metadata or volume keyframes; Captions is a caption track) [obs, AU1].
    public var effectName: String? {
        switch self {
        case .aiNoiseRemoval: "VSTEffect-DFN3NoiseRemoval"
        case .audioCompression: "WinCompression"
        case .emphasize: "Emphasize"
        case .pitch: "Pitch"
        case .captions, .clipSpeed, .fadeIn, .fadeOut: nil
        }
    }

    /// The effect entry with Camtasia's defaults, in the observed shape: `effectName`, `bypassed`
    /// false, `category` "categoryAudioEffects", `parameters` as plain numbers (integers where
    /// Camtasia writes integers), no `start`/`duration` [obs, AU1]. Ramp times are ticks at
    /// `editRate` (1 s). AI Noise Removal gets no `metadata.ExtandableEffectData`: that is the
    /// vendor plug-in's opaque state, which WizRec never writes (an existing one is preserved).
    public func effectJSON(editRate: Int64 = 705_600_000) -> JSONObject? {
        guard let name = effectName else { return nil }
        let params: [(String, JSON)]
        switch self {
        case .aiNoiseRemoval:
            params = [("Amount", J.dbl(0.8)), ("Bypass", J.dbl(0))]
        case .audioCompression:
            params = [("ratio", J.dbl(10)), ("threshold", J.dbl(-20)), ("gain", J.dbl(9)), ("attack", J.dbl(0)),
                      ("release", J.dbl(3500)), ("preset", J.int(1))]
        case .emphasize:
            params = [("emphasizeAmount", J.dbl(0.8)), ("emphasizeRampPosition", J.int(0)),
                      ("emphasizeRampInTime", J.int(editRate)), ("emphasizeRampOutTime", J.int(editRate))]
        case .pitch:
            params = [("pitch", J.dbl(-200)), ("effectBlend", J.dbl(100)), ("smoothness", J.dbl(50)),
                      ("tightness", J.dbl(50))]
        default:
            return nil
        }
        return JSONObject([("effectName", .string(name)), ("bypassed", .bool(false)),
                           ("category", .string("categoryAudioEffects")), ("parameters", J.obj(params))])
    }
}

/// Applies an Audio Effects panel item to a clip the way the panel does (AU1):
/// - effect items add their default entry (`AudioPanelItem.effectJSON`) through `AddEffect`
///   (on a `UnifiedMedia` it goes to the parent) and set `metadata.effectApplied`;
/// - Clip Speed only sets `metadata.clipSpeedAttribute` true and `effectApplied` "Clip Speed"
///   (`scalar` is unchanged until a speed is set with `SetClipSpeed`);
/// - Fade In / Fade Out write volume points (`AudioFade`, 1 s).
/// Captions throws: captions are made by the Captions module.
@MainActor public final class ApplyAudioItem: EditCommand {
    public let clipID: Int64
    public let item: AudioPanelItem
    public var name: String { item.displayName }
    private var inner: (any EditCommand)?
    private var swap = TrackSwap()

    public init(clipID: Int64, item: AudioPanelItem) { self.clipID = clipID; self.item = item }

    public func apply(to project: Project) throws {
        switch item {
        case .captions:
            throw EditError.invalid("captions are not a clip effect")
        case .fadeIn, .fadeOut:
            let c = AudioFade(clipID: clipID, item == .fadeIn ? .fadeIn : .fadeOut)
            try c.apply(to: project)
            inner = c
        case .clipSpeed:
            try Effects.editClip(project, clipID, &swap) { clip in
                guard let md = clip["metadata"]?.object else { throw EditError.invalid("clip \(self.clipID) has no metadata") }
                if let attr = md["clipSpeedAttribute"]?.object { attr["value"] = .bool(true) }
                else { md["clipSpeedAttribute"] = J.typedBool(true) }
                md["effectApplied"] = .string("Clip Speed")
            }
            inner = nil
        default:
            guard let e = item.effectJSON(editRate: project.timebase.editRate) else { throw EditError.invalid("no effect") }
            let c = AddEffect(clipID: clipID, effectJSON: String(decoding: JSON.object(e).serialized(), as: UTF8.self))
            try c.apply(to: project)
            inner = c
        }
    }

    public func revert(on project: Project) throws {
        if let inner { try inner.revert(on: project) } else { try swap.restore(in: project) }
    }
}

/// Fade In / Fade Out as volume points on the clip's audio (`parameters.volume`; the `audio`
/// child of a `UnifiedMedia`) [obs, AU1]. On a clip without volume keyframes and level v
/// (constant `volume`, default 1):
/// - Fade In writes `0` at the clip's first media time and `v` at `length` later;
/// - Fade Out writes `v` at the first media time, `v` at `length` before the end and `0` at the
///   end.
/// Each point is `{endTime, time, value, duration: 0}` with `endTime == time`, no `interp`, and
/// the parameter becomes `{type: "double", keyframes}` without `defaultValue`. Times are clip
/// media ticks (time-mapping.md §6); `length` is timeline time (1 s default), shortened to the
/// clip. With existing points, points inside the fade span are replaced and the level at the
/// span's inner edge is kept [WizRec].
@MainActor public final class AudioFade: EditCommand {
    public enum Kind: Sendable { case fadeIn, fadeOut }
    public let clipID: Int64
    public let kind: Kind
    /// Fade length in timeline ticks; nil = 1 s at the project's edit rate.
    public let length: Int64?
    public var name: String { kind == .fadeIn ? "Fade In" : "Fade Out" }
    private var swap = TrackSwap()

    public init(clipID: Int64, _ kind: Kind, length: Int64? = nil) {
        self.clipID = clipID; self.kind = kind; self.length = length
    }

    public func apply(to project: Project) throws {
        let len = length ?? project.timebase.editRate
        guard len > 0 else { throw EditError.invalid("fade length must be > 0") }
        try Effects.editClip(project, clipID, &swap) { clip in
            let (owner, t) = try VolumePoints.owner(clip)
            let m0 = Exact.floor(t.mediaStart)
            let mEnd = Exact.floor(try Exact.add(t.mediaStart, t.media(t.duration)))
            let span = min(Exact.floor(try t.media(len)), mEnd - m0)
            guard span > 0 else { throw EditError.invalid("clip \(self.clipID) is too short to fade") }
            var pts = VolumePoints.read(owner)
            let c = VolumePoints.constant(owner)
            switch self.kind {
            case .fadeIn:
                let level = VolumePoints.level(pts, at: m0 + span, constant: c)
                pts.removeAll { $0.time >= m0 && $0.time <= m0 + span }
                pts += [(m0, 0), (m0 + span, level)]
            case .fadeOut:
                let level = VolumePoints.level(pts, at: mEnd - span, constant: c)
                let hadPoints = !pts.isEmpty
                let startLevel = VolumePoints.level(pts, at: m0, constant: c)
                pts.removeAll { $0.time >= mEnd - span && $0.time <= mEnd }
                if !hadPoints && mEnd - span > m0 { pts.append((m0, startLevel)) }
                pts += [(mEnd - span, level), (mEnd, 0)]
            }
            VolumePoints.write(owner, pts)
        }
    }

    public func revert(on project: Project) throws { try swap.restore(in: project) }
}

/// Edit ▸ Add Audio Point at clip media time `at` (ticks; snapped to the frame grid) [obs, AU1]:
/// on a clip without volume keyframes it writes two points at the current level, one at the
/// clip's first media time and one at `at`; otherwise it adds one point at `at` with the level
/// the envelope has there (the sound does not change). Same point shape as `AudioFade`. A point
/// already at `at` is an error.
@MainActor public final class AddAudioPoint: EditCommand {
    public let name = "Add Audio Point"
    public let clipID: Int64
    public let at: Int64
    private var swap = TrackSwap()

    public init(clipID: Int64, at mediaTime: Int64) { self.clipID = clipID; self.at = mediaTime }

    public func apply(to project: Project) throws {
        let m = FrameGrid(project).nearest(at)
        try Effects.editClip(project, clipID, &swap) { clip in
            let (owner, t) = try VolumePoints.owner(clip)
            let m0 = Exact.floor(t.mediaStart)
            let mEnd = Exact.floor(try Exact.add(t.mediaStart, t.media(t.duration)))
            guard m >= m0, m <= mEnd else { throw EditError.invalid("audio point outside clip \(self.clipID)") }
            var pts = VolumePoints.read(owner)
            guard !pts.contains(where: { $0.time == m }) else { throw EditError.invalid("a point exists at \(m)") }
            let level = VolumePoints.level(pts, at: m, constant: VolumePoints.constant(owner))
            if pts.isEmpty, m != m0 { pts.append((m0, level)) }
            pts.append((m, level))
            VolumePoints.write(owner, pts)
        }
    }

    public func revert(on project: Project) throws { try swap.restore(in: project) }
}

/// Stores a measured loudness on `sourceBin[id].sourceTracks[track]` (`integratedLUFS`, LUFS;
/// `peakLevel`, linear), e.g. from AudioEngine's `SourceLoudness`, which measures the way
/// Camtasia does (audio.md §2.1). Silence (−∞) is written as `-Infinity` [obs].
@MainActor public final class SetSourceLoudness: EditCommand {
    public let name = "Measure Loudness"
    public let sourceID: Int64
    public let track: Int
    public let integratedLUFS: Double
    public let peakLevel: Double
    private var swap = ValueSwap()

    public init(sourceID: Int64, track: Int, integratedLUFS: Double, peakLevel: Double) {
        self.sourceID = sourceID; self.track = track; self.integratedLUFS = integratedLUFS; self.peakLevel = peakLevel
    }

    public func apply(to project: Project) throws {
        guard !integratedLUFS.isNaN, integratedLUFS < .infinity, peakLevel.isFinite, peakLevel >= 0 else {
            throw EditError.invalid("loudness must be a number (LUFS may be −∞) and peak ≥ 0")
        }
        let items = project.root["sourceBin"]?.array?.items ?? []
        guard let i = items.firstIndex(where: { $0.object?["id"]?.int == sourceID }) else {
            throw EditError.invalid("source \(sourceID) not found")
        }
        let path = JSONPath(steps: [.key("sourceBin"), .index(i), .key("sourceTracks"), .index(track)])
        guard let old = path.resolve(in: project.root)?.object else {
            throw EditError.invalid("source \(sourceID) has no track \(track)")
        }
        let st = old.copy()
        st["integratedLUFS"] = .number(integratedLUFS.isFinite ? JSONNumber(integratedLUFS) : JSONNumber(lexeme: "-Infinity"))
        st["peakLevel"] = .number(JSONNumber(peakLevel))
        try swap.commit([(path: path, new: .object(st))], in: project)
    }

    public func revert(on project: Project) throws { try swap.restore(in: project) }
}

/// Reading and writing `parameters.volume` as a point list (audio.md §4).
@MainActor enum VolumePoints {
    typealias Point = (time: Int64, value: Double)

    /// The object holding the clip's volume and its timing. Throws for clips without audio.
    static func owner(_ clip: JSONObject) throws -> (JSONObject, Timing) {
        guard !["IMFile", "Callout", "VMFile", "ScreenVMFile"].contains(clip.clipType) else {
            throw EditError.invalid("clip \(clip.clipID ?? -1) has no audio")
        }
        let owner = try M2.parameterOwner(clip, "volume")
        return (owner, try Timing(owner))
    }

    /// Existing keyframes as points (a window keyframe counts at its `endTime`, where it reaches
    /// its value), sorted; empty for a constant or missing volume.
    static func read(_ owner: JSONObject) -> [Point] {
        guard let kfs = owner["parameters"]?.object?["volume"]?.object?["keyframes"]?.array?.items else { return [] }
        return kfs.compactMap(\.object).compactMap { k -> Point? in
            guard let v = k["value"]?.double, let t = k["endTime"]?.int ?? k["time"]?.int else { return nil }
            return (t, v)
        }.sorted { $0.time < $1.time }
    }

    /// The level at media time `m`: linear between points, held outside them [inf]; the constant
    /// volume `constant` when there are no points.
    static func level(_ pts: [Point], at m: Int64, constant: Double) -> Double {
        guard let first = pts.first, let last = pts.last else { return constant }
        if m <= first.time { return first.value }
        if m >= last.time { return last.value }
        for i in 1..<pts.count where m < pts[i].time {
            let a = pts[i - 1], b = pts[i]
            return a.value + (b.value - a.value) * Double(m - a.time) / Double(b.time - a.time)
        }
        return last.value
    }

    /// Writes `pts` (sorted, later duplicates win) as the volume keyframes, keeping the key's
    /// position, and syncs `animationTracks`.
    static func write(_ owner: JSONObject, _ pts: [Point]) {
        if owner["parameters"]?.object == nil { owner["parameters"] = J.emptyObject }
        guard let params = owner["parameters"]?.object else { return }
        var byTime: [Int64: Double] = [:]
        for p in pts { byTime[p.time] = p.value }
        let kfs = byTime.keys.sorted().map { t in
            J.obj([("endTime", J.int(t)), ("time", J.int(t)), ("value", J.dbl(byTime[t] ?? 1)), ("duration", J.int(0))])
        }
        params["volume"] = J.obj([("type", .string("double")), ("keyframes", J.arr(kfs))])
        AnimationSync.sync(owner)
    }

    /// The current constant volume of `owner` (bare number or `defaultValue`), default 1.
    static func constant(_ owner: JSONObject) -> Double {
        guard let v = owner["parameters"]?.object?["volume"] else { return 1 }
        return v.double ?? v.object?["defaultValue"]?.double ?? 1
    }
}
