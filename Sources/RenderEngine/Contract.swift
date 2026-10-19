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

/// An effect with its parameters evaluated at the plan time. M1 compositor ignores effects.
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
    case shader(URL, parameters: [String: Double])
    /// A group's children, bottom to top, in the group's own coordinate space.
    case group([Layer])
    /// A clip type the engine does not draw yet (e.g. `"Callout"` before M5).
    case unsupported(type: String)
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

    public init(clipID: Int64, content: LayerContent, size: CGSize, transform: CGAffineTransform = .identity,
                sourceCrop: Insets = .zero, geometryCrop: Insets = .zero, opacity: Double = 1,
                effects: [EffectInstance] = []) {
        self.clipID = clipID; self.content = content; self.size = size; self.transform = transform
        self.sourceCrop = sourceCrop; self.geometryCrop = geometryCrop; self.opacity = opacity; self.effects = effects
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
        let layers = SceneEvaluator(editRate: timebase.editRate).layers(tracks, at: Rational(ticks))
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
}

/// Headless renderer: evaluate → fetch frames → composite → image. Used by golden tests and export.
public actor OfflineRenderer {
    public let scene: SceneModel
    public let pool: MediaPool

    public init(scene: SceneModel, pool: MediaPool) {
        self.scene = scene; self.pool = pool
    }

    /// Frame at timeline `ticks`, at `size` px (default: canvas size).
    public func image(at ticks: Int64, size: CGSize? = nil) async throws -> CGImage {
        throw RenderError.notImplemented
    }
}
