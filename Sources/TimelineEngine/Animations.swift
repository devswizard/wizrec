import Foundation
import TSCProjKit

// Menu animations (animation.md §1–§2): one 1 s keyframe segment that ends at
// the playhead, on the clip's keyframe (media) time axis.
//
// Rules:
// - Segment: `endTime` = the playhead's media time (time-mapping.md §6;
//   stills: time since the untrimmed start, `trimStartSum` + offset, §3),
//   snapped to the frame grid; `time` = `endTime` − 1 s; negative `time` is
//   legal [obs]. With a Clip Speed (scalar ≠ 1) the 1 s is measured on the
//   media axis [WizRec].
// - Keyframe keys `endTime, time, value, duration`, no `interp`; a new
//   parameter is `{type, defaultValue, keyframes}` with no `interp` [obs]. A
//   parameter that already has the long form keeps its keys (an existing
//   `interp` stays) [WizRec]; a bare number becomes the long form in place.
// - The segment starts from the parameter's constant (`defaultValue`) [obs];
//   Full Opacity sets that start to 0 [obs] unless the parameter already has
//   keyframes [WizRec]. A keyframe already ending at the same time gets the
//   new value; others are kept, the new one inserted in time order [WizRec].
// - One `animationTracks.visual` entry `{endTime, duration}` for the segment,
//   shared by every parameter of the preset; Custom adds only that entry [obs].
// - UnifiedMedia: written to its `video` part (as `SetParameter`). Clips with
//   no picture (audio, an audio-only UnifiedMedia) are rejected.

/// A *Modify ▸ Add Animation* preset (animation.md §2). End values are for the
/// 1 s segment; scales are factors, translations canvas px, rotations radians.
public enum AnimationPreset: String, Sendable, CaseIterable {
    /// No parameter change: an empty animation (one `animationTracks` entry) to edit later.
    case custom
    /// `opacity` → 0.
    case noOpacity
    /// `opacity` 0 → 1.
    case fullOpacity
    /// `scale0`/`scale1` → 1.25.
    case scaleUp
    /// `scale0`/`scale1` → 0.75.
    case scaleDown
    /// `scale0`/`scale1` → canvas height / media height (fits the height) [obs].
    case scaleToFit
    /// `translation0` → −canvas width / 4, `rotation1` → +π/6, scale → 0.5 [obs on 1920 px].
    case tiltLeft
    /// `translation0` → +canvas width / 4, `rotation1` → −π/6, scale → half the
    /// canvas width / media width (2.4 for a 400 px still on 1920 [obs]; the
    /// formula is [WizRec], 0.5 when the media has no size).
    case tiltRight

    /// Menu label in WizRec's words.
    public var displayName: String {
        switch self {
        case .custom: "Custom"
        case .noOpacity: "No Opacity"
        case .fullOpacity: "Full Opacity"
        case .scaleUp: "Scale Up"
        case .scaleDown: "Scale Down"
        case .scaleToFit: "Scale to Fit"
        case .tiltLeft: "Tilt Left"
        case .tiltRight: "Tilt Right"
        }
    }
}

/// Adds a menu animation to a clip: a 1 s keyframe segment ending at
/// `playhead` (project ticks), animation.md §1–§2. One undo step.
/// `clipID` may be any clip with a picture, also inside a group.
@MainActor public final class AddAnimation: EditCommand {
    public let name = "Add Animation"
    public let clipID: Int64
    public let preset: AnimationPreset
    /// Project-timeline ticks.
    public let playhead: Int64
    public init(clipID: Int64, preset: AnimationPreset, at playhead: Int64) {
        self.clipID = clipID; self.preset = preset; self.playhead = playhead
    }

    /// True when `preset` can be added to clip `clipID` (exists, has a picture;
    /// Scale to Fit also needs a media size). For enabling drops and menu items.
    public static func canApply(_ preset: AnimationPreset, clipID: Int64, in project: Project) -> Bool {
        guard let loc = try? Locator.locate(clipID, in: project) else { return false }
        return (try? MenuAnimation.targets(preset, clip: loc.clip, project: project)) != nil
    }

    var swap = TrackSwap()
    public func apply(to project: Project) throws { try MenuAnimation.apply(self, project) }
    public func revert(on project: Project) throws { try swap.restore(in: project) }
}

@MainActor
enum MenuAnimation {
    /// `(parameter, start value or nil to keep, end value)` per animated parameter.
    typealias Target = (name: String, from: Double?, to: Double)

    static func apply(_ c: AddAnimation, _ project: Project) throws {
        let loc = try Locator.locate(c.clipID, in: project)
        var edits = TrackEdits(project)
        let track = try edits.track(at: loc.trackPath)
        guard let clip = track["medias"]?.array?[loc.index].object else { throw EditError.clipNotFound(c.clipID) }
        let targets = try Self.targets(c.preset, clip: clip, project: project)
        guard let owner = GroupGeometry.owner(clip) else { throw EditError.invalid("clip has no picture") }
        let end = try endTime(clip: clip, owner: owner, trackPath: loc.trackPath, playhead: c.playhead, project: project)
        let window = AnimationSync.Window(time: end - project.timebase.editRate, endTime: end)
        var written: [AnimationSync.Window] = targets.isEmpty ? [window] : []
        if !targets.isEmpty {
            if owner["parameters"]?.object == nil { owner["parameters"] = J.emptyObject }
            guard let params = owner["parameters"]?.object else { throw EditError.invalid("no parameters") }
            for t in targets { written.append(addSegment(params, t, window)) }
        }
        AnimationSync.addEntries(owner, for: Array(Set(written)))
        try edits.commit(&c.swap)
    }

    /// The parameters `preset` animates on `clip`; throws when it can't be applied.
    static func targets(_ preset: AnimationPreset, clip: JSONObject, project: Project) throws -> [Target] {
        guard hasPicture(clip) else { throw EditError.invalid("clip \(clip.clipID ?? -1) has no picture") }
        let size = GroupGeometry.naturalSize(clip, project)
        func scale(_ v: Double) -> [Target] { [("scale0", nil, v), ("scale1", nil, v)] }
        switch preset {
        case .custom: return []
        case .noOpacity: return [("opacity", nil, 0)]
        case .fullOpacity: return [("opacity", 0, 1)]
        case .scaleUp: return scale(1.25)
        case .scaleDown: return scale(0.75)
        case .scaleToFit:
            guard let h = size?.h, h > 0, project.height > 0 else { throw EditError.invalid("media has no size") }
            return scale(project.height / h)
        case .tiltLeft:
            return [("translation0", nil, -project.width / 4), ("rotation1", nil, Double.pi / 6)] + scale(0.5)
        case .tiltRight:
            let w = size?.w ?? 0
            let s = w > 0 && project.width > 0 ? project.width / 2 / w : 0.5
            return [("translation0", nil, project.width / 4), ("rotation1", nil, -Double.pi / 6)] + scale(s)
        }
    }

    static func hasPicture(_ clip: JSONObject) -> Bool {
        switch clip.clipType {
        case "AMFile": false
        case "UnifiedMedia": clip["video"]?.object != nil
        default: true
        }
    }

    /// Keyframe-axis time of `playhead` on `clip`, snapped to the frame grid.
    static func endTime(clip: JSONObject, owner: JSONObject, trackPath: JSONPath, playhead: Int64,
                        project: Project) throws -> Int64 {
        // Map the project time into the time axis of the clip's track (through enclosing groups).
        var t = Rational(playhead)
        for path in GroupChain.enclosingClipPaths(trackPath) {
            guard let g = path.resolve(in: project.root)?.object else { throw EditError.invalid("group not found") }
            let tm = try Timing(g)
            t = try Exact.add(tm.mediaStart, Exact.div(Exact.sub(t, Rational(tm.start)), tm.scalar))
        }
        let tm = try Timing(clip)
        let offset = try Exact.sub(t, Rational(tm.start))
        let media: Rational
        if Retime.isStill(owner) {
            media = try Exact.add(Rational(owner["trimStartSum"]?.int ?? 0), offset)
        } else {
            media = try Exact.add(tm.mediaStart, Exact.div(offset, tm.scalar))
        }
        return FrameGrid(project).nearest(Exact.floor(media))
    }

    /// Adds the segment for one parameter; returns the keyframe window written
    /// (an existing keyframe ending at the same time keeps its own start).
    @discardableResult
    static func addSegment(_ params: JSONObject, _ t: Target, _ w: AnimationSync.Window) -> AnimationSync.Window {
        let kf = JSONObject([
            ("endTime", J.int(w.endTime)), ("time", J.int(w.time)), ("value", J.dbl(t.to)),
            ("duration", J.int(w.endTime - w.time)),
        ])
        let o: JSONObject
        if let existing = params[t.name]?.object {
            o = existing
        } else {
            let base = params[t.name]?.double ?? ParamWriter.defaultValue(t.name)
            o = JSONObject([("type", .string("double")), ("defaultValue", J.dbl(base))])
            params[t.name] = .object(o)
        }
        let kfs = o["keyframes"]?.array?.items ?? []
        if kfs.isEmpty, let from = t.from { o["defaultValue"] = J.dbl(from) }
        func end(_ v: JSON) -> Int64 { v.object?["endTime"]?.int ?? v.object?["time"]?.int ?? 0 }
        var items = kfs
        var written = w
        if let same = items.firstIndex(where: { end($0) == w.endTime }), let k = items[same].object {
            let copy = k.copy()
            copy["value"] = J.dbl(t.to)
            items[same] = .object(copy)
            written.time = k["time"]?.int ?? w.time
        } else {
            let at = items.firstIndex { end($0) > w.endTime } ?? items.count
            items.insert(.object(kf), at: at)
        }
        o["keyframes"] = J.arr(items)
        return written
    }
}
