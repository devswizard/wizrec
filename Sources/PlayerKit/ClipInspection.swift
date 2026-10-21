import CoreGraphics
import Foundation
import RenderEngine
import TSCProjKit

/// Inspector fields of a clip, with the parameter keys they edit.
public enum InspectorField: String, CaseIterable, Sendable {
    case positionX, positionY, scale, rotation, cropLeft, cropTop, cropRight, cropBottom, opacity, volume
    /// One axis of the scale (canvas handles with Shift: free scale, ui-workflow.md §8.1).
    case scaleX, scaleY

    /// Parameter keys written by this field (scale writes both axes).
    public var keys: [String] {
        switch self {
        case .positionX: ["translation0"]
        case .positionY: ["translation1"]
        case .scale: ["scale0", "scale1"]
        case .scaleX: ["scale0"]
        case .scaleY: ["scale1"]
        case .rotation: ["rotation2"]
        case .cropLeft: ["geometryCrop0"]
        case .cropTop: ["geometryCrop1"]
        case .cropRight: ["geometryCrop2"]
        case .cropBottom: ["geometryCrop3"]
        case .opacity: ["opacity"]
        case .volume: ["volume"]
        }
    }

    /// Camtasia default when the key is absent (`docs/specs/defaults.md`).
    public var defaultValue: Double {
        switch self {
        case .scale, .scaleX, .scaleY, .opacity, .volume: 1
        default: 0
        }
    }

    /// True for fields on the audio-bearing clip rather than the visual one.
    public var isAudio: Bool { self == .volume }
}

/// What the inspector shows for one selected clip, evaluated at the playhead.
///
/// Values are in project units: translation in canvas px (+y up), rotation in radians,
/// crop as fractions, opacity/volume/scale as factors.
public struct ClipInspection: Equatable, Sendable {
    /// The selected clip (top-level or nested).
    public var clipID: Int64
    public var typeName: String
    public var name: String
    /// Timeline position, ticks (parent timeline for nested clips).
    public var start: Int64
    public var duration: Int64
    /// Playback speed (1 / `scalar`).
    public var speed: Double
    /// Clip id that geometry edits target (the `UnifiedMedia` itself, which TimelineEngine routes to
    /// its `video` part); nil for audio-only clips.
    public var visualClipID: Int64?
    /// Clip id that volume edits target (a `UnifiedMedia` routes to its `audio` part); nil for silent clips.
    public var audioClipID: Int64?
    /// Field values at the playhead.
    public var values: [InspectorField: Double]
    /// Fields with keyframes (edits then set a keyframe at `keyframeTime`).
    public var animated: Set<InspectorField>
    /// Clip media time at the playhead (ticks), for keyframe edits; nil when the playhead
    /// is outside the clip or the clip is nested.
    public var keyframeTime: Int64?
    /// Effect names in order, with `bypassed`.
    public var effects: [(name: String, bypassed: Bool)]
    /// `attributes.gain` of the audio clip (linear), when present.
    public var gain: Double?
    /// The clip's shader background parameters (`sourceEffect`), when it plays a `.tscshadervid`.
    public var shader: ShaderInspection?

    public static func == (a: ClipInspection, b: ClipInspection) -> Bool {
        a.clipID == b.clipID && a.typeName == b.typeName && a.name == b.name && a.start == b.start
            && a.duration == b.duration && a.speed == b.speed && a.visualClipID == b.visualClipID
            && a.audioClipID == b.audioClipID && a.values == b.values && a.animated == b.animated
            && a.keyframeTime == b.keyframeTime && a.gain == b.gain && a.shader == b.shader
            && a.effects.map(\.name) == b.effects.map(\.name) && a.effects.map(\.bypassed) == b.effects.map(\.bypassed)
    }

    /// The inspection of clip `clipID` anywhere in `project`, at timeline time `playhead` (ticks).
    @MainActor
    public static func make(project: Project, clipID: Int64, playhead: Int64) -> ClipInspection? {
        var found: (clip: Clip, topLevel: Bool)?
        for track in project.tracks {
            for c in track.clips {
                if c.id == clipID { found = (c, true); break }
                c.walk { inner, depth in
                    if depth > 0, inner.id == clipID, found == nil { found = (inner, false) }
                }
            }
            if found != nil { break }
        }
        guard let (clip, topLevel) = found else { return nil }

        let visual: Clip?
        let audio: Clip?
        switch clip.kind {
        case .unified:
            visual = clip.video; audio = clip.audio
        default:
            let t = clip.kind.typeName
            visual = t == "AMFile" ? nil : clip
            audio = ["AMFile", "StitchedMedia", "Group"].contains(t) ? clip : nil
        }
        var keyframeTime: Int64?
        if topLevel, clip.contains(playhead) {
            keyframeTime = Self.round(clip.mediaTime(atTimeline: playhead))
        }
        let t = keyframeTime ?? Self.round(clip.mediaStart)
        var values: [InspectorField: Double] = [:]
        var animated: Set<InspectorField> = []
        for f in InspectorField.allCases {
            guard let owner = f.isAudio ? audio : visual, let key = f.keys.first else { continue }
            let params = owner.parameters
            values[f] = params.value(key, at: t, default: f.defaultValue)
            if f.keys.contains(where: { params[$0]?.isAnimated ?? false }) { animated.insert(f) }
        }
        let scalar = clip.scalar
        return ClipInspection(
            clipID: clip.id, typeName: clip.kind.typeName, name: clip.name ?? "",
            start: clip.start, duration: clip.duration,
            speed: scalar.num != 0 ? scalar.double == 0 ? 1 : 1 / scalar.double : 1,
            // SetParameter routes a UnifiedMedia id to its video part (volume to its audio part).
            visualClipID: visual.map { _ in clip.kind == .unified ? clip.id : visual?.id ?? clip.id },
            audioClipID: audio.map { _ in clip.kind == .unified ? clip.id : audio?.id ?? clip.id }, values: values, animated: animated,
            keyframeTime: keyframeTime, effects: (visual ?? clip).effects.filter { !$0.isPlaceholder }.map { ($0.name, $0.bypassed) },
            gain: audio?.attributes?["gain"]?.double,
            shader: clip.kind.typeName == "VMFile"
                ? ShaderInspection.make(clip: clip, source: clip.sourceID.flatMap { project.source(id: $0) },
                                        at: t, keyframeTime: keyframeTime)
                : nil)
    }

    /// Parameter changes that set `field` to `value` (keyframe at the playhead when animated).
    public func changes(_ field: InspectorField, _ value: Double) -> [EditorDocumentModel.ParameterChange] {
        guard let target = field.isAudio ? audioClipID : visualClipID else { return [] }
        let kf = animated.contains(field) ? keyframeTime : nil
        return field.keys.map { EditorDocumentModel.ParameterChange(clipID: target, $0, value, keyframeAt: kf) }
    }

    private static func round(_ r: Rational) -> Int64 {
        guard r.den != 0 else { return 0 }
        let q = Double(r.num) / Double(r.den)
        return Int64(q.rounded())
    }
}

/// Canvas hit testing: which top-level clip is drawn under a point.
public enum CanvasHitTest {
    /// Top-level clip id of the topmost layer containing `point` (canvas px, origin at the
    /// canvas centre, +y up). Crops are honoured; effects are not.
    @MainActor
    public static func clip(at point: CGPoint, plan: RenderPlan, project: Project) -> Int64? {
        for layer in plan.layers.reversed() where contains(layer, point) {
            return topLevelClip(forLayer: layer.clipID, in: project) ?? layer.clipID
        }
        return nil
    }

    /// True when `point` (parent px) lies inside the layer's cropped rectangle.
    public static func contains(_ layer: Layer, _ point: CGPoint) -> Bool {
        guard layer.size.width > 0, layer.size.height > 0, layer.opacity > 0 else { return false }
        let local = point.applying(layer.transform.inverted())
        let w = layer.size.width, h = layer.size.height
        let c = layer.geometryCrop
        let minX = -w / 2 + c.left * w, maxX = w / 2 - c.right * w
        let minY = -h / 2 + c.bottom * h, maxY = h / 2 - c.top * h
        return local.x >= minX && local.x <= maxX && local.y >= minY && local.y <= maxY
    }

    /// The top-level clip that draws layer `id` (the clip itself, or the `UnifiedMedia` owning it).
    @MainActor
    public static func topLevelClip(forLayer id: Int64, in project: Project) -> Int64? {
        for track in project.tracks {
            for c in track.clips where c.id == id || c.video?.id == id { return c.id }
        }
        return nil
    }

    /// Converts a point in a view showing the canvas aspect-fit (origin top-left, +y down)
    /// to canvas px (origin centre, +y up). Nil outside the letterboxed canvas.
    public static func canvasPoint(_ p: CGPoint, viewSize: CGSize, canvasSize: CGSize) -> CGPoint? {
        guard canvasSize.width > 0, canvasSize.height > 0, viewSize.width > 0, viewSize.height > 0 else { return nil }
        let s = min(viewSize.width / canvasSize.width, viewSize.height / canvasSize.height)
        let x = (p.x - viewSize.width / 2) / s, y = (viewSize.height / 2 - p.y) / s
        guard abs(x) <= canvasSize.width / 2, abs(y) <= canvasSize.height / 2 else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// View points per canvas pixel for an aspect-fit canvas.
    public static func scale(viewSize: CGSize, canvasSize: CGSize) -> Double {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return 1 }
        return min(viewSize.width / canvasSize.width, viewSize.height / canvasSize.height)
    }
}
