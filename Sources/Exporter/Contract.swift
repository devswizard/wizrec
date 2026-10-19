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

/// What to export.
public struct ExportSettings: Sendable, Equatable {
    public var format: ExportFormat
    /// Output frame size in px (aspect-fit of the canvas; default = canvas size).
    public var size: CGSize?
    /// Output frames per second (default = project `videoFormatFrameRate`).
    public var frameRate: Rational?
    /// Timeline range in ticks (default = whole project).
    public var range: Range<Int64>?
    public var includeAudio: Bool = true
    public init(format: ExportFormat) { self.format = format }
}

/// A named setting for the export sheet.
public struct ExportPreset: Sendable, Equatable {
    public var name: String
    public var settings: ExportSettings
}

public enum ExportError: Error, Sendable, Equatable {
    case notImplemented
    case cancelled
    case failed(String)
}

/// One export job. Progress 0–1 via `progress`; `cancel()` stops and removes the partial file.
public actor ExportSession {
    public let settings: ExportSettings
    public let output: URL

    public init(scene: SceneModel, audio: AudioScene, pool: MediaPool, settings: ExportSettings, output: URL) {
        self.settings = settings; self.output = output
    }

    /// Fraction done, 0–1, updated while `run()` works.
    public private(set) var progress: Double = 0

    public func run() async throws { throw ExportError.notImplemented }
    public func cancel() {}

    /// Built-in presets (1080p/720p/4K MP4, ProRes, GIF, audio).
    public static var presets: [ExportPreset] { [] }
}
