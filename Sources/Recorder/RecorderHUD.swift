import AppKit
import Observation
import SwiftUI

/// What the HUD's target picker can point at.
public enum HUDTargetChoice: Hashable, Sendable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    /// The region last selected with the overlay.
    case region
}

/// State and actions behind the recorder HUD; usable without the window (tests, app menus).
@MainActor @Observable
public final class RecorderHUDModel {
    public var displays: [DisplayInfo] = []
    public var windows: [WindowInfo] = []
    public var cameras: [CaptureDeviceInfo] = []
    public var microphones: [CaptureDeviceInfo] = []

    public var target: HUDTargetChoice = .display(CGMainDisplayID())
    /// Selected region: display and rectangle in its points, top-left origin.
    public var region: (display: CGDirectDisplayID, rect: CGRect)?
    public var microphoneID: String?
    public var cameraID: String?
    public var captureSystemAudio = false
    public var logCursor = true
    /// Set only through `setLogKeystrokes(_:)`, which asks for consent.
    public private(set) var logKeystrokes = false
    public var countdown = 3
    public var frameRate = 30
    public var codec: VideoCodec = .h264

    public private(set) var state: RecorderState = .idle
    public private(set) var elapsedText = "0:00"
    /// Last error or warning for the user, nil when none.
    public var message: String?
    /// True when window titles could not be listed (Screen Recording not granted yet).
    public private(set) var windowsNeedPermission = false

    /// Folder for the next recording; called once per recording.
    public var outputDirectory: @MainActor () -> URL
    /// Called with the finished recording (or the error that ended it).
    public var onFinish: (@MainActor (Result<RecordingResult, Error>) -> Void)?
    /// Called before keystroke logging turns on; return true only after explicit user consent.
    public var requestKeystrokeConsent: @MainActor () -> Bool = { false }

    public private(set) var session: RecordingSession?
    private var ticker: Timer?
    private let overlay = RegionSelectionOverlay()

    public init(outputDirectory: @escaping @MainActor () -> URL = RecorderHUDModel.defaultOutputDirectory) {
        self.outputDirectory = outputDirectory
    }

    /// `<tmp>/WizRec Recordings/Recording <date>`. Apps should pass their own folder.
    public static func defaultOutputDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WizRec Recordings", isDirectory: true)
            .appendingPathComponent(HUDFormat.folderName(for: Date()), isDirectory: true)
    }

    /// Reloads displays, windows and devices.
    public func refresh() async {
        displays = CaptureSources.displays()
        cameras = CaptureSources.cameras()
        microphones = CaptureSources.microphones()
        do {
            windows = try await CaptureSources.windows()
            windowsNeedPermission = false
        } catch {
            windows = []
            windowsNeedPermission = true
        }
        if case let .display(id) = target, !displays.contains(where: { $0.id == id }), let first = displays.first {
            target = .display(first.id)
        }
        if case let .window(id) = target, !windows.contains(where: { $0.id == id }), let first = displays.first {
            target = .display(first.id)
        }
    }

    /// Turns keystroke logging on (after `requestKeystrokeConsent` and the permission check) or off.
    public func setLogKeystrokes(_ on: Bool) {
        guard on else { logKeystrokes = false; return }
        guard requestKeystrokeConsent() else { return }
        if !RecorderPermissions.keystrokeMonitoring {
            RecorderPermissions.requestKeystrokeMonitoring()
            message = "Allow WizRec under Privacy & Security › Input Monitoring, then turn keystroke logging on again."
            return
        }
        logKeystrokes = true
    }

    /// Opens the region overlay; on success the target becomes `.region`.
    public func selectRegion() {
        overlay.begin { [weak self] result in
            guard let self, let result else { return }
            self.region = (result.0, result.1)
            self.target = .region
        }
    }

    /// The capture target for the current choice, nil when a region is chosen but not selected.
    public var captureTarget: CaptureTarget? {
        switch target {
        case let .display(id): .display(id)
        case let .window(id): .window(id)
        case .region: region.map { .region($0.display, $0.rect) }
        }
    }

    /// Options for the next recording.
    public func makeOptions(outputDirectory: URL) -> RecordingOptions? {
        guard let t = captureTarget else { return nil }
        var o = RecordingOptions(target: t, outputDirectory: outputDirectory)
        o.frameRate = frameRate
        o.codec = codec
        o.captureSystemAudio = captureSystemAudio
        o.microphoneID = microphoneID
        o.cameraID = cameraID
        o.logCursor = logCursor
        o.logKeystrokes = logKeystrokes
        return o
    }

    /// Start (idle), cancel the countdown, or stop (recording / paused). Bound to ⌘⇧2.
    public func toggleRecording() {
        switch state {
        case .idle: startRecording()
        case .countingDown: session?.cancel()
        case .recording, .paused: stopRecording()
        case .finishing: break
        }
    }

    /// Pause or resume. Bound to ⌘⇧P.
    public func togglePause() {
        switch state {
        case .recording: session?.pause()
        case .paused: session?.resume()
        default: break
        }
    }

    private func startRecording() {
        guard let options = makeOptions(outputDirectory: outputDirectory()) else {
            message = "Select a region first."
            return
        }
        message = nil
        let s = RecordingSession(options: options)
        s.onStateChange = { [weak self] in self?.sessionStateChanged($0) }
        session = s
        Task {
            do {
                try await s.start(countdown: countdown)
            } catch is CancellationError {
                session = nil
            } catch {
                session = nil
                message = Self.describe(error)
                onFinish?(.failure(error))
            }
        }
    }

    private func stopRecording() {
        guard let s = session else { return }
        Task {
            do {
                let result = try await s.stop()
                message = s.warnings.isEmpty ? nil : s.warnings.joined(separator: "\n")
                session = nil
                onFinish?(.success(result))
            } catch {
                session = nil
                message = Self.describe(error)
                onFinish?(.failure(error))
            }
        }
    }

    private func sessionStateChanged(_ s: RecorderState) {
        state = s
        switch s {
        case .recording, .paused:
            if ticker == nil {
                let t = Timer(timeInterval: 0.25, repeats: true) { _ in
                    MainActor.assumeIsolated { [weak self] in self?.tick() }
                }
                RunLoop.main.add(t, forMode: .common)
                ticker = t
            }
            tick()
        case .idle, .countingDown, .finishing:
            ticker?.invalidate(); ticker = nil
            if s == .idle || s == .countingDown(countdown) { elapsedText = "0:00" }
        }
    }

    private func tick() { elapsedText = HUDFormat.elapsed(session?.elapsed ?? 0) }

    static func describe(_ error: Error) -> String {
        switch error {
        case let RecorderError.permissionDenied(what):
            "Permission needed: \(what). Allow WizRec in System Settings › Privacy & Security, then relaunch."
        case let RecorderError.deviceUnavailable(what): "Unavailable: \(what)."
        case let RecorderError.failed(what): "Recording failed: \(what)."
        default: error.localizedDescription
        }
    }
}

/// Floating recorder panel the app presents: target picker (display / window / region overlay),
/// device toggles, countdown, timer, pause/stop and global hot keys (⌘⇧2 start/stop, ⌘⇧P pause).
/// The panel is excluded from the captured pixels.
@MainActor
public final class RecorderHUDController: NSWindowController, NSWindowDelegate {
    public let model: RecorderHUDModel
    /// Global shortcuts; change before `present()`.
    public var startStopHotKey: HUDHotKey = .startStop
    public var pauseHotKey: HUDHotKey = .pauseResume
    private let hotKeys = GlobalHotKeys()
    private var hotKeysInstalled = false

    /// `outputDirectory` is asked for a fresh folder at each start; `onFinish` gets the files.
    public init(outputDirectory: @escaping @MainActor () -> URL = RecorderHUDModel.defaultOutputDirectory,
                onFinish: (@MainActor (Result<RecordingResult, Error>) -> Void)? = nil) {
        let model = RecorderHUDModel(outputDirectory: outputDirectory)
        model.onFinish = onFinish
        self.model = model
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 340, height: 420),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = "WizRec Recorder"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        model.requestKeystrokeConsent = { [weak self] in self?.askKeystrokeConsent() ?? false }
        let host = NSHostingView(rootView: RecorderHUDView(model: model, startStop: startStopHotKey, pause: pauseHotKey))
        host.sizingOptions = [.preferredContentSize]
        panel.contentView = host
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the panel (top-right of the main screen the first time) and installs the hot keys.
    public func present() {
        guard let panel = window else { return }
        if !panel.isVisible, let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(CGPoint(x: f.maxX - panel.frame.width - 20, y: f.maxY - 20))
        }
        (panel.contentView as? NSHostingView<RecorderHUDView>)?.rootView =
            RecorderHUDView(model: model, startStop: startStopHotKey, pause: pauseHotKey)
        panel.orderFrontRegardless()
        RecorderExclusions.exclude(windowNumber: panel.windowNumber)
        installHotKeys()
        Task { await model.refresh() }
    }

    private func installHotKeys() {
        guard !hotKeysInstalled else { return }
        hotKeysInstalled = true
        let a = hotKeys.register(startStopHotKey) { [weak self] in self?.model.toggleRecording() }
        let b = hotKeys.register(pauseHotKey) { [weak self] in self?.model.togglePause() }
        if !a || !b { model.message = "A recorder shortcut is used by another app." }
    }

    public func windowWillClose(_ notification: Notification) {
        if let n = window?.windowNumber { RecorderExclusions.include(windowNumber: n) }
        // Keep hot keys while recording so the user can still stop.
        if model.state == .idle {
            hotKeys.unregisterAll()
            hotKeysInstalled = false
        }
    }

    private func askKeystrokeConsent() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Log keystrokes in this recording?"
        alert.informativeText = """
            WizRec will save the keys you press while recording (key, modifiers and typed characters) \
            in cursor.json next to the video, so they can be shown on screen later. Nothing is logged \
            while a password field or other secure input is active. Text typed anywhere else, including \
            messages and other private text, is saved. The log stays on this Mac.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Log Keystrokes")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// The panel's content.
struct RecorderHUDView: View {
    @Bindable var model: RecorderHUDModel
    let startStop: HUDHotKey
    let pause: HUDHotKey

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.state {
            case .idle: setup
            case let .countingDown(n): countdownView(n)
            case .recording, .paused, .finishing: recordingView
            }
            if let m = model.message {
                Text(m).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Record", selection: $model.target) {
                ForEach(model.displays) { d in Text(d.name).tag(HUDTargetChoice.display(d.id)) }
                if !model.windows.isEmpty {
                    Divider()
                    ForEach(model.windows) { w in
                        Text(w.title.isEmpty ? w.appName : "\(w.appName) — \(w.title)").lineLimit(1).tag(HUDTargetChoice.window(w.id))
                    }
                }
                Divider()
                Text(regionLabel).tag(HUDTargetChoice.region)
            }
            HStack {
                Button("Select Region…") { model.selectRegion() }
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }
            }
            if model.windowsNeedPermission {
                Text("Grant Screen Recording to list windows.").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Microphone", selection: $model.microphoneID) {
                Text("None").tag(String?.none)
                ForEach(model.microphones) { Text($0.name).tag(Optional($0.id)) }
            }
            Picker("Camera", selection: $model.cameraID) {
                Text("None").tag(String?.none)
                ForEach(model.cameras) { Text($0.name).tag(Optional($0.id)) }
            }
            Toggle("System audio", isOn: $model.captureSystemAudio)
            Toggle("Log cursor and clicks", isOn: $model.logCursor)
            Toggle("Log keystrokes", isOn: Binding(get: { model.logKeystrokes }, set: { model.setLogKeystrokes($0) }))
            Stepper("Countdown: \(model.countdown) s", value: $model.countdown, in: 0...10)
            Button {
                model.toggleRecording()
            } label: {
                Label("Record  \(startStop.displayString)", systemImage: "record.circle").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var regionLabel: String {
        guard let r = model.region?.rect else { return "Region (not selected)" }
        return "Region \(Int(r.width)) × \(Int(r.height)) pt"
    }

    private func countdownView(_ n: Int) -> some View {
        VStack(spacing: 8) {
            Text("\(n)").font(.system(size: 64, weight: .bold, design: .rounded)).monospacedDigit()
            Button("Cancel") { model.toggleRecording() }
        }
        .frame(maxWidth: .infinity)
    }

    private var recordingView: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(model.state == .paused ? Color.orange : Color.red).frame(width: 12, height: 12)
                Text(model.elapsedText).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                if model.state == .paused { Text("Paused").foregroundStyle(.secondary) }
            }
            HStack {
                Button {
                    model.togglePause()
                } label: {
                    Label(model.state == .paused ? "Resume  \(pause.displayString)" : "Pause  \(pause.displayString)",
                          systemImage: model.state == .paused ? "play.fill" : "pause.fill")
                }
                .disabled(model.state == .finishing)
                Button {
                    model.toggleRecording()
                } label: {
                    Label("Stop  \(startStop.displayString)", systemImage: "stop.fill")
                }
                .disabled(model.state == .finishing)
            }
            if model.state == .finishing { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity)
    }
}
