import AppKit
import Captions
import Exporter
import MediaEngine
import MetalKit
import PlayerKit
import QuartzCore
import Recorder
import SwiftUI
import TimelineEngine
import TimelineUI
import TSCProjKit
import UniformTypeIdentifiers
import WizRecAssets

/// The editor window: media bin | canvas + transport | inspector, timeline below.
///
/// Split positions and the window frame persist in UserDefaults (never in the project).
/// The canvas is an `MTKView` drawn on demand from a display link that drives
/// `PlaybackEngine.tick`. After every project change the scene is rebuilt
/// (`EditorDocumentModel.onChange`) and swapped into the engine at the same playhead.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSToolbarItemValidation {
    let model: EditorDocumentModel
    let engine: PlaybackEngine
    let ui = EditorUIState()
    let timelineModel: TimelineModel
    let inspector = InspectorState()
    private weak var projectDocument: ProjectDocument?
    let options: LaunchOptions
    private let canvas: EditorCanvasView
    private let selectionOverlay = SelectionOverlayView()
    private let timelineView: TimelineUI.TimelineView
    private var providerDirectory: URL?
    private let thumbnails: ThumbnailStore
    private var renderer: CanvasRenderer?
    private var link: CADisplayLink?
    private var keyMonitor: Any?
    private var didAnnounce = false
    private var lastPlayheadSync: Int64 = -1
    private var lastSelection: Set<Int64> = []
    private var lastTimelineError: String?
    private var relinkWindow: NSWindow?
    private var relinkStatus: String?
    private var recorderHUD: RecorderHUDController?
    /// Tab / Shift-Tab between the panes: library sidebar → canvas → inspector → timeline.
    let keyLoop = EditorKeyLoop()
    /// Enabled state of the timeline toolbar's buttons, and what it was last computed from.
    let timelineTools = TimelineToolbarState()
    private var timelineToolsKey: [Int64] = []
    /// The toolbar's delegate (NSToolbar holds it weakly).
    private let toolbarItems = EditorToolbar()
    /// The last media drop into an open group while it imports and places (`placeInGroup`).
    private var groupDrop: Task<Void, Never>?
    /// Playhead (ticks) when the current recording started; the result is placed there.
    private var recordingStart: Int64 = 0
    /// The running transcription (Captions ▸ Transcribe); cancel with Captions ▸ Cancel.
    var transcription: Task<Void, Never>?
    /// File ▸ Export… sheet while shown, its remembered choices, and the job queue.
    var exportSheet: NSWindow?
    let exportState = ExportSheetState()
    var exportSpecs: [Int: ExportJobSpec] = [:]
    /// Asks before a close or quit cancels running exports.
    let exportCloseGuard = ExportCloseGuard()
    /// Exports decode on their own pool so they never evict playback frames.
    lazy var exportPool = MediaPool(cacheLimitBytes: 256 << 20)
    lazy var exportQueue: ExportQueue = Self.makeExportQueue(
        specs: { [weak self] id in self?.exportSpecs[id] },
        pool: { [weak self] in self?.exportPool ?? MediaPool(cacheLimitBytes: 64 << 20) })

    init(document: ProjectDocument, model: EditorDocumentModel, options: LaunchOptions) {
        self.model = model
        self.options = options
        projectDocument = document
        engine = model.makeEngine(audio: options.audio)
        timelineModel = TimelineModel(undo: model.undo)
        thumbnails = ThumbnailStore(pool: model.thumbnailPool)
        ui.showOverlay = options.overlay
        canvas = EditorCanvasView(frame: NSRect(x: 0, y: 0, width: 960, height: 540), device: MTLCreateSystemDefaultDevice())
        timelineView = TimelineUI.TimelineView(model: timelineModel)

        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        window.contentMinSize = NSSize(width: 900, height: 560)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        super.init(window: window)
        window.toolbar = toolbarItems.make(autosave: !options.isScripted)
        window.editor = self
        window.delegate = self
        canvas.editor = self
        selectionOverlay.editor = self
        canvas.registerForDraggedTypes(MediaDrop.types)

        renderer = CanvasRenderer(view: canvas)
        renderer?.engine = engine
        if renderer == nil { ui.compositorError = "Metal is not available on this Mac." }
        buildLayout(in: window)
        shouldCascadeWindows = false
        // `--window-size` runs leave the saved frame alone (no autosave name, no restore).
        if options.windowSize == nil { windowFrameAutosaveName = "WizRec.EditorWindow" }

        timelineModel.onSeek = { [weak self] t in self?.engine.seek(toTicks: t) }
        timelineModel.onDrop = { [weak self] payload, track, ticks in
            guard let self else { return false }
            switch payload {
            case .files(let urls): self.place(.files(urls), track: track, at: ticks)
            case .sources(let ids): self.place(.sources(ids), track: track, at: ticks)
            }
            return true
        }
        timelineModel.onGroupDrop = { [weak self] payload, target in
            guard let self else { return false }
            switch payload {
            case .files(let urls): self.placeInGroup(.files(urls), target)
            case .sources(let ids): self.placeInGroup(.sources(ids), target)
            }
            return true
        }
        updateMediaProvider()
        model.onChange = { [weak self] in self?.projectDidChange() }
        // `-WizRec.BackgroundLibraryRoot <dir>` (argument domain): where library backgrounds placed
        // into a Rev group are written (UI checks keep them out of Application Support).
        if let root = UserDefaults.standard.string(forKey: "WizRec.BackgroundLibraryRoot"), !root.isEmpty {
            model.backgroundLibraryRoot = URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true)
        }
        inspector.timebase = model.project.timebase

        engine.highSpeedPolicyEnabled = options.framePolicy != "exact"
        engine.useNearestDecoded = options.framePolicy == "nearest"
        if let s = options.seekSeconds { engine.seek(toTicks: model.scene.timebase.ticks(seconds: s)) }
        if options.statsLog {
            let name = model.bundle.directory.lastPathComponent
            engine.onStats = { s in print("stats [\(name)] \(s.line)"); fflush(stdout) }
        }
        refreshInspector()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Layout

    private func buildLayout(in window: NSWindow) {
        let bar = NSHostingView(rootView: TransportBar(engine: engine))
        let overlay = PassthroughHostingView(rootView: CanvasOverlay(
            engine: engine, model: model, ui: ui,
            relink: { [weak self] in self?.showRelink(nil) },
            record: { [weak self] in self?.newRecording(nil) },
            importMedia: { [weak self] in self?.importMedia(nil) }))
        overlay.dropTarget = canvas
        let center = NSView()
        for v in [canvas, selectionOverlay, overlay, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            center.addSubview(v)
        }
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: center.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: center.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: TransportBar.height),
        ])
        for v in [selectionOverlay, overlay] as [NSView] {
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
                v.topAnchor.constraint(equalTo: canvas.topAnchor),
                v.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
            ])
        }
        center.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true

        let bin = NSHostingView(rootView: SidebarView(model: model, thumbnails: thumbnails, actions: BinActions(
            importMedia: { [weak self] in self?.importMedia(nil) },
            importFiles: { [weak self] urls in self?.importFiles(urls, place: false) },
            insert: { [weak self] id in self?.insertSource(id) },
            relink: { [weak self] id in self?.locate(id) }),
            library: LibraryActions(apply: { [weak self] kind, name in self?.applyLibraryItem(kind, name) ?? false })))
        let props = NSHostingView(rootView: InspectorView(state: inspector, actions: InspectorActions(
            preview: { [weak self] f, v in self?.previewField(f, v) },
            commit: { [weak self] in self?.commitPreview() },
            set: { [weak self] f, v in self?.setField(f, v) },
            setSpeed: { [weak self] v in self?.setSpeed(v) },
            setDuration: { [weak self] t in self?.setDuration(t) },
            setCaptionStyle: { [weak self] s in self?.setSelectedCaptionStyle(s) },
            previewBackground: { [weak self] n, v in self?.previewBackground(n, v) },
            setBackground: { [weak self] n, v in self?.setBackground(n, v) })))
        bin.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        props.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let top = EditorSplitView()
        top.isVertical = true
        top.dividerStyle = .thin
        for v in [bin, center, props] { top.addArrangedSubview(v) }
        top.setHoldingPriority(.defaultLow + 10, forSubviewAt: 0)
        top.setHoldingPriority(.defaultLow - 10, forSubviewAt: 1)
        top.setHoldingPriority(.defaultLow + 10, forSubviewAt: 2)
        top.defaultSizes = { size in [250, max(360, size.width - 250 - 290 - 2)] }
        if options.windowSize == nil { top.persist(as: "WizRec.EditorSplit.Panes") } else { top.useDefaultLayout() }

        let root = EditorSplitView()
        root.isVertical = false
        root.dividerStyle = .thick
        let tools = NSHostingView(rootView: TimelineToolbar(state: timelineTools, actions: timelineToolbarActions()))
        let timelinePane = NSView()
        for v in [tools, timelineView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            timelinePane.addSubview(v)
        }
        NSLayoutConstraint.activate([
            tools.leadingAnchor.constraint(equalTo: timelinePane.leadingAnchor),
            tools.trailingAnchor.constraint(equalTo: timelinePane.trailingAnchor),
            tools.topAnchor.constraint(equalTo: timelinePane.topAnchor),
            tools.heightAnchor.constraint(equalToConstant: TimelineToolbar.height),
            timelineView.leadingAnchor.constraint(equalTo: timelinePane.leadingAnchor),
            timelineView.trailingAnchor.constraint(equalTo: timelinePane.trailingAnchor),
            timelineView.topAnchor.constraint(equalTo: tools.bottomAnchor),
            timelineView.bottomAnchor.constraint(equalTo: timelinePane.bottomAnchor),
            timelineView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        for v in [top, timelinePane] as [NSView] { root.addArrangedSubview(v) }
        root.setHoldingPriority(.defaultLow - 10, forSubviewAt: 0)
        root.setHoldingPriority(.defaultLow + 10, forSubviewAt: 1)
        keyLoop.panes = [
            EditorKeyLoop.Pane(view: bin, ownsTabOrder: true),
            EditorKeyLoop.Pane(view: center, extraStops: [canvas]),
            EditorKeyLoop.Pane(view: props),
            EditorKeyLoop.Pane(view: timelinePane, singleStop: timelineView),
        ]
        root.defaultSizes = { size in [max(360, size.height - 230 - TimelineToolbar.height)] }
        if options.windowSize == nil { root.persist(as: "WizRec.EditorSplit.Timeline") } else { root.useDefaultLayout() }
        window.contentView = root
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard !didAnnounce, let window else { return }
        didAnnounce = true
        if let size = options.windowSize {
            window.setContentSize(size)
            window.center()
        } else if !window.setFrameUsingName("WizRec.EditorWindow") {
            window.center()
        }
        window.layoutIfNeeded()
        if let root = window.contentView as? EditorSplitView {
            root.applyDefaultsIfNeeded()
            root.layoutSubtreeIfNeeded()
            (root.arrangedSubviews.first as? EditorSplitView)?.applyDefaultsIfNeeded()
        }
        timelineView.zoomToFit(nil)
        // Keep keyboard shortcuts (Space, S, M) live: the library search field must not grab focus.
        window.makeFirstResponder(timelineView)
        startDisplayLink()
        installKeys()
        print("WizRec: opened \(model.bundle.directory.lastPathComponent) window=\(window.windowNumber) "
              + "canvas=\(Int(model.scene.canvasSize.width))x\(Int(model.scene.canvasSize.height)) "
              + "fps=\(model.scene.frameRate) frames=\(engine.grid.frameCount) missing=\(model.missing.count)")
        fflush(stdout)
        if options.runsScript {
            Task { await runScript() }
        } else if options.autoplay {
            engine.play()
        }
        if options.showsRelinkAtOpen(missing: model.missing.count) { showRelink(nil) }
        if options.openGroup, let g = model.project.tracks.flatMap(\.clips).first(where: { $0.kind == .group }) {
            timelineModel.openGroups = [g.id]
            print("WizRec: opened group \(g.id) for editing")
            fflush(stdout)
        }
    }

    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        model.isUntitled ? "Untitled Project" : displayName
    }

    private func startDisplayLink() {
        let l = canvas.displayLink(target: self, selector: #selector(displayTick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        let needsDraw = engine.tick(host: link.targetTimestamp, timestamp: link.timestamp, period: link.duration)
        if needsDraw || options.drawAlways {
            canvas.draw()
            selectionOverlay.needsDisplay = true
            if let e = renderer?.compositorError, ui.compositorError != e { ui.compositorError = e }
        }
        if timelineModel.selection != lastSelection {
            lastSelection = timelineModel.selection
            refreshInspector()
            selectionOverlay.needsDisplay = true
        }
        if timelineModel.lastError != lastTimelineError {
            lastTimelineError = timelineModel.lastError
            if let e = lastTimelineError { ui.show(e) }
        }
        refreshTimelineTools()
        let t = engine.currentTicks
        if t != lastPlayheadSync {
            lastPlayheadSync = t
            timelineModel.playhead = t
            if !engine.isPlaying { refreshInspector() }
        }
    }

    // MARK: Timeline toolbar

    private func timelineToolbarActions() -> TimelineToolbarActions {
        TimelineToolbarActions(
            undo: { [weak self] in self?.undoEdit() },
            redo: { [weak self] in self?.redoEdit() },
            cut: { [weak self] in self?.cut(nil) },
            copy: { [weak self] in self?.copy(nil) },
            paste: { [weak self] in self?.paste(nil) },
            split: { [weak self] in self?.timelineView.splitAtPlayhead(nil) },
            delete: { [weak self] in self?.timelineView.delete(nil) },
            rippleDelete: { [weak self] in self?.timelineView.rippleDelete(nil) },
            addTrack: { [weak self] in self?.timelineView.addTrack(nil) },
            toggleSnapping: { [weak self] in self?.timelineView.toggleSnapping(nil) },
            zoomOut: { [weak self] in self?.timelineView.zoomOut(nil) },
            zoomToFit: { [weak self] in self?.timelineView.zoomToFit(nil) },
            zoomIn: { [weak self] in self?.timelineView.zoomIn(nil) })
    }

    /// Re-validates the timeline toolbar when something it depends on changed (cheap otherwise).
    private func refreshTimelineTools() {
        let undo = model.undo
        let key: [Int64] = [Int64(model.revision), engine.currentTicks, Int64(NSPasteboard.general.changeCount),
                            Int64(timelineModel.selection.count), timelineModel.selection.min() ?? -1,
                            Int64(undo.canUndo ? 1 : 0) + Int64(undo.canRedo ? 2 : 0),
                            Int64(timelineModel.pointsPerSecond * 1000), timelineModel.snappingEnabled ? 1 : 0]
        guard key != timelineToolsKey else { return }
        timelineToolsKey = key
        func valid(_ action: Selector) -> Bool { validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")) }
        let s = timelineTools
        func set<T: Equatable>(_ path: ReferenceWritableKeyPath<TimelineToolbarState, T>, _ v: T) {
            if s[keyPath: path] != v { s[keyPath: path] = v }
        }
        set(\.canUndo, undo.canUndo)
        set(\.canRedo, undo.canRedo)
        set(\.undoName, undo.undoName)
        set(\.redoName, undo.redoName)
        set(\.canCut, valid(#selector(cut(_:))))
        set(\.canCopy, valid(#selector(copy(_:))))
        set(\.canPaste, valid(#selector(paste(_:))))
        set(\.canSplit, timelineView.validateMenuItem(NSMenuItem(title: "", action: #selector(TimelineUI.TimelineView.splitAtPlayhead(_:)), keyEquivalent: "")))
        set(\.canDelete, timelineView.validateMenuItem(NSMenuItem(title: "", action: #selector(TimelineUI.TimelineView.delete(_:)), keyEquivalent: "")))
        set(\.canZoomIn, timelineView.validateMenuItem(NSMenuItem(title: "", action: #selector(TimelineUI.TimelineView.zoomIn(_:)), keyEquivalent: "")))
        set(\.canZoomOut, timelineView.validateMenuItem(NSMenuItem(title: "", action: #selector(TimelineUI.TimelineView.zoomOut(_:)), keyEquivalent: "")))
        set(\.snapping, timelineModel.snappingEnabled)
    }

    // MARK: Project changes

    /// Timeline thumbnails/waveforms resolve media against the bundle folder, which moves on Save As.
    private func updateMediaProvider() {
        let dir = model.bundle.directory
        guard dir != providerDirectory else { return }
        providerDirectory = dir
        timelineView.mediaProvider = MediaPoolTimelineProvider(pool: model.thumbnailPool, bundleDirectory: dir)
    }

    private func projectDidChange() {
        engine.replaceScene(model.scene, audioScene: model.audioScene)
        updateMediaProvider()
        projectDocument?.refreshEditedState()
        let kept = timelineModel.selection.filter { ClipInspection.make(project: model.project, clipID: $0, playhead: 0) != nil }
        if kept != timelineModel.selection { timelineModel.selection = kept }
        refreshInspector()
        selectionOverlay.needsDisplay = true
        window?.title = windowTitle(forDocumentDisplayName: projectDocument?.displayName ?? "")
    }

    func select(_ ids: Set<Int64>) {
        timelineModel.selection = ids
        refreshInspector()
        selectionOverlay.needsDisplay = true
    }

    func inspection(of clipID: Int64) -> ClipInspection? {
        ClipInspection.make(project: model.project, clipID: clipID, playhead: engine.currentTicks)
    }

    private func refreshInspector() {
        let sel = timelineModel.selection
        inspector.selectionCount = sel.count
        let next = sel.count == 1 ? sel.first.flatMap(inspection(of:)) : nil
        if inspector.grid != engine.grid { inspector.grid = engine.grid }
        // Clip Speed works on top-level clips with media time (not images or annotations).
        inspector.speedEditable = next.map { n in
            !["IMFile", "Callout"].contains(n.typeName)
                && model.project.tracks.contains { $0.clips.contains { $0.id == n.clipID } }
        } ?? false
        if next != inspector.inspection { inspector.inspection = next }
        let caption = selectedDynamicCaption?.style
        if caption != inspector.captionStyle { inspector.captionStyle = caption }
    }

    // MARK: Edits

    func run(_ what: String, _ body: () throws -> Void) {
        do {
            try body()
            inspector.error = nil
        } catch {
            inspector.error = "\(what): \(Self.describe(error))"
            ui.show("\(what) failed: \(Self.describe(error))")
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let e as DocumentError: e.description
        case let e as EditError:
            switch e {
            case .invalid(let s): s
            case .clipNotFound(let id): "clip \(id) not found"
            case .trackNotFound(let i): "track \(i + 1) not found"
            }
        case let e as BundleWriteError:
            switch e {
            case .notImplemented: "not implemented yet"
            case .exists(let u): "\(u.lastPathComponent) already exists"
            case .copyFailed(let s): s
            }
        default: (error as NSError).localizedDescription
        }
    }

    func preview(_ changes: [EditorDocumentModel.ParameterChange]) {
        guard !changes.isEmpty else { return }
        run("Change property") { try model.preview(changes) }
    }

    func commitPreview() { run("Change property") { try model.commitPreview() } }

    private func previewField(_ f: InspectorField, _ v: Double) {
        guard let i = inspector.inspection else { return }
        preview(i.changes(f, v))
    }

    private func setField(_ f: InspectorField, _ v: Double) {
        guard let i = inspector.inspection else { return }
        let changes = i.changes(f, v)
        guard !changes.isEmpty else { return }
        run("Change property") { try model.set(changes) }
    }

    /// Live shader background parameter values from the inspector (no undo step yet).
    private func previewBackground(_ name: String, _ values: [Double]) {
        guard let s = inspector.inspection?.shader else { return }
        preview(s.parameterChanges(name, values))
    }

    /// Shader background parameter values from the inspector: one undo step ("Change Background").
    private func setBackground(_ name: String, _ values: [Double]) {
        guard let s = inspector.inspection?.shader else { return }
        let changes = s.parameterChanges(name, values)
        guard !changes.isEmpty else { return }
        run("Change background") { try model.set(changes) }
    }

    /// Clip speed from the inspector (exact rational, two-decimal precision); later clips ripple.
    /// The duration is floored to a frame and the media range kept (ED2b).
    private func setSpeed(_ speed: Rational) {
        guard let i = inspector.inspection, speed.num > 0, speed.den > 0 else { return }
        run(String(localized: "Clip Speed")) { try model.perform(SetClipSpeed(clipID: i.clipID, speed: speed, ripple: true)) }
    }

    /// Clip duration from the inspector's Clip Speed Duration field (ticks, floored to a frame by
    /// `SetClipDuration`); the media range is kept and later clips ripple (ED2b).
    private func setDuration(_ ticks: Int64) {
        guard let i = inspector.inspection, ticks > 0 else { return }
        run(String(localized: "Clip Speed")) { try model.perform(SetClipDuration(clipID: i.clipID, duration: ticks, ripple: true)) }
    }

    func undoEdit() { run("Undo") { try model.undoLast() } }
    func redoEdit() { run("Redo") { try model.redoLast() } }

    // MARK: Library

    /// Library double-click: an effect goes onto every selected clip; a transition onto the
    /// cut at the playhead, else both edges of each selected clip (one undo step each).
    func applyLibraryItem(_ kind: LibraryItem.Kind, _ name: String) -> Bool {
        if kind == .audio, let item = AudioPanelItem(rawValue: name) { return applyAudioItem(item) }
        if kind == .callout, let preset = AssetCatalog.callout(id: name) { return insertCallout(preset) }
        if kind == .background, let bg = AssetCatalog.background(id: name) { return placeBackground(bg) }
        if kind == .background { return false }
        if timelineModel.selection.isEmpty, kind == .effect {
            ui.show(String(localized: "Select clips on the timeline first, or drag the effect onto a clip."))
            return false
        }
        let ok = kind == .effect ? timelineView.applyEffect(named: name) : timelineView.applyTransition(named: name)
        return ok
    }

    /// Audio library double-click: the item on every selected clip with audio, one undo step.
    /// Captions is Captions ▸ Add Captions.
    func applyAudioItem(_ item: AudioPanelItem) -> Bool {
        if item == .captions {
            addEmptyCaptions(nil)
            return true
        }
        guard let c = AudioPanel.command(item, project: model.project, selection: timelineModel.selection) else {
            ui.show(String(localized: "Select clips with audio on the timeline first."))
            return false
        }
        var ok = false
        run(item.displayName) { try model.perform(c); ok = true }
        return ok
    }

    /// Annotations library double-click: the callout at the playhead (5 s, above the clips
    /// there), selected. One undo step.
    func insertCallout(_ preset: CalloutPreset) -> Bool {
        let c = CalloutInsertion.command(preset, project: model.project, playhead: engine.currentTicks)
        var ok = false
        run(String(localized: "Add Callout")) { try model.perform(c); ok = true }
        if let id = c.clipID { select([id]) }
        return ok
    }

    /// Backgrounds library double-click: the background at the playhead (60 s, lowest free
    /// track), selected. With a group open on the timeline it goes on a new top inner track of
    /// that group at the playhead instead; the group never grows (`placeBackground(_:inGroup:atPlayhead:)`).
    /// One undo step ("Add Background").
    func placeBackground(_ bg: BackgroundAsset) -> Bool {
        let at = engine.currentTicks
        let group = timelineModel.openGroups.last
        ui.isImporting = true
        Task {
            defer { ui.isImporting = false }
            do {
                let clip: Int64
                if let group {
                    clip = try await model.placeBackground(bg, inGroup: group, atPlayhead: at)
                } else {
                    clip = try await model.placeBackground(bg, at: at)
                }
                select([clip])
            } catch {
                ui.show(String(localized: "Could not add \(bg.displayName): \(Self.describe(error))"))
            }
        }
        return true
    }

    /// Edit ▸ Add Audio Point:a volume point at the playhead on the selected clips with audio.
    @objc func addAudioPoint(_ sender: Any?) {
        guard let c = AudioPanel.addPointCommand(project: model.project, selection: timelineModel.selection,
                                                 playhead: engine.currentTicks) else {
            ui.show(String(localized: "Select a clip with audio under the playhead."))
            return
        }
        run(String(localized: "Add Audio Point")) { try model.perform(c) }
    }

    // MARK: Import and placement

    @objc func importMedia(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .audio, .image, .audiovisualContent]
            + [UTType(filenameExtension: "tscshadervid")].compactMap { $0 }   // shader backgrounds
        panel.message = "Choose media to add to the project's media bin."
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK else { return }
            MainActor.assumeIsolated { self?.importFiles(panel.urls, place: false) }
        }
    }

    /// Imports `urls` into the bin; with `place`, also onto the timeline at `ticks`. Projects
    /// among them open in their own window; folders and other documents are reported.
    func importFiles(_ given: [URL], place: Bool, track: Int? = nil, at ticks: Int64? = nil) {
        let sorted = DroppedFiles(given)
        if !sorted.projects.isEmpty { (NSDocumentController.shared as? WizRecDocumentController)?.openFiles(sorted.projects) }
        let unsupported = sorted.unsupportedMessage()
        let urls = sorted.media
        guard !urls.isEmpty else {
            if let unsupported { ui.show(unsupported, seconds: 10) }
            return
        }
        ui.isImporting = true
        Task {
            let r = await model.importInSequence(urls, place: place, from: ticks ?? engine.currentTicks, track: track)
            if let last = r.placed.last { select([last.clip]) }
            ui.isImporting = false
            // UI checks read this line (drops onto the bin, canvas and timeline).
            let placed = r.placed.map { "\($0.clip)@track\($0.track)" }.joined(separator: ",")
            print("WizRec: imported \(urls.count - r.failures.count) of \(urls.count) "
                  + "place=\(place) clips=[\(placed)] bin=\(model.project.sourceBin.count)")
            fflush(stdout)
            let failures = (unsupported.map { [$0] } ?? []) + r.failures.map { Self.importFailure($0.file, $0.error) }
            if !failures.isEmpty { ui.show(failures.joined(separator: " "), seconds: 10) }
        }
    }

    /// One plain sentence for a file that could not be imported.
    static func importFailure(_ url: URL, _ error: any Error) -> String {
        if case DocumentError.unsupportedMedia = error { return describe(error) }
        return String(localized: "“\(url.lastPathComponent)” couldn’t be imported: \(describe(error))")
    }

    /// Places a bin item at the playhead.
    func insertSource(_ id: Int64) { place(.sources([id]), track: nil, at: engine.currentTicks) }

    /// Handles a drop on the canvas or timeline: files are imported, then placed;
    /// bin items are placed one after another from `ticks`.
    func place(_ drop: MediaDrop, track: Int?, at ticks: Int64) {
        switch drop {
        case .files(let urls):
            importFiles(urls, place: true, track: track, at: ticks)
        case .sources(let ids):
            var t = ticks
            run("Add to timeline") {
                for id in ids {
                    let clip = try model.insertSource(id, at: t, track: track)
                    if let c = model.project.tracks.flatMap(\.clips).first(where: { $0.id == clip }) { t = c.end }
                    select([clip])
                }
            }
        }
    }

    /// Handles a drop inside an open group: files are imported, then everything is placed on
    /// the group's inner track one after another (one undo step).
    func placeInGroup(_ items: EditorDocumentModel.GroupPlacement, _ target: GroupDropTarget) {
        if case .files = items { ui.isImporting = true }
        groupDrop = Task {
            defer { ui.isImporting = false }
            do {
                let ids = try await model.placeInGroup(items, group: target.group, track: target.track, at: target.ticks)
                if let last = ids.last { select([last]) }
            } catch {
                ui.show(String(localized: "Cannot add to the group: \(Self.describe(error))"), seconds: 8)
            }
        }
    }

    // MARK: Recording

    /// File ▸ New Recording: shows the recorder panel. Each recording is written to the
    /// project's `recordings/<unix-ts>/` and, when it stops, placed at the playhead where it
    /// started (screen, camera and audio stacked on free tracks) as one undo step.
    @objc func newRecording(_ sender: Any?) {
        if let hud = recorderHUD { hud.present(); return }
        let hud = RecorderHUDController(
            outputDirectory: { [weak self] in self?.nextRecordingFolder() ?? RecorderHUDModel.defaultOutputDirectory() },
            onFinish: { [weak self] result in self?.recordingFinished(result) })
        recorderHUD = hud
        hud.present()
    }

    private func nextRecordingFolder() -> URL {
        recordingStart = engine.currentTicks
        let stamp = String(format: "%.6f", Date().timeIntervalSince1970)
        return model.bundle.directory.appendingPathComponent("recordings", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
    }

    private func recordingFinished(_ result: Result<RecordingResult, Error>) {
        switch result {
        case .failure(let e):
            ui.show("Recording failed: \(Self.describe(e))", seconds: 10)
        case .success(let r):
            let files = [r.screen] + (r.camera.map { [$0] } ?? []) + r.audio
            let start = recordingStart
            window?.makeKeyAndOrderFront(nil)
            Task {
                do {
                    let ids = try await model.importAndPlace(files, at: start, name: "Add Recording")
                    select(ids.first.map { [$0] } ?? [])
                    engine.seek(toTicks: start)
                } catch {
                    ui.show("Cannot add the recording: \(Self.describe(error)). Its files are in \(r.screen.deletingLastPathComponent().path).",
                            seconds: 12)
                }
            }
        }
    }

    // MARK: Relink

    @objc func showRelink(_ sender: Any?) {
        guard let window else { return }
        if let w = relinkWindow { window.beginSheet(w); return }
        let host = NSHostingController(rootView: relinkView())
        let sheet = NSWindow(contentViewController: host)
        relinkWindow = sheet
        window.beginSheet(sheet) { [weak self] _ in MainActor.assumeIsolated { self?.relinkWindow = nil } }
    }

    private func relinkView() -> RelinkView {
        RelinkView(model: model, actions: RelinkActions(
            locate: { [weak self] id in self?.locate(id) },
            searchFolder: { [weak self] in self?.searchFolder() },
            close: { [weak self] in
                guard let self, let w = self.relinkWindow else { return }
                self.window?.endSheet(w)
            }), status: relinkStatus)
    }

    private func refreshRelinkSheet() {
        (relinkWindow?.contentViewController as? NSHostingController<RelinkView>)?.rootView = relinkView()
    }

    /// Picks a replacement file for source `id`.
    func locate(_ id: Int64) {
        guard let host = relinkWindow ?? window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let src = model.project.source(id: id)?.src ?? ""
        panel.message = "Locate \((src.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent)"
        panel.beginSheetModal(for: host) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                Task {
                    do {
                        try await self.model.relink(id, to: url)
                        self.thumbnails.reset(url)
                        self.relinkStatus = "Relinked \(url.lastPathComponent)."
                    } catch {
                        self.relinkStatus = "Cannot relink: \(Self.describe(error))"
                        self.ui.show(self.relinkStatus ?? "")
                    }
                    self.refreshRelinkSheet()
                }
            }
        }
    }

    private func searchFolder() {
        guard let host = relinkWindow ?? window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder that holds the missing files (searched with subfolders)."
        panel.beginSheetModal(for: host) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                Task {
                    do {
                        let n = try await self.model.relinkAll(in: url).count
                        self.relinkStatus = n == 0 ? "No missing files found in \(url.lastPathComponent)."
                            : "Relinked \(n) file\(n == 1 ? "" : "s") from \(url.lastPathComponent)."
                    } catch {
                        self.relinkStatus = "Cannot relink: \(Self.describe(error))"
                    }
                    self.refreshRelinkSheet()
                }
            }
        }
    }

    // MARK: Script (verification without UI interaction)

    /// `--group-drop` files: opens the first top-level group (as a double-click does) and hands
    /// the files to the timeline's group-drop handler on inner track 0, after its last clip.
    private func runScriptedGroupDrops() async {
        let urls = options.groupDropPaths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        guard !urls.isEmpty else { return }
        guard let group = model.project.tracks.flatMap(\.clips).first(where: { $0.kind == .group }) else {
            print("script: group drop: no group on the timeline")
            return
        }
        timelineModel.openGroups = [group.id]
        let end = group.tracks.first?.clips.map(\.end).max() ?? 0
        let target = GroupDropTarget(group: group.id, groupPath: [group.id], track: 0, ticks: end)
        let accepted = timelineModel.onGroupDrop?(.files(urls), target) ?? false
        await groupDrop?.value
        let inner = model.project.tracks.flatMap(\.clips).first { $0.id == group.id }?.tracks.first?.clips.count ?? 0
        print("script: group drop into \(group.id) accepted=\(accepted) innerTrack0Clips=\(inner) "
              + "selection=\(timelineModel.selection.sorted()) message=\(ui.message ?? "none")")
    }

    /// `--import` files (placed at the playhead), `--nudge` the result, `--save`, then
    /// snapshots at `--snapshot-at` times into `--snapshot-dir`.
    private func runScript() async {
        try? await Task.sleep(nanoseconds: 300_000_000)  // let the window lay out
        for path in options.importPaths {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do {
                let clip = try await model.importAndInsert(url, at: engine.currentTicks)
                select([clip])
                print("script: imported \(url.lastPathComponent) as clip \(clip)")
            } catch {
                print("script: import \(url.lastPathComponent) failed: \(Self.describe(error))")
            }
        }
        await runScriptedGroupDrops()
        if let n = options.nudge, let id = timelineModel.selection.first, let i = inspection(of: id) {
            let x = (i.values[.positionX] ?? 0) + n.x, y = (i.values[.positionY] ?? 0) + n.y
            run("Move") { try model.set(i.changes(.positionX, x) + i.changes(.positionY, y)) }
            print("script: moved clip \(id) by \(n.x),\(n.y) px; error=\(inspector.error ?? "none")")
        }
        if let c = options.importCaptions {
            importCaptions(from: URL(fileURLWithPath: (c as NSString).expandingTildeInPath))
            print("script: captions now \(CaptionFiles.cues(in: model.project).count) cues; \(ui.message ?? "")")
        }
        if let c = options.exportCaptions {
            let url = URL(fileURLWithPath: (c as NSString).expandingTildeInPath)
            let text = url.pathExtension.lowercased() == "vtt" ? CaptionFiles.vtt(model.project) : CaptionFiles.srt(model.project)
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
                print("script: exported captions to \(url.path)")
            } catch {
                print("script: export captions failed: \(Self.describe(error))")
            }
        }
        if let path = options.exportPath {
            let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let all = ExportSession.presets
            let presets = options.exportPresets.isEmpty
                ? Array(all.first { $0.settings.format.fileExtension == file.pathExtension.lowercased() }.map { [$0] } ?? [])
                : options.exportPresets.compactMap { n in all.first { $0.name == n } }
            if presets.count != max(1, options.exportPresets.count) {
                print("script: unknown export preset; available: \(all.map(\.name).joined(separator: " | "))")
            }
            let started = Date()
            queueScriptedExports(presets, to: file)
            await exportQueue.waitUntilIdle()
            for j in exportQueue.jobs { print("script: export \(j.name) → \(j.output.path): \(j.state)") }
            print(String(format: "script: exports took %.1f s", Date().timeIntervalSince(started)))
        }
        if options.select, timelineModel.selection.isEmpty, let first = model.project.tracks.flatMap(\.clips).last {
            select([first.id])
        }
        if options.save {
            projectDocument?.save(nil)
            try? await Task.sleep(nanoseconds: 300_000_000)
            print("script: saved dirty=\(model.isDirty) edited=\(projectDocument?.isDocumentEdited ?? false)")
        }
        fflush(stdout)
        guard let dir = options.snapshotDir else { return }
        let out = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for t in options.snapshotTimes.isEmpty ? [0] : options.snapshotTimes {
            engine.seek(toTicks: model.scene.timebase.ticks(seconds: t))
            let settled = await engine.waitUntilSettled(timeout: 10)
            canvas.draw()
            try? await Task.sleep(nanoseconds: 300_000_000)
            refreshInspector()
                try? await Task.sleep(nanoseconds: 100_000_000)
            await writeSnapshot(to: out.appendingPathComponent(String(format: "frame-%06.2fs.png", t)),
                          note: settled ? "" : " (frames still decoding)")
        }
        if options.autoplay {
            engine.seek(toTicks: model.scene.timebase.ticks(seconds: options.seekSeconds ?? 0))
            engine.play()
            for n in 1...3 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await writeSnapshot(to: out.appendingPathComponent("playing-\(n).png"), note: "")
            }
        }
    }

    /// Window content as PNG, with the Metal canvas rendered offscreen into its frame
    /// (Metal layers are not captured by `cacheDisplay`). Everything is composed into a fresh
    /// bitmap: drawing into the rep `cacheDisplay` filled broke later SwiftUI captures.
    /// The canvas is rendered first (awaiting the GPU without blocking the main thread), then the
    /// window is cached, so both show the same state.
    private func writeSnapshot(to url: URL, note: String) async {
        guard let root = window?.contentView else { return }
        let scale = window?.backingScaleFactor ?? 2
        let rect = canvas.convert(canvas.bounds, to: root)
        let image = await renderer?.renderImage(size: CGSize(width: rect.width * scale, height: rect.height * scale))
        guard let cached = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: cached)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cached.pixelsWide, pixelsHigh: cached.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        out.size = root.bounds.size   // before the context, so drawing is in points
        guard let ctx = NSGraphicsContext(bitmapImageRep: out) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        cached.draw(in: root.bounds)
        // `rect` is in the root's (flipped or not) space; the bitmap uses a bottom-left origin.
        let r = root.isFlipped ? NSRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height) : rect
        if let image { ctx.cgContext.draw(image, in: r) }
        let overlays = canvas.superview?.subviews.filter { $0 is PassthroughHostingView<CanvasOverlay> } ?? []
        for v in [selectionOverlay] + overlays {
            if let top = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: top)
                top.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = out.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: url)
            print("snapshot \(url.path) t=\(model.scene.timebase.timecode(engine.currentTicks))\(note)")
        } catch {
            print("snapshot failed \(url.path): \(error)")
        }
        fflush(stdout)
    }

    // MARK: Keys

    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self.window, let window = self.window else { return false }
                // Tab / Shift-Tab: the window's pane loop decides at pane edges (library tiles
                // handle their own Tab and leave through `keyLoop.leave`).
                let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
                if event.keyCode == 48, mods.subtracting(.shift).isEmpty, window.attachedSheet == nil {
                    if window.firstResponder is LibraryTileAccessibility.Element { return false }
                    return self.keyLoop.handleTab(in: window, backward: mods.contains(.shift))
                }
                guard !(window.firstResponder is NSText) else { return false }
                // A focused library tile takes Space (press) instead of play/pause.
                if event.keyCode == 49, self.window?.firstResponder is LibraryTileAccessibility.Element { return false }
                return self.handleKey(event)
            }
            return handled ? nil : event
        }
    }

    /// Space play/pause, ←/→ frame step (⇧ = 1 s), Home/End or ⌘←/⌘→ start/end.
    private func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let fps = max(1, Int64(engine.grid.fps.double.rounded()))
        switch (e.keyCode, mods) {
        case (49, []): engine.togglePlay()
        case (123, []): engine.step(by: -1)
        case (124, []): engine.step(by: 1)
        case (123, [.shift]): engine.step(by: -fps)
        case (124, [.shift]): engine.step(by: fps)
        case (115, []), (123, [.command]): engine.goToStart()
        case (119, []), (124, [.command]): engine.goToEnd()
        case (1, []): timelineView.splitAtPlayhead(nil)       // S
        case (46, []): timelineView.addMarker(nil)            // M
        default: return false
        }
        return true
    }

    // MARK: Menu actions

    @objc func playPause(_ sender: Any?) { engine.togglePlay() }
    @objc func stepForward(_ sender: Any?) { engine.step(by: 1) }
    @objc func stepBackward(_ sender: Any?) { engine.step(by: -1) }
    @objc func goToStart(_ sender: Any?) { engine.goToStart() }
    @objc func goToEnd(_ sender: Any?) { engine.goToEnd() }
    @objc func togglePerformanceOverlay(_ sender: Any?) { ui.showOverlay.toggle() }

    /// Edit ▸ Delete: removes the selected clips (the timeline view handles it first when focused).
    @objc func delete(_ sender: Any?) {
        let ids = Array(timelineModel.selection)
        guard !ids.isEmpty else { return }
        run("Delete") { try model.perform(DeleteClips(clipIDs: ids)) }
    }

    // MARK: Clipboard and clip structure

    static let clipsType = NSPasteboard.PasteboardType("com.devswizard.wizrec.clips")
    static let clipsOriginType = NSPasteboard.PasteboardType("com.devswizard.wizrec.clips-origin")

    /// Selected clips that sit directly on a track (copy, group and stitch work on those).
    private var topLevelSelection: [Int64] {
        let top = Set(model.project.tracks.flatMap(\.clips).map(\.id))
        return model.project.tracks.flatMap(\.clips).map(\.id).filter { timelineModel.selection.contains($0) && top.contains($0) }
    }

    private func put(_ payload: ClipboardPayload) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(payload.data, forType: Self.clipsType)
        pb.setString(model.bundle.directory.path, forType: Self.clipsOriginType)
    }

    @objc func copy(_ sender: Any?) {
        let ids = model.clipboardSelection(timelineModel.selection, openGroup: timelineModel.openGroups.last)
        run("Copy") { put(try model.copyClips(ids)) }
    }

    @objc func cut(_ sender: Any?) {
        run("Cut") {
            put(try model.cutClips(model.clipboardSelection(timelineModel.selection,
                                                            openGroup: timelineModel.openGroups.last)))
            select([])
        }
    }

    @objc func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        guard let data = pb.data(forType: Self.clipsType), let payload = try? ClipboardPayload(data: data) else { return }
        let origin = pb.string(forType: Self.clipsOriginType).map { URL(fileURLWithPath: $0) }
        let group = timelineModel.openGroups.last
        let track = model.pasteTrack(timelineModel.selection, openGroup: group)
        let at = engine.grid.snap(engine.currentTicks)
        Task {
            do {
                let ids = try await model.paste(payload, origin: origin, track: track, at: at, group: group)
                select(Set(ids))
                if !model.missing.isEmpty { ui.show("Some pasted media is missing: File ▸ Relink Missing Media.") }
            } catch {
                ui.show("Paste failed: \(Self.describe(error))")
            }
        }
    }

    @objc func groupClips(_ sender: Any?) {
        let ids = topLevelSelection
        let c = GroupClips(clipIDs: ids)
        run("Group") { try model.perform(c) }
        if let g = c.groupID { select([g]) }
    }

    @objc func ungroupClip(_ sender: Any?) {
        guard let id = topLevelSelection.first else { return }
        let c = UngroupClip(clipID: id)
        run("Ungroup") { try model.perform(c) }
        if !c.releasedIDs.isEmpty { select(Set(c.releasedIDs)) }
    }

    @objc func stitchClips(_ sender: Any?) {
        let c = StitchClips(clipIDs: topLevelSelection)
        run("Stitch") { try model.perform(c) }
        if let s = c.stitchedID { select([s]) }
    }

    @objc func unstitchClip(_ sender: Any?) {
        guard let id = topLevelSelection.first else { return }
        let c = UnstitchClip(clipID: id)
        run("Unstitch") { try model.perform(c) }
        if !c.pieceIDs.isEmpty { select(Set(c.pieceIDs)) }
    }

    @objc func detachAudio(_ sender: Any?) {
        guard let id = topLevelSelection.first else { return }
        let c = DetachAudio(clipID: id)
        run("Separate Video and Audio") { try model.perform(c) }
        if let v = c.videoID { select([v]) }
    }

    private func kindOfSelection() -> ClipKind? {
        guard topLevelSelection.count == 1, let id = topLevelSelection.first else { return nil }
        return model.project.tracks.flatMap(\.clips).first { $0.id == id }?.kind
    }

    // Timeline actions arriving here (the timeline is not first responder): forward them.
    @objc func splitAtPlayhead(_ sender: Any?) { timelineView.splitAtPlayhead(sender) }
    @objc func rippleDelete(_ sender: Any?) { timelineView.rippleDelete(sender) }
    @objc func addTrack(_ sender: Any?) { timelineView.addTrack(sender) }
    @objc func toggleSnapping(_ sender: Any?) { timelineView.toggleSnapping(sender) }
    @objc func zoomIn(_ sender: Any?) { timelineView.zoomIn(sender) }
    @objc func zoomOut(_ sender: Any?) { timelineView.zoomOut(sender) }
    @objc func zoomToFit(_ sender: Any?) { timelineView.zoomToFit(sender) }
    @objc func deselectAll(_ sender: Any?) { select([]) }
    @objc func addMarker(_ sender: Any?) { timelineView.addMarker(sender) }
    @objc func extendFrame(_ sender: Any?) { timelineView.extendFrame(sender) }

    private static let forwarded: Set<Selector> = [
        #selector(splitAtPlayhead(_:)), #selector(rippleDelete(_:)), #selector(addTrack(_:)),
        #selector(toggleSnapping(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(zoomToFit(_:)),
        #selector(deselectAll(_:)), #selector(addMarker(_:)), #selector(extendFrame(_:)),
    ]

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let a = item.action, Self.forwarded.contains(a) { return timelineView.validateMenuItem(item) }
        if let a = item.action, let ok = validateCaptionsItem(a) { return ok }
        switch item.action {
        case #selector(togglePerformanceOverlay(_:)):
            item.title = ui.showOverlay ? "Hide Performance Overlay" : "Show Performance Overlay"
        case #selector(delete(_:)):
            return !timelineModel.selection.isEmpty
        case #selector(addAudioPoint(_:)):
            return AudioPanel.audioClips(in: model.project, selection: timelineModel.selection)
                .contains { $0.contains(engine.currentTicks) }
        case #selector(copy(_:)), #selector(cut(_:)):
            return !topLevelSelection.isEmpty
        case #selector(paste(_:)):
            return NSPasteboard.general.availableType(from: [Self.clipsType]) != nil
        case #selector(groupClips(_:)):
            return topLevelSelection.count >= 2
        case #selector(stitchClips(_:)):
            return topLevelSelection.count >= 2
        case #selector(ungroupClip(_:)):
            return kindOfSelection() == .group
        case #selector(unstitchClip(_:)):
            return kindOfSelection() == .stitched
        case #selector(detachAudio(_:)):
            return kindOfSelection() == .unified
        case #selector(showRelink(_:)):
            return relinkWindow == nil
        case #selector(showExport(_:)):
            return canExport
        default: break
        }
        return true
    }

    /// Something to export: the timeline is not empty.
    var canExport: Bool { engine.grid.duration > 0 }

    /// Toolbar items validate like the menu items with the same action.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let action = item.action else { return true }
        return validateMenuItem(NSMenuItem(title: item.label, action: action, keyEquivalent: ""))
    }

    // MARK: Lifecycle

    func windowWillClose(_ notification: Notification) { shutdown() }

    /// Stops the display link, audio and decoding. Idempotent.
    func shutdown() {
        transcription?.cancel()
        exportQueue.cancelAll()
        link?.invalidate()
        link = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        engine.shutdown()
        if recorderHUD?.model.state == .idle { recorderHUD?.close() }
        let thumbs = model.thumbnailPool
        Task { await thumbs.purge() }
    }
}
