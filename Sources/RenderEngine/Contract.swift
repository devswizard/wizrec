// Public interface of RenderEngine, frozen by coordination/CONTRACTS.md.
// Changing anything here needs an API_CHANGE message and the lead's approval.

import CoreGraphics
import CoreMedia
import Foundation
import MediaEngine
import Metal
import TSCProjKit

/// Straight-alpha colour, components 0–1.
public struct RGBA: Sendable, Equatable {
    public var r, g, b, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
}

/// Crop amounts as fractions of the frame (0 = none), per edge.
public struct Insets: Sendable, Equatable {
    public var left, top, right, bottom: Double
    public init(left: Double = 0, top: Double = 0, right: Double = 0, bottom: Double = 0) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }
    public static let zero = Insets()
}

/// An effect with its parameters evaluated at the plan time.
/// The compositor draws the ones in `Compositor.renderedEffects` (unless bypassed); others pass through.
/// Effects with a `start`/`duration` window are left out of `Layer.effects` outside it.
public struct EffectInstance: Sendable, Equatable {
    public var name: String
    public var parameters: [String: Double]
    public var bypassed: Bool
    public init(name: String, parameters: [String: Double], bypassed: Bool) {
        self.name = name; self.parameters = parameters; self.bypassed = bypassed
    }
}

/// What a layer draws.
public enum LayerContent: Sendable, Equatable {
    /// A video frame; the request's `time` is the resolved stream time.
    case video(FrameRequest)
    /// A still image file.
    case image(URL)
    /// A `.tscshadervid` background; parameters from the clip's `sourceEffect`, evaluated.
    /// `time`: shader time in seconds (the clip's inner time / editRate).
    case shader(URL, parameters: [String: Double], time: Double)
    /// A group's children, bottom to top, in the group's own coordinate space.
    case group([Layer])
    /// A transition in progress on one track. `from` is the outgoing clip, `to` the incoming one, both in
    /// the parent's coordinate space; `nil` on one side = a fade in or out at a clip edge.
    /// The carrying layer has the parent's size and an identity transform.
    indirect case transition(TransitionInstance, from: Layer?, to: Layer?)
    /// A callout (annotation) evaluated at the plan time (`docs/specs/callouts.md`).
    case callout(CalloutContent)
    /// A clip type the engine does not draw.
    case unsupported(type: String)
}

/// One rich-text run of a callout: attributes for UTF-16 range `range` of `CalloutContent.text`.
/// Nil fields inherit the callout's base font.
public struct CalloutTextRun: Sendable, Equatable {
    public var range: Range<Int>
    public var fontName: String?
    /// Points = callout px at scale 1.
    public var fontSize: Double?
    /// CSS-style weight, 100–900.
    public var fontWeight: Int?
    public var italic: Bool?
    public var underline: Bool?
    public var strikethrough: Bool?
    public var color: RGBA?
    /// Extra letter spacing, points.
    public var kerning: Double?

    public init(range: Range<Int>, fontName: String? = nil, fontSize: Double? = nil, fontWeight: Int? = nil,
                italic: Bool? = nil, underline: Bool? = nil, strikethrough: Bool? = nil, color: RGBA? = nil,
                kerning: Double? = nil) {
        self.range = range; self.fontName = fontName; self.fontSize = fontSize; self.fontWeight = fontWeight
        self.italic = italic; self.underline = underline; self.strikethrough = strikethrough; self.color = color
        self.kerning = kerning
    }
}

/// A callout's `def`, evaluated. Units: callout px (= layer px), origin at the box centre, +y up.
public struct CalloutContent: Sendable, Equatable {
    /// `remix`, `TypeWinBlur`, `TypeWinPixelate`, `TypeWinHighlighter`, `TypeWinSpotlight`, …
    public var kind: String
    /// Geometry id for `remix`, e.g. `shape-rectangle`, `speech-bubble2`, `arrow`, `text`.
    public var shape: String
    public var style: String
    /// Box size, callout px.
    public var size: CGSize
    public var fill: RGBA
    public var stroke: RGBA
    public var strokeWidth: Double
    /// `solid`, `dash`, `dot`, `dashdot`, `dashdotdot`.
    public var strokeStyle: String
    public var cornerRadius: Double
    /// Tail tip (bubbles, text arrows) or arrow end, relative to the box centre, +y up.
    public var tail: CGPoint
    /// Arrow end caps: `shape-anchor` and `shape-tail`.
    public var anchorCap: String
    public var tailCap: String
    public var text: String
    public var runs: [CalloutTextRun]
    public var fontName: String
    public var fontWeight: String
    /// Base size, points; runs' `fontSize` overrides it.
    public var fontSize: Double
    public var textColor: RGBA
    /// `left`, `center`, `right`.
    public var horizontalAlignment: String
    /// `top`, `center`, `bottom`.
    public var verticalAlignment: String
    public var wordWrap: Bool
    public var lineSpacing: Double
    public var tracking: Double
    public var textStrokeWidth: Double
    public var textStrokeColor: RGBA
    /// Region kinds: strength (blur, pixelate, spotlight), 0–1.
    public var intensity: Double
    /// Region kinds: `blur-invert` / `fill-invert`.
    public var invert: Bool

    public init(kind: String = "remix", shape: String = "shape-rectangle", style: String = "",
                size: CGSize, fill: RGBA = RGBA(1, 1, 1, 1), stroke: RGBA = RGBA(0, 0, 0, 1),
                strokeWidth: Double = 0, strokeStyle: String = "solid", cornerRadius: Double = 0,
                tail: CGPoint = .zero, anchorCap: String = "none", tailCap: String = "arrow",
                text: String = "", runs: [CalloutTextRun] = [], fontName: String = "Helvetica",
                fontWeight: String = "Regular", fontSize: Double = 64, textColor: RGBA = RGBA(0, 0, 0, 1),
                horizontalAlignment: String = "center", verticalAlignment: String = "center",
                wordWrap: Bool = true, lineSpacing: Double = 0, tracking: Double = 0,
                textStrokeWidth: Double = 0, textStrokeColor: RGBA = RGBA(0, 0, 0, 1),
                intensity: Double = 0.5, invert: Bool = false) {
        self.kind = kind; self.shape = shape; self.style = style; self.size = size; self.fill = fill
        self.stroke = stroke; self.strokeWidth = strokeWidth; self.strokeStyle = strokeStyle
        self.cornerRadius = cornerRadius; self.tail = tail; self.anchorCap = anchorCap; self.tailCap = tailCap
        self.text = text; self.runs = runs; self.fontName = fontName; self.fontWeight = fontWeight
        self.fontSize = fontSize; self.textColor = textColor; self.horizontalAlignment = horizontalAlignment
        self.verticalAlignment = verticalAlignment; self.wordWrap = wordWrap; self.lineSpacing = lineSpacing
        self.tracking = tracking; self.textStrokeWidth = textStrokeWidth; self.textStrokeColor = textStrokeColor
        self.intensity = intensity; self.invert = invert
    }
}

/// A track transition evaluated at the plan time.
public struct TransitionInstance: Sendable, Equatable {
    /// Transition name, e.g. `"Fade"`, `"RadialWipe"`.
    public var name: String
    /// 0 at the start of the transition window, 1 at its end.
    public var progress: Double
    /// Window length, ticks.
    public var duration: Int64
    /// The transition's `reverse` flag.
    public var reverse: Bool
    /// Numeric transition parameters, evaluated (empty when the entry has none).
    public var parameters: [String: Double]

    public init(name: String, progress: Double, duration: Int64, reverse: Bool = false,
                parameters: [String: Double] = [:]) {
        self.name = name; self.progress = progress; self.duration = duration; self.reverse = reverse
        self.parameters = parameters
    }
}

/// A recorded mouse cursor drawn over a screen-recording layer (WizRec `cursor.json` recordings).
/// Drawn in the layer's local space on top of its video and before its effects.
public struct CursorOverlay: Sendable, Equatable {
    /// Cursor image file (PNG, premultiplied sRGB).
    public var image: URL
    /// Image size in source video px (drawn 1:1 with the video at `scale` 1).
    public var imageSize: CGSize
    /// Hot spot in image px from its top-left.
    public var hotspot: CGPoint
    /// Hot-spot position in source video px, top-left origin, y down.
    public var position: CGPoint
    /// Source video size, px (the cursor log's `videoWidth`×`videoHeight`).
    public var sourceSize: CGSize
    /// Extra cursor scale (cursor effects; 1 = as recorded).
    public var scale: Double
    public var opacity: Double

    public init(image: URL, imageSize: CGSize, hotspot: CGPoint, position: CGPoint, sourceSize: CGSize,
                scale: Double = 1, opacity: Double = 1) {
        self.image = image; self.imageSize = imageSize; self.hotspot = hotspot; self.position = position
        self.sourceSize = sourceSize; self.scale = scale; self.opacity = opacity
    }
}

/// One visible clip at the plan time.
///
/// Coordinates: pixels, origin at the parent's centre, +x right, +y up.
public struct Layer: Sendable, Equatable {
    /// Project clip id (the visual clip, e.g. the `video` child of a `UnifiedMedia`).
    public var clipID: Int64
    public var content: LayerContent
    /// Natural size in px before transform (source `rect`, or the group's `widthAttr`/`heightAttr`).
    public var size: CGSize
    /// Maps layer-local px (origin at layer centre, +y up) to parent px.
    public var transform: CGAffineTransform
    /// Crop in source space, fractions of `size`.
    public var sourceCrop: Insets
    /// Crop of the placed geometry, fractions of `size`.
    public var geometryCrop: Insets
    /// This layer's own opacity, 0–1 (parents' opacity is not folded in).
    public var opacity: Double
    public var effects: [EffectInstance]
    /// Recorded cursor over this layer's video, if its recording has a cursor log.
    public var cursor: CursorOverlay?
    /// Motion blur: `transform` sampled across the shutter; the layer is drawn at each with weight 1/N.
    /// Empty = no motion blur.
    public var motion: [CGAffineTransform]

    public init(clipID: Int64, content: LayerContent, size: CGSize, transform: CGAffineTransform = .identity,
                sourceCrop: Insets = .zero, geometryCrop: Insets = .zero, opacity: Double = 1,
                effects: [EffectInstance] = [], cursor: CursorOverlay? = nil, motion: [CGAffineTransform] = []) {
        self.clipID = clipID; self.content = content; self.size = size; self.transform = transform
        self.sourceCrop = sourceCrop; self.geometryCrop = geometryCrop; self.opacity = opacity; self.effects = effects
        self.cursor = cursor; self.motion = motion
    }
}

/// The scene at one instant. Pure data; build it without a GPU.
public struct RenderPlan: Sendable, Equatable {
    /// Timeline time, ticks.
    public var time: Int64
    /// Canvas size, px.
    public var canvasSize: CGSize
    public var background: RGBA
    /// Bottom (track 0) to top.
    public var layers: [Layer]

    public init(time: Int64, canvasSize: CGSize, background: RGBA, layers: [Layer]) {
        self.time = time; self.canvasSize = canvasSize; self.background = background; self.layers = layers
    }

    /// Every video frame the plan needs, groups included, in draw order.
    public var frameRequests: [FrameRequest] {
        func walk(_ ls: [Layer]) -> [FrameRequest] {
            ls.flatMap { l -> [FrameRequest] in
                switch l.content {
                case .video(let r): [r]
                case .group(let children): walk(children)
                case .transition(_, let from, let to): walk([from, to].compactMap { $0 })
                default: []
                }
            }
        }
        return walk(layers)
    }
}

/// An audible span of one audio clip, for the player's mixer.
public struct AudioSegment: Sendable, Equatable {
    public var clipID: Int64
    public var url: URL
    /// Stream index (`trackNumber`).
    public var stream: Int
    /// Timeline span, ticks.
    public var timelineRange: Range<Int64>
    /// Stream time at `timelineRange.lowerBound`.
    public var mediaStart: CMTime
    /// Media seconds per timeline second (clip speed, nested scalars multiplied).
    public var rate: Double
    /// Linear gain (clip `gain` × `volume`, group gains multiplied); keyframes ignored in M1.
    public var gain: Double

    public init(clipID: Int64, url: URL, stream: Int, timelineRange: Range<Int64>, mediaStart: CMTime,
                rate: Double, gain: Double) {
        self.clipID = clipID; self.url = url; self.stream = stream; self.timelineRange = timelineRange
        self.mediaStart = mediaStart; self.rate = rate; self.gain = gain
    }
}

/// Immutable, Sendable projection of a project for rendering.
/// Build on the main actor (where the `Project` lives); evaluate anywhere.
public struct SceneModel: Sendable {
    public let timebase: Timebase
    public let canvasSize: CGSize
    public let frameRate: Rational
    /// Timeline length, ticks.
    public let duration: Int64
    /// Canvas background (`timeline.backgroundColor`).
    let background: RGBA
    /// Top-level tracks, bottom to top.
    let tracks: [STrack]

    /// `resolve` maps a source-bin entry to its file (usually `ProjectBundle.resolve`).
    /// Reads the project only; never mutates it.
    public init(project: Project, resolve: (SourceMedia) -> URL) {
        timebase = project.timebase
        canvasSize = CGSize(width: project.width, height: project.height)
        frameRate = project.frameRate
        duration = project.duration
        let timeline = project.timeline
        background = Conventions.background(timeline?.backgroundColor ?? [0, 0, 0, 255])
        tracks = SceneBuilder(project: project, resolve: resolve)
            .tracks(project.tracks, attributes: timeline?.trackAttributes ?? [])
    }

    /// The scene at timeline time `ticks`. Pure and deterministic.
    public func evaluate(at ticks: Int64) -> RenderPlan {
        let layers = SceneEvaluator(editRate: timebase.editRate, frameRate: frameRate)
            .layers(tracks, at: Rational(ticks), space: canvasSize)
        return RenderPlan(time: ticks, canvasSize: canvasSize, background: background, layers: layers)
    }

    /// Audio clips overlapping `range` (ticks), clipped to it.
    public func audioSegments(in range: Range<Int64>) -> [AudioSegment] {
        AudioEvaluator(editRate: timebase.editRate).segments(tracks, in: range)
    }
}

public enum RenderEngine {
    /// Convenience: `SceneModel(project:resolve:).evaluate(at:)`.
    public static func evaluate(_ project: Project, at ticks: Int64, resolve: (SourceMedia) -> URL) -> RenderPlan {
        SceneModel(project: project, resolve: resolve).evaluate(at: ticks)
    }
}

public enum RenderError: Error, Sendable, Equatable {
    case noMetalDevice
    case shaderCompile(String)
    case notImplemented
}

/// Draws a `RenderPlan` with Metal. Not thread-safe: own it from one actor.
public final class Compositor {
    public let device: any MTLDevice
    private let core: CompositorCore

    /// Effect names drawn on the GPU; any other effect passes through unchanged.
    public static var renderedEffects: Set<String> { EffectRegistry.names }

    /// Compiles the shaders; throws `RenderError.shaderCompile` on failure.
    public init(device: any MTLDevice) throws {
        self.device = device
        core = try CompositorCore(device: device)
    }

    /// Encodes `plan` into `target` (`.bgra8Unorm`, any size; the canvas is scaled to fit).
    /// Layers whose frame is missing from `frames` are skipped.
    public func encode(_ plan: RenderPlan, frames: [FrameRequest: VideoFrame],
                       into target: any MTLTexture, commandBuffer: any MTLCommandBuffer) throws {
        try core.encode(plan, frames: frames, into: target, commandBuffer: commandBuffer)
    }

    /// Offscreen textures idle in the pool (tests, diagnostics).
    var idleTextureCount: Int { core.fx.pool.idleCount }
}

/// Headless renderer: evaluate → fetch frames → composite → image. Used by golden tests and export.
public actor OfflineRenderer {
    public let scene: SceneModel
    public let pool: MediaPool
    /// Frame lookup; `pool.frame` unless a test injects another source.
    let frames: @Sendable (FrameRequest) async throws -> VideoFrame
    private var gpu: OfflineGPU?

    public init(scene: SceneModel, pool: MediaPool) {
        self.scene = scene; self.pool = pool
        frames = { [pool] in try await pool.frame($0) }
    }

    init(scene: SceneModel, pool: MediaPool, frames: @escaping @Sendable (FrameRequest) async throws -> VideoFrame) {
        self.scene = scene; self.pool = pool; self.frames = frames
    }

    /// Frame at timeline `ticks`, at `size` px (default: canvas size).
    /// Frames whose file is missing or unsupported are left out (the layer is not drawn);
    /// other decode errors are thrown.
    public func image(at ticks: Int64, size: CGSize? = nil) async throws -> CGImage {
        if gpu == nil { gpu = try OfflineGPU() }
        guard let gpu else { throw RenderError.noMetalDevice }
        let plan = scene.evaluate(at: ticks)
        let fetched = try await OfflineGPU.fetch(plan.frameRequests, using: frames)
        let target = size ?? scene.canvasSize
        return try gpu.render(plan, frames: fetched,
                                    width: max(Int(target.width.rounded()), 1),
                                    height: max(Int(target.height.rounded()), 1))
    }
}
