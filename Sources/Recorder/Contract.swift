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
    /// Writing a file failed (additive, recorder API_CHANGE 2026-10-19).
    case failed(String)
}

/// One recording. Drive from the main actor (HUD).
///
/// `start` checks permissions, starts every source, counts down (`state` = `.countingDown(n)`,
/// one second per step) and then sets t = 0 for every file. `pause`/`resume` cut the paused
/// span out of all files and the cursor log; `stop` closes the files and returns them.
@MainActor
public final class RecordingSession {
    public let options: RecordingOptions
    public private(set) var state: RecorderState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    /// Called on every `state` change (additive API).
    public var onStateChange: (@MainActor (RecorderState) -> Void)?
    /// Non-fatal problems of the last `stop` (a secondary file missing, dropped frames…) (additive API).
    public private(set) var warnings: [String] = []
    private var engine: RecordingEngine?
    private var cancelled = false

    public init(options: RecordingOptions) { self.options = options }

    /// Recording time so far, seconds; frozen while paused, 0 before the countdown ends (additive API).
    public var elapsed: TimeInterval { engine?.elapsed ?? 0 }

    /// Starts recording after `countdown` seconds. Throws `RecorderError.permissionDenied` /
    /// `.deviceUnavailable`, or `CancellationError` when `cancel()`/`stop()` came during the countdown.
    public func start(countdown: Int = 3) async throws {
        guard state == .idle else { return }
        cancelled = false
        warnings = []
        let engine = RecordingEngine(options: options)
        self.engine = engine
        state = .countingDown(max(1, countdown))
        do {
            try await engine.prepare()
            var n = max(0, countdown)
            while n > 0 {
                try checkCancelled()
                state = .countingDown(n)
                let deadline = Date().addingTimeInterval(1)
                while Date() < deadline {
                    try checkCancelled()
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                n -= 1
            }
            try checkCancelled()
            engine.begin()
            state = .recording
        } catch {
            await engine.abort()
            self.engine = nil
            state = .idle
            throw error
        }
    }

    private func checkCancelled() throws {
        if cancelled || Task.isCancelled { throw CancellationError() }
    }

    /// Cancels a countdown in progress (additive API). No effect once recording.
    public func cancel() {
        if case .countingDown = state { cancelled = true }
    }

    public func pause() {
        guard state == .recording, let engine else { return }
        engine.pause()
        state = .paused
    }

    public func resume() {
        guard state == .paused, let engine else { return }
        engine.resume()
        state = .recording
    }

    /// Stops and returns the files. During the countdown it cancels instead and throws
    /// `CancellationError`.
    public func stop() async throws -> RecordingResult {
        if case .countingDown = state { cancel(); throw CancellationError() }
        guard state == .recording || state == .paused, let engine else { throw RecorderError.deviceUnavailable("not recording") }
        state = .finishing
        defer { self.engine = nil; state = .idle }
        do {
            let result = try await engine.finish()
            warnings = engine.warnings
            return result
        } catch {
            warnings = engine.warnings
            throw error
        }
    }
}
