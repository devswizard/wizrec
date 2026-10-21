import AppKit
import Observation
import PlayerKit
import SwiftUI
import UniformTypeIdentifiers

/// The start screen (Window ▸ Start Screen, ⇧⌘1): recent projects plus New Project, New
/// Recording, Open Project… and Import Media…; projects or media dropped on it open.
/// Shown at launch when no project opens (`AppPreferences.launchWindow`) and again when the
/// last project window closes (`StartScreenPolicy`). Closes itself once a project window opens.
@MainActor
final class StartWindowController: NSWindowController, NSWindowDelegate {
    /// Created on first use (scripted runs never build it).
    private static var instance: StartWindowController?
    static var shared: StartWindowController {
        if let i = instance { return i }
        let i = StartWindowController()
        instance = i
        return i
    }

    /// Closes the start screen if it was ever built and is up.
    static func dismissIfShown() { instance?.dismissForProject() }

    /// Refreshes the recent list if the start screen is up (e.g. after Clear Menu).
    static func reloadIfShown() { if instance?.isShown == true { instance?.model.reload() } }

    let model = StartScreenModel()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = String(localized: "Start Screen")
        window.identifier = NSUserInterfaceItemIdentifier("WizRec.StartScreen")
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.tabbingMode = .disallowed
        // Window ▸ Start Screen lists it; keep it out of the window list below.
        window.isExcludedFromWindowsMenu = true
        super.init(window: window)
        window.delegate = self
        let host = NSHostingController(rootView: StartView(model: model))
        host.sizingOptions = [.minSize]
        window.contentViewController = host
        window.setContentSize(NSSize(width: 900, height: 580))
        window.isRestorable = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var isShown: Bool { window?.isVisible == true }

    func present() {
        model.reload()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        print("WizRec: start screen shown recent=\(model.rows.count)")
        fflush(stdout)
    }

    /// A project window opened: the start screen steps aside.
    func dismissForProject() {
        guard isShown else { return }
        close()
    }

    func windowDidBecomeKey(_ notification: Notification) { model.reload() }
}

// MARK: - Model

/// Recent rows and their thumbnails for `StartView`. Thumbnails load off the main thread
/// (`RecentProjects.thumbnailData` parses the project) and are cached by path and date.
@MainActor @Observable
final class StartScreenModel {
    private(set) var rows: [RecentProject] = []
    private(set) var thumbnails: [String: NSImage] = [:]
    /// Paths whose thumbnail is loaded (or known to be absent), with the date it was read at.
    @ObservationIgnored private var loaded: [String: Date] = [:]

    /// The recent documents shown: the UI-check override when given, else AppKit's list.
    static func recentURLs(defaults: UserDefaults = .standard) -> [URL] {
        if let paths = defaults.stringArray(forKey: RecentProjects.overrideKey) {
            return paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        }
        return NSDocumentController.shared.recentDocumentURLs
    }

    /// A UI check replaced the recent list (`RecentProjects.overrideKey`).
    static var overridden: Bool { UserDefaults.standard.object(forKey: RecentProjects.overrideKey) != nil }

    static func hidden(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: RecentProjects.hiddenKey) ?? [])
    }

    /// Recent rows without the hidden ones (also used by File ▸ Open Recent).
    static func visibleRecents() -> [URL] {
        let urls = recentURLs()
        let hidden = RecentProjects.pruned(hidden: hidden(), recents: urls)
        return urls.filter { !hidden.contains($0.standardizedFileURL.path) }
    }

    func reload() {
        let urls = Self.recentURLs()
        let stored = Self.hidden()
        let hidden = RecentProjects.pruned(hidden: stored, recents: urls)
        // Never prune against a UI check's override list (that would rewrite the user's list).
        if hidden != stored, !Self.overridden {
            UserDefaults.standard.set(Array(hidden).sorted(), forKey: RecentProjects.hiddenKey)
        }
        let fresh = RecentProjects.list(urls, hidden: hidden)
        if fresh != rows { rows = fresh }
        for row in fresh where row.exists {
            let stamp = row.modified ?? .distantPast
            guard loaded[row.id] != stamp else { continue }
            loaded[row.id] = stamp
            let url = row.url, id = row.id
            Task.detached(priority: .utility) {
                let data = RecentProjects.thumbnailData(projectAt: url)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let data, let image = NSImage(data: data) {
                        self.thumbnails[id] = image
                    } else {
                        self.thumbnails[id] = nil
                    }
                }
            }
        }
    }

    /// Remove from List: hidden until the project is opened again (`noteNewRecentDocumentURL`).
    func remove(_ ids: Set<String>) {
        var hidden = Self.hidden()
        hidden.formUnion(ids)
        if Self.overridden {
            // UI checks: hide for this run only (the argument domain beats the stored value).
            let d = UserDefaults.standard
            var args = d.volatileDomain(forName: UserDefaults.argumentDomain)
            args[RecentProjects.hiddenKey] = Array(hidden).sorted()
            d.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
        } else {
            UserDefaults.standard.set(Array(hidden).sorted(), forKey: RecentProjects.hiddenKey)
        }
        reload()
    }

    func row(_ id: String) -> RecentProject? { rows.first { $0.id == id } }
}

// MARK: - Actions

/// What the start screen's buttons do (also File ▸ New Recording / Import Media… with no
/// project window open, through `AppDelegate`).
@MainActor
enum StartActions {
    static var controller: WizRecDocumentController? { NSDocumentController.shared as? WizRecDocumentController }

    static func newProject() { NSDocumentController.shared.newDocument(nil) }

    static func newRecording() {
        do {
            try controller?.newProjectEditor()?.newRecording(nil)
        } catch {
            NSApp.presentError(error)
        }
    }

    static func openProject() { NSDocumentController.shared.openDocument(nil) }

    /// Import Media…: video, audio or image files start a new project with them on the timeline.
    static func importMedia() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audiovisualContent, .image]
        panel.message = String(localized: "Choose video, audio or image files to start a new project with.")
        panel.prompt = String(localized: "Import")
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { controller?.openFiles(urls) }
        }
    }

    static func open(_ row: RecentProject, model: StartScreenModel) {
        guard row.exists else {
            let alert = NSAlert()
            alert.messageText = String(localized: "“\(row.name)” can’t be found")
            alert.informativeText = String(localized: "It was moved, renamed or deleted: \(row.url.path)")
            alert.addButton(withTitle: String(localized: "Remove from List"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            if alert.runModal() == .alertFirstButtonReturn { model.remove([row.id]) }
            return
        }
        controller?.openFiles([row.url])
    }

    static func showInFinder(_ rows: [RecentProject]) {
        let urls = rows.filter(\.exists).map(\.url)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
}

// MARK: - View

struct StartView: View {
    let model: StartScreenModel
    @AppStorage(AppPreferences.Key.showStartScreenAtLaunch) private var showAtLaunch = true
    @State private var selection: Set<String> = []
    @State private var dropTargeted = false
    @FocusState private var listFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            actions
                .frame(width: 320)
                .frame(maxHeight: .infinity)
                .background(.regularMaterial)
            Divider()
            recents
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 520, idealHeight: 580)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            StartDrop.open(providers)
            return true
        }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: model.rows) { _, _ in selectFirstIfNeeded() }
    }

    // MARK: Actions column

    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "WizRec").font(.title.weight(.semibold))
                    Text(Self.versionText).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 44).padding(.bottom, 28)
            VStack(spacing: 10) {
                StartActionButton(symbol: "plus.rectangle.on.rectangle", title: "New Project",
                                  detail: "An empty 1080p timeline", shortcut: "⌘N", id: "start.newProject",
                                  action: StartActions.newProject)
                StartActionButton(symbol: "record.circle", title: "New Recording",
                                  detail: "Record the screen into a new project", shortcut: "⌘R",
                                  id: "start.newRecording", tint: .red, action: StartActions.newRecording)
                StartActionButton(symbol: "folder", title: "Open Project…",
                                  detail: "A .cmproj or .tscproj from any Mac or PC", shortcut: "⌘O",
                                  id: "start.openProject", action: StartActions.openProject)
                StartActionButton(symbol: "square.and.arrow.down", title: "Import Media…",
                                  detail: "Start a project from video, audio or images", shortcut: "⌘I",
                                  id: "start.importMedia", action: StartActions.importMedia)
            }
            Spacer(minLength: 16)
            Text("Drop projects or media files anywhere in this window.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
            Toggle("Show start screen at launch", isOn: $showAtLaunch)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("start.showAtLaunch")
        }
        .padding(.horizontal, 22).padding(.bottom, 20)
    }

    private static var versionText: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return v.map { String(localized: "Version \($0)") } ?? String(localized: "Screen recorder & editor")
    }

    // MARK: Recents column

    @ViewBuilder private var recents: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Projects").font(.title2.weight(.semibold))
                .padding(.horizontal, 20).padding(.top, 44).padding(.bottom, 10)
                .accessibilityAddTraits(.isHeader)
            if model.rows.isEmpty {
                emptyState
            } else {
                recentList
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack").font(.system(size: 40)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("No recent projects").font(.headline)
            Text("Projects you open or save appear here. Open a Camtasia project, start a new one, or drop files here.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("start.recents.empty")
    }

    private var recentList: some View {
        List(selection: $selection) {
            ForEach(model.rows) { row in
                RecentRow(row: row, thumbnail: model.thumbnails[row.id])
                    .tag(row.id)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .focused($listFocused)
        .accessibilityIdentifier("start.recents")
        .accessibilityLabel("Recent Projects")
        .contextMenu(forSelectionType: String.self) { ids in
            let picked = ids.compactMap { model.row($0) }
            if !picked.isEmpty {
                Button("Open") { picked.filter(\.exists).forEach { StartActions.open($0, model: model) } }
                    .disabled(!picked.contains(where: \.exists))
                Button("Show in Finder") { StartActions.showInFinder(picked) }
                    .disabled(!picked.contains(where: \.exists))
                Divider()
                Button("Remove from List") { model.remove(Set(ids)) }
            }
        } primaryAction: { ids in
            // Double-click or Return.
            for id in ids { if let row = model.row(id) { StartActions.open(row, model: model) } }
        }
        .onDeleteCommand { model.remove(selection) }
    }

    private func selectFirstIfNeeded() {
        let ids = Set(model.rows.map(\.id))
        selection = selection.intersection(ids)
        if selection.isEmpty, let first = model.rows.first(where: \.exists) ?? model.rows.first {
            selection = [first.id]
        }
        if !model.rows.isEmpty { listFocused = true }
    }
}

/// One big button of the actions column.
private struct StartActionButton: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let shortcut: String
    let id: String
    var tint: Color = .accentColor
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Text(verbatim: shortcut).font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(hovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.035)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(detail))
        .accessibilityIdentifier(id)
    }
}

/// One recent project: thumbnail (its own, or a generated placeholder), name, folder, date.
private struct RecentRow: View {
    let row: RecentProject
    let thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 14) {
            preview
                .frame(width: 112, height: 63)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(row.folder).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Text(dateText).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .opacity(row.exists ? 1 : 0.45)
        .help(row.url.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityIdentifier("start.recent.\(row.name)")
    }

    @ViewBuilder private var preview: some View {
        if let thumbnail {
            Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
        } else {
            let hue = RecentProjects.placeholderHue(for: row.name)
            ZStack {
                LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.78),
                                        Color(hue: hue, saturation: 0.6, brightness: 0.45)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: row.exists ? "film" : "questionmark.folder")
                    .font(.system(size: 22, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private var dateText: String {
        guard row.exists else { return String(localized: "Not found") }
        guard let d = row.modified else { return "" }
        return String(localized: "Modified \(d.formatted(date: .abbreviated, time: .shortened))")
    }

    private var accessibilityText: String {
        let state = row.exists ? dateText : String(localized: "not found")
        return "\(row.name), \(row.folder), \(state)"
    }
}

/// Files dropped on the start screen: projects open, media start a new project.
enum StartDrop {
    static func open(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let collected = URLBox()
        for (i, p) in providers.enumerated() where p.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { collected.append(i, url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = collected.urls
            MainActor.assumeIsolated { StartActions.controller?.openFiles(urls) }
        }
    }

    /// Dropped URLs collected from the item providers' callback queues.
    private final class URLBox: @unchecked Sendable {
        // @unchecked: every access holds `lock`.
        private let lock = NSLock()
        private var items: [(Int, URL)] = []
        func append(_ i: Int, _ u: URL) { lock.lock(); items.append((i, u)); lock.unlock() }
        /// In drop order.
        var urls: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return items.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
