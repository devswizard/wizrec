import AppKit
import Captions
import PlayerKit
import SwiftUI

/// WizRec ▸ Settings… (⌘,): general, playback and privacy preferences (`AppPreferences`).
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let host = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: host)
        window.title = String(localized: "Settings")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("WizRec.Settings")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func present() {
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            PlaybackSettings().tabItem { Label("Playback", systemImage: "play.rectangle") }
            CaptionSettings().tabItem { Label("Captions", systemImage: "captions.bubble") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 480)
        .padding(20)
    }
}

private struct GeneralSettings: View {
    @AppStorage(AppPreferences.Key.showWelcomeAtLaunch) private var showWelcome = false

    var body: some View {
        Form {
            Toggle("Show the welcome window at launch", isOn: $showWelcome)
            Button("Show Welcome Window") { WelcomeWindowController.shared.present() }
        }
        .formStyle(.grouped)
    }
}

private struct PlaybackSettings: View {
    @AppStorage(AppPreferences.Key.playAudio) private var playAudio = true
    @AppStorage(AppPreferences.Key.framePolicy) private var framePolicy = AppPreferences.FramePolicy.nearest.rawValue
    @AppStorage(AppPreferences.Key.showPerformanceOverlay) private var overlay = false

    var body: some View {
        Form {
            Toggle("Play audio", isOn: $playAudio)
            Picker("Fast playback", selection: $framePolicy) {
                Text("Every frame (may stutter)").tag(AppPreferences.FramePolicy.exact.rawValue)
                Text("Skip frames to keep time").tag(AppPreferences.FramePolicy.thin.rawValue)
                Text("Skip frames, show nearest while seeking").tag(AppPreferences.FramePolicy.nearest.rawValue)
            }
            Toggle("Show the performance overlay", isOn: $overlay)
            Text("Applies to projects opened afterwards.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

/// Speech engine for Captions ▸ Transcribe: Apple Speech, or whisper.cpp (`whisper-cli` and a
/// ggml model the user installs; detected at runtime, never bundled).
private struct CaptionSettings: View {
    @AppStorage(WhisperSettings.backendKey) private var backend = AppleSpeechRecognizer().id
    @AppStorage(WhisperSettings.modelKey) private var model = ""
    @AppStorage(WhisperSettings.binaryPathKey) private var binaryPath = ""
    /// Default on, matching `WhisperCppRecognizer.fromDefaults` (a missing key means on).
    @AppStorage(WhisperSettings.vadKey) private var vad = true
    @State private var models: [WhisperModel] = []
    @State private var vadModel: String?
    @State private var found: URL?
    @State private var status = ""
    @State private var ready = false

    private static let whisperID = WhisperCppRecognizer().id

    var body: some View {
        Form {
            Picker("Speech engine", selection: $backend) {
                Text("Apple Speech").tag(AppleSpeechRecognizer().id)
                Text("whisper.cpp").tag(Self.whisperID)
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("settings.captions.engine")
            Text("Apple Speech needs no setup. whisper.cpp runs on this Mac too and knows many more languages; install it with `brew install whisper-cpp` and add a model below.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Section("whisper.cpp") {
                Picker("Model", selection: $model) {
                    Text("Automatic").tag("")
                    ForEach(models, id: \.name) { m in
                        Text("\(m.name) (\(ByteCountFormatter.string(fromByteCount: m.bytes, countStyle: .file)))").tag(m.name)
                    }
                    if !model.isEmpty, !models.contains(where: { $0.name == model }) {
                        Text("\(model) (missing)").tag(model)
                    }
                }
                .accessibilityIdentifier("settings.captions.model")
                HStack {
                    Button("Show Models Folder") {
                        let dir = WhisperCppRecognizer.defaultModelsDirectory
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                    Button("Refresh") { refresh() }
                }
                Text("Put ggml model files (e.g. ggml-small.bin from the whisper.cpp project) in ~/Library/Application Support/WizRec/models.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Skip silences (voice activity detection)", isOn: $vad)
                    .accessibilityIdentifier("settings.captions.vad")
                Text(vadModel.map { String(localized: "Uses \($0) from the models folder.") }
                     ?? String(localized: "Without a Silero VAD model (ggml-silero-*.bin) in the models folder, silences are detected from the audio level."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("whisper-cli path", text: $binaryPath, prompt: Text("Search automatically"))
                    Button("Choose…") { chooseBinary() }
                }
                if binaryPath.isEmpty {
                    Text(found.map { String(localized: "Found: \($0.path)") } ?? String(localized: "whisper-cli not found"))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Label(status, systemImage: ready ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(ready ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(backend != Self.whisperID)
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onChange(of: model) { _, _ in refresh() }
        .onChange(of: binaryPath) { _, _ in refresh() }
    }

    private func refresh() {
        models = WhisperCppRecognizer.installedModels()
        vadModel = WhisperCppRecognizer.preferredVADModel(in: WhisperCppRecognizer.installedVADModels())?.name
        let w = WhisperCppRecognizer.fromDefaults()
        found = w.resolvedBinary()
        Task { @MainActor in
            let s = await w.status(language: nil)
            ready = s == .ready
            status = EditorWindowController.describe(s, backend: Self.whisperID)
        }
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        panel.message = String(localized: "Choose the whisper-cli executable")
        if panel.runModal() == .OK, let url = panel.url { binaryPath = url.path }
    }
}

private struct PrivacySettings: View {
    @AppStorage(AppPreferences.Key.crashLogsEnabled) private var crashLogs = false
    @State private var count = CrashLog.reports().count

    var body: some View {
        Form {
            Toggle("Save crash reports on this Mac", isOn: $crashLogs)
                .onChange(of: crashLogs) { _, on in CrashLog.setEnabled(on) }
            Text("Reports stay in ~/Library/Logs/WizRec. WizRec never sends them anywhere; attach one to a bug report yourself if you like. They hold the app and macOS version and a backtrace, never project content.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Show Crash Reports") {
                    let dir = CrashLog.defaultDirectory
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
                Button("Delete Crash Reports") {
                    CrashLog.deleteAll()
                    count = CrashLog.reports().count
                }
                .disabled(count == 0)
                Spacer()
                Text("^[\(count) report](inflect: true)").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { count = CrashLog.reports().count }
    }
}
