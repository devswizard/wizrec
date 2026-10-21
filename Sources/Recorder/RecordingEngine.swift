import AVFoundation
import CoreMedia
import Foundation

/// Output file names inside `RecordingOptions.outputDirectory`.
public enum RecordingFiles {
    public static let screen = "screen.mp4"
    public static let camera = "camera.mp4"
    public static let microphone = "microphone.m4a"
    public static let systemAudio = "system-audio.m4a"
    public static let cursorLog = "cursor.json"
    /// Folder (next to `cursor.json`) holding the cursor PNGs.
    public static let cursorImages = "cursors"
}

/// Wires the capture sources, the shared clock, the writers and the cursor logger of one
/// recording. Driven by `RecordingSession` on the main actor.
@MainActor
final class RecordingEngine {
    let options: RecordingOptions
    let clock = RecordingClock()
    private(set) var warnings: [String] = []

    private var screen: ScreenCapture?
    private var devices: DeviceCapture?
    private var logger: CursorLogger?
    private var screenPipe: VideoPipeline?
    private var cameraPipe: VideoPipeline?
    private var writers: (screen: MediaFileWriter, camera: MediaFileWriter?, mic: MediaFileWriter?, system: MediaFileWriter?)?

    init(options: RecordingOptions) { self.options = options }

    /// Test seam (QA11-3): installs the file writers `prepare()` would create, without any
    /// capture source, so tests can drive `finish()` with injected (e.g. stuck) writers.
    /// Internal (`@testable import Recorder`); the app never calls it.
    func installWritersForTesting(screen: MediaFileWriter, camera: MediaFileWriter? = nil,
                                  mic: MediaFileWriter? = nil, system: MediaFileWriter? = nil) {
        writers = (screen, camera, mic, system)
    }

    private func url(_ name: String) -> URL { options.outputDirectory.appendingPathComponent(name) }

    /// Checks permissions, creates the folder and starts every source. Frames delivered before
    /// `begin()` are dropped (the latest screen frame is kept for t=0).
    func prepare() async throws {
        try await Self.checkPermissions(options)
        try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)

        let fps = max(1, min(240, options.frameRate))
        let screenWriter = MediaFileWriter(url: url(RecordingFiles.screen), kind: .video(codec: options.codec, frameRate: fps))
        let systemWriter = options.captureSystemAudio ? MediaFileWriter(url: url(RecordingFiles.systemAudio), kind: .audio) : nil
        let cameraWriter = options.cameraID != nil ? MediaFileWriter(url: url(RecordingFiles.camera), kind: .video(codec: options.codec, frameRate: 30)) : nil
        let micWriter = options.microphoneID != nil ? MediaFileWriter(url: url(RecordingFiles.microphone), kind: .audio) : nil
        writers = (screenWriter, cameraWriter, micWriter, systemWriter)

        let screenPipe = VideoPipeline(clock: clock, writer: screenWriter)
        self.screenPipe = screenPipe
        let systemPipe = systemWriter.map { AudioPipeline(clock: clock, writer: $0) }
        let cameraPipe = cameraWriter.map { VideoPipeline(clock: clock, writer: $0) }
        self.cameraPipe = cameraPipe
        let micPipe = micWriter.map { AudioPipeline(clock: clock, writer: $0) }

        let screen = try await ScreenCapture.make(
            options: options,
            onVideo: Self.sink(screenPipe),
            onAudio: systemPipe.map(Self.sink)
        )
        if options.cameraID != nil || options.microphoneID != nil {
            let devices = try DeviceCapture(
                cameraID: options.cameraID, microphoneID: options.microphoneID,
                onCamera: cameraPipe.map(Self.sink),
                onMicrophone: micPipe.map(Self.sink)
            )
            self.devices = devices
            await Task.detached { devices.start() }.value
        }
        self.screen = screen
        try await screen.start()

        if options.logCursor || options.logKeystrokes {
            var windowID: CGWindowID?
            if case let .window(id) = options.target { windowID = id }
            let logger = CursorLogger(clock: clock, geometry: screen.plan.geometry, windowID: windowID,
                                      sampleRate: fps, logKeystrokes: options.logKeystrokes,
                                      directory: options.outputDirectory)
            try logger.startMonitoring()
            self.logger = logger
        }
    }

    /// Capture-queue callbacks (not main-actor isolated).
    nonisolated static func sink(_ p: VideoPipeline) -> @Sendable (CMSampleBuffer, CMTime) -> Void {
        { p.receive($0, hostTime: $1) }
    }
    nonisolated static func sink(_ p: AudioPipeline) -> @Sendable (CMSampleBuffer, CMTime) -> Void {
        { p.receive($0, hostTime: $1) }
    }

    /// t = 0 of every file.
    func begin() {
        clock.start(at: hostNow())
        activate()
    }

    func pause() { clock.pause(at: hostNow()) }

    func resume() {
        guard clock.resume(at: hostNow()) != nil else { return }
        activate()
    }

    private func activate() {
        screenPipe?.activate()
        cameraPipe?.activate()
        logger?.segmentStarted()
    }

    /// Recording time now, seconds (frozen while paused).
    var elapsed: TimeInterval { clock.recordingTime(at: hostNow()).seconds }

    /// Stops every source and closes the files.
    func finish() async throws -> RecordingResult {
        let end = clock.stop(at: hostNow())
        await stopSources()
        guard let writers else { throw RecorderError.deviceUnavailable("not prepared") }

        var cursorURL: URL?
        if let logger {
            let log = logger.finish(duration: end)
            let u = url(RecordingFiles.cursorLog)
            do { try log.jsonData().write(to: u, options: .atomic); cursorURL = u } catch {
                warnings.append("cursor log not written: \(error.localizedDescription)")
            }
            self.logger = nil
        }

        func close(_ w: MediaFileWriter?, _ what: String) async -> URL? {
            guard let w else { return nil }
            do {
                if try await w.finish(at: end) { return w.url }
                warnings.append("\(what): no samples recorded")
            } catch {
                warnings.append("\(what): \(error)")
            }
            return nil
        }
        let camera = await close(writers.camera, "camera")
        let mic = await close(writers.mic, "microphone")
        let system = await close(writers.system, "system audio")
        if let failure = screen?.streamFailure { warnings.append("screen stream stopped early: \(failure.localizedDescription)") }
        let screenOK: Bool
        do { screenOK = try await writers.screen.finish(at: end) } catch {
            throw RecorderError.failed("screen video: \(error)")
        }
        guard screenOK else { throw RecorderError.deviceUnavailable("no screen frames were captured") }
        let dropped = writers.screen.droppedCount
        if dropped > 0 { warnings.append("screen: \(dropped) frames dropped (encoder busy)") }
        return RecordingResult(screen: writers.screen.url, camera: camera, audio: [mic, system].compactMap { $0 },
                               cursorLog: cursorURL, duration: end)
    }

    /// Tears everything down without producing a result (cancel / failed start).
    func abort() async {
        logger?.stopMonitoring(); logger = nil
        await stopSources()
        if let w = writers {
            for writer in [w.screen, w.camera, w.mic, w.system].compactMap({ $0 }) {
                _ = try? await writer.finish(at: .zero)
            }
        }
    }

    private func stopSources() async {
        logger?.stopMonitoring()
        if let screen { await screen.stop() }
        if let devices { await Task.detached { devices.stop() }.value }
        screen = nil; devices = nil
    }

    static func checkPermissions(_ o: RecordingOptions) async throws {
        if !RecorderPermissions.screenRecording {
            RecorderPermissions.requestScreenRecording()
            if !RecorderPermissions.screenRecording { throw RecorderError.permissionDenied("Screen Recording") }
        }
        if o.cameraID != nil {
            if RecorderPermissions.camera == .notDetermined { _ = await RecorderPermissions.requestCamera() }
            guard RecorderPermissions.camera == .authorized else { throw RecorderError.permissionDenied("Camera") }
        }
        if o.microphoneID != nil {
            if RecorderPermissions.microphone == .notDetermined { _ = await RecorderPermissions.requestMicrophone() }
            guard RecorderPermissions.microphone == .authorized else { throw RecorderError.permissionDenied("Microphone") }
        }
        if o.logKeystrokes, !RecorderPermissions.keystrokeMonitoring {
            RecorderPermissions.requestKeystrokeMonitoring()
            throw RecorderError.permissionDenied("Input Monitoring (keystroke logging)")
        }
    }
}
