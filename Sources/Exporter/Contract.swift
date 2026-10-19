// Public interface of Exporter (agent "export", M9), frozen by coordination/CONTRACTS.md.
// Changing anything here needs an API_CHANGE message and the lead's approval.

import CoreGraphics
import Foundation
import AudioEngine
import MediaEngine
import RenderEngine
import TSCProjKit

/// Output container and codec.
public enum ExportFormat: Sendable, Equatable {
    /// MP4, `codec` "h264" or "hevc", video bitrate in bits/s (nil = automatic).
    case mp4(codec: String, bitrate: Int?)
    /// QuickTime ProRes, `profile` "422", "422HQ" or "4444".
    case mov(profile: String)
    /// Animated GIF at `fps`, palette per clip.
    case gif(fps: Int)
    /// Audio only: "m4a", "wav" or "mp3".
    case audio(container: String)
}

/// GIF encoding options (used by `ExportFormat.gif`).
public struct GIFOptions: Sendable, Equatable {
    /// Floyd–Steinberg error diffusion (true) or nearest palette colour (false).
    public var dither: Bool
    /// Times the animation repeats after the first play; 0 = forever.
    public var loopCount: Int
    /// Opaque palette entries per segment, 2–255 (one more index is kept for "unchanged" pixels).
    public var maxColors: Int
    /// A new palette starts when the visible clips change or after this many frames.
    public var maxSegmentFrames: Int

    public init(dither: Bool = true, loopCount: Int = 0, maxColors: Int = 255, maxSegmentFrames: Int = 90) {
        self.dither = dither; self.loopCount = loopCount; self.maxColors = maxColors
        self.maxSegmentFrames = maxSegmentFrames
    }
}

/// What to export.
public struct ExportSettings: Sendable, Equatable {
    public var format: ExportFormat
    /// Output frame size in px: the canvas is aspect-fitted into this box (rounded to even px for
    /// H.264/HEVC/ProRes), so the output never has letterbox bars. Default = canvas size.
    public var size: CGSize?
    /// Output frames per second (default = project `videoFormatFrameRate`; GIF uses its own `fps`).
    public var frameRate: Rational?
    /// Timeline range in ticks (default = whole project).
    public var range: Range<Int64>?
    public var includeAudio: Bool = true
    /// GIF palette and dithering options.
    public var gif = GIFOptions()
    public init(format: ExportFormat) { self.format = format }
}

/// A named setting for the export sheet.
public struct ExportPreset: Sendable, Equatable {
    public var name: String
    public var settings: ExportSettings
    public init(name: String, settings: ExportSettings) { self.name = name; self.settings = settings }
}

public enum ExportError: Error, Sendable, Equatable {
    case notImplemented
    case cancelled
    case failed(String)
}

/// One export job. Progress 0–1 via `progress`; `cancel()` stops and removes the partial file.
///
/// The file is written next to `output` under a temporary name and moved into place only when
/// complete, so a failed or cancelled export never leaves a partial file (or destroys an existing one).
public actor ExportSession {
    public let settings: ExportSettings
    public let output: URL
    let scene: SceneModel
    let audioScene: AudioScene
    let pool: MediaPool
    /// Set by `cancel()`; checked between frames and audio chunks.
    var cancelRequested = false
    private var progressHandler: (@Sendable (Double) -> Void)?
    private var running = false
    /// Callers of `cancelAndWait()` waiting for `run()` to return.
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    public init(scene: SceneModel, audio: AudioScene, pool: MediaPool, settings: ExportSettings, output: URL) {
        self.settings = settings; self.output = output
        self.scene = scene; self.audioScene = audio; self.pool = pool
    }

    /// Fraction done, 0–1, updated while `run()` works.
    public private(set) var progress: Double = 0

    /// Calls `handler` (on an arbitrary thread) whenever `progress` changes by ≥ 0.5 % and at the end.
    public func setProgressHandler(_ handler: (@Sendable (Double) -> Void)?) { progressHandler = handler }

    /// Runs the export. Throws `ExportError.cancelled` after `cancel()` (or task cancellation).
    public func run() async throws {
        guard !running else { throw ExportError.failed("export already running") }
        running = true
        defer {
            running = false
            let waiters = stopWaiters
            stopWaiters = []
            for w in waiters { w.resume() }
        }
        report(0)
        try await perform()
        report(1, force: true)
    }

    public func cancel() { cancelRequested = true }

    /// True while `run()` is working and the output is not in place yet, i.e. cancelling now
    /// throws away encoded work. False before `run()`, after it returned, and once cancelled.
    /// The app asks this before closing a window and shows a confirmation when true.
    public var cancellationLosesWork: Bool { running && !cancelRequested }

    /// Cancels and returns once `run()` has stopped and removed its partial output (immediately
    /// when nothing runs). An export that already moved its file into place keeps it.
    public func cancelAndWait() async {
        cancelRequested = true
        guard running else { return }
        await withCheckedContinuation { stopWaiters.append($0) }
    }

    /// Built-in presets (1080p/720p/4K MP4, ProRes, GIF, audio).
    public static var presets: [ExportPreset] { ExportPresets.all }

    /// Updates `progress` and notifies the handler.
    func report(_ value: Double, force: Bool = false) {
        let v = min(max(value, 0), 1)
        let notify = force || abs(v - progress) >= 0.005 || v == 0
        progress = v
        if notify { progressHandler?(v) }
    }

    /// True once `cancel()` was called or the running task was cancelled.
    var isCancelled: Bool { cancelRequested || Task.isCancelled }
}
