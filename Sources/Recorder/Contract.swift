// Public interface of Recorder (agent "recorder"), frozen by coordination/CONTRACTS.md.
// Changing anything here needs an API_CHANGE message and the lead's approval.

import CoreGraphics
import CoreMedia
import Foundation

/// What to capture.
public enum CaptureTarget: Sendable, Equatable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    /// A rectangle in the display's points, origin top-left.
    case region(CGDirectDisplayID, CGRect)
}

public enum VideoCodec: String, Sendable { case h264, hevc }

/// Recording configuration.
public struct RecordingOptions: Sendable, Equatable {
    public var target: CaptureTarget
    /// Capture frames per second.
    public var frameRate: Int = 30
    public var codec: VideoCodec = .h264
    /// Draw the cursor into the screen pixels. Default false: the cursor is logged and
    /// rendered later as its own layer (CLAUDE.md M6/M7).
    public var cursorInVideo: Bool = false
    public var captureSystemAudio: Bool = false
    /// `AVCaptureDevice.uniqueID`, nil = no microphone.
    public var microphoneID: String?
    /// `AVCaptureDevice.uniqueID`, nil = no camera.
    public var cameraID: String?
    /// Log cursor position, clicks and cursor images to `cursor.json`.
    public var logCursor: Bool = true
    /// Log keystrokes (needs Accessibility permission and explicit user consent).
    public var logKeystrokes: Bool = false
    /// Folder that receives the output files (created if missing).
    public var outputDirectory: URL

    public init(target: CaptureTarget, outputDirectory: URL) {
        self.target = target; self.outputDirectory = outputDirectory
    }
}

/// Files produced by one recording. Durations share time 0 = recording start.
public struct RecordingResult: Sendable, Equatable {
    /// Screen video (MP4), cursor not drawn unless `cursorInVideo`.
    public var screen: URL
    public var camera: URL?
    /// Microphone and/or system audio (M4A / WAV).
    public var audio: [URL]
    /// Cursor/click/keystroke log, format in `docs/specs/cursor-log.md`.
    public var cursorLog: URL?
    public var duration: CMTime
}

public enum RecorderState: Sendable, Equatable { case idle, countingDown(Int), recording, paused, finishing }

public enum RecorderError: Error, Sendable, Equatable {
    case permissionDenied(String)
    case deviceUnavailable(String)
    case notImplemented
}

/// One recording. Drive from the main actor (HUD).
@MainActor
public final class RecordingSession {
    public let options: RecordingOptions
    public private(set) var state: RecorderState = .idle

    public init(options: RecordingOptions) { self.options = options }

    public func start(countdown: Int = 3) async throws { throw RecorderError.notImplemented }
    public func pause() {}
    public func resume() {}
    public func stop() async throws -> RecordingResult { throw RecorderError.notImplemented }
}
