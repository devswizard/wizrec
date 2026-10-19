import AppKit
import MetalKit
import Observation
import PlayerKit
import QuartzCore
import SwiftUI

/// UI-only state of a player window.
@MainActor @Observable
final class PlayerUIState {
    var showOverlay = false
    var compositorError: String?
    let missing: [MissingMedia]
    init(missing: [MissingMedia]) { self.missing = missing }
}

/// The player window: Metal canvas (aspect-fit by the compositor), overlay and transport bar.
/// A display link on the canvas drives `PlaybackEngine.tick` and on-demand draws.
@MainActor
final class PlayerWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let model: PlayerDocumentModel
    let engine: PlaybackEngine
    let ui: PlayerUIState
    private let options: LaunchOptions
    private let canvas: MTKView
    private var renderer: CanvasRenderer?
    private var link: CADisplayLink?
    private var keyMonitor: Any?
    private var didAnnounce = false

    init(model: PlayerDocumentModel, options: LaunchOptions) {
        self.model = model
        self.options = options
        engine = model.makeEngine(audio: options.audio)
        ui = PlayerUIState(missing: model.missing)
        ui.showOverlay = options.overlay
        canvas = MTKView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), device: MTLCreateSystemDefaultDevice())

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720 + TransportBar.height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.contentMinSize = NSSize(width: 560, height: 315 + TransportBar.height)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        super.init(window: window)
        window.delegate = self

        renderer = CanvasRenderer(view: canvas)
        renderer?.engine = engine
        if renderer == nil { ui.compositorError = "Metal is not available on this Mac." }
        buildLayout(in: window)

        if let s = options.seekSeconds { engine.seek(toTicks: model.scene.timebase.ticks(seconds: s)) }
        if options.statsLog {
            let name = model.bundle.directory.lastPathComponent
            engine.onStats = { s in print("stats [\(name)] \(s.line)"); fflush(stdout) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildLayout(in window: NSWindow) {
        let root = NSView()
        let bar = NSHostingView(rootView: TransportBar(engine: engine))
        let overlay = NSHostingView(rootView: CanvasOverlay(engine: engine, ui: ui))
        for v in [canvas, bar, overlay] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: root.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: TransportBar.height),
            overlay.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: canvas.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
        ])
        window.contentView = root
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard !didAnnounce, let window else { return }
        didAnnounce = true
        window.center()
        startDisplayLink()
        installKeys()
        print("WizRec: opened \(model.bundle.directory.lastPathComponent) window=\(window.windowNumber) "
              + "canvas=\(Int(model.scene.canvasSize.width))x\(Int(model.scene.canvasSize.height)) "
              + "fps=\(model.scene.frameRate) frames=\(engine.grid.frameCount) missing=\(model.missing.count)")
        fflush(stdout)
        if let dir = options.snapshotDir {
            Task { await runSnapshots(into: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)) }
        } else if options.autoplay {
            engine.play()
        }
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
            if let e = renderer?.compositorError, ui.compositorError != e { ui.compositorError = e }
        }
    }

    // MARK: Snapshots (verification without screen-recording permission)

    /// Seeks to each `--snapshot-at` time, waits for exact frames, writes `frame-<s>s.png`;
    /// then, with `--autoplay`, plays and writes `playing-<n>.png` every 4 s.
    private func runSnapshots(into dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? await Task.sleep(nanoseconds: 300_000_000)  // let the window lay out
        for t in options.snapshotTimes {
            engine.seek(toTicks: model.scene.timebase.ticks(seconds: t))
            let settled = await engine.waitUntilSettled(timeout: 10)
            canvas.draw()
            try? await Task.sleep(nanoseconds: 100_000_000)
            let name = String(format: "frame-%06.2fs.png", t)
            writeSnapshot(to: dir.appendingPathComponent(name), note: settled ? "" : " (frames still decoding)")
        }
        guard options.autoplay else { return }
        engine.seek(toTicks: model.scene.timebase.ticks(seconds: options.seekSeconds ?? 0))
        engine.play()
        for n in 1...4 {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            writeSnapshot(to: dir.appendingPathComponent("playing-\(n).png"), note: "")
        }
    }

    /// Window content as PNG: the AppKit/SwiftUI views with the canvas rendered offscreen
    /// into its frame (Metal layers are not captured by `cacheDisplay`).
    private func writeSnapshot(to url: URL, note: String) {
        guard let root = window?.contentView, let overlayView = root.subviews.last,
              let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds),
              let top = overlayView.bitmapImageRepForCachingDisplay(in: overlayView.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: rep)
        overlayView.cacheDisplay(in: overlayView.bounds, to: top)
        let scale = window?.backingScaleFactor ?? 2
        let rect = canvas.frame
        let image = renderer?.renderImage(size: CGSize(width: rect.width * scale, height: rect.height * scale))
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            if let image { ctx.cgContext.draw(image, in: rect) }
            top.draw(in: overlayView.frame, from: .zero, operation: .sourceOver, fraction: 1,
                     respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
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
            // Local monitors run on the main thread.
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self.window else { return false }
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

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(togglePerformanceOverlay(_:)) {
            item.title = ui.showOverlay ? "Hide Performance Overlay" : "Show Performance Overlay"
        }
        return true
    }

    // MARK: Lifecycle

    func windowWillClose(_ notification: Notification) { shutdown() }

    /// Stops the display link, audio and decoding. Idempotent.
    func shutdown() {
        link?.invalidate()
        link = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        engine.shutdown()
    }
}
