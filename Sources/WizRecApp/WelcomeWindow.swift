import AppKit
import PlayerKit
import SwiftUI

/// First-launch onboarding (Help ▸ Welcome to WizRec): what WizRec does, the permissions
/// recording asks for, and the crash-report opt-in. Finishing it sets
/// `AppPreferences.onboardingCompleted`. Closing it with no project open shows the start screen.
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    static let shared = WelcomeWindowController()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = String(localized: "Welcome to WizRec")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: WelcomeView(finish: { [weak self] action in
            self?.finish(action)
        }))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func present() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    enum Action { case close, newProject, open }

    /// Closed (Get Started or the close button) with no project open: the start screen.
    func windowWillClose(_ notification: Notification) {
        guard !AppEnvironment.terminating, NSDocumentController.shared.documents.isEmpty else { return }
        DispatchQueue.main.async { StartWindowController.shared.present() }
    }

    private func finish(_ action: Action) {
        UserDefaults.standard.set(true, forKey: AppPreferences.Key.onboardingCompleted)
        close()
        let dc = NSDocumentController.shared
        switch action {
        case .close: break
        case .newProject: dc.newDocument(nil)
        case .open: dc.openDocument(nil)
        }
    }
}

struct WelcomeView: View {
    let finish: (WelcomeWindowController.Action) -> Void
    @State private var page = 0
    @AppStorage(AppPreferences.Key.crashLogsEnabled) private var crashLogs = false
    private let pages = 3

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: intro
                case 1: permissions
                default: privacy
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 36).padding(.top, 40)
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<pages, id: \.self) { i in
                        Circle().fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Page \(page + 1) of \(pages)")
                Spacer()
                if page > 0 { Button("Back") { page -= 1 } }
                if page < pages - 1 {
                    Button("Continue") { page += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Get Started") { finish(.close) }.keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("welcome.getStarted")
                }
            }
            .padding(20)
        }
        .frame(width: 560, height: 420)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text("Welcome to WizRec").font(.largeTitle.weight(.semibold))
                    Text("Free, open-source screen recorder & editor by Devs Wizard.").foregroundStyle(.secondary)
                }
            }
            feature("film.stack", "Opens your Camtasia projects",
                    "Open .cmproj and .tscproj files from any Mac or PC, edit them, and save them back.")
            feature("record.circle", "Record your screen",
                    "Capture the screen, a window or a region with camera, microphone and system audio.")
            feature("timeline.selection", "Edit on a multi-track timeline",
                    "Cut, trim, group, add effects, transitions, captions, and export MP4, MOV or GIF.")
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Permissions").font(.title.weight(.semibold))
            Text("macOS asks before WizRec can record. Nothing is requested until you use the feature.")
                .foregroundStyle(.secondary)
            feature("rectangle.dashed.badge.record", "Screen & System Audio Recording",
                    "Needed to record the screen. Grant it in System Settings ▸ Privacy & Security when asked.")
            feature("mic", "Microphone and Camera", "Only when you turn them on in the recorder.")
            feature("keyboard", "Accessibility (optional)",
                    "Lets recordings log keystrokes and clicks for cursor effects. Off unless you enable it.")
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your privacy").font(.title.weight(.semibold))
            Text("WizRec has no account, no analytics and sends nothing over the network.")
                .foregroundStyle(.secondary)
            Toggle(isOn: $crashLogs) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save crash reports on this Mac")
                    Text("Kept in ~/Library/Logs/WizRec so you can attach one to a bug report. Never sent. Change it any time in Settings.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .onChange(of: crashLogs) { _, on in CrashLog.setEnabled(on) }
            .toggleStyle(.checkbox)
        }
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(Color.accentColor)
                .frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
