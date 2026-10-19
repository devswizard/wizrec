import AppKit
import TimelineEngine

// Additive public API of `TimelineView` (API_CHANGE TimelineUI, 2026-10-19).
extension TimelineView: NSMenuItemValidation {
    /// Pasteboard type for media-bin drags: one string per item, the `sourceBin` id.
    public static let sourceIDType = NSPasteboard.PasteboardType("com.devswizard.wizrec.source-id")
    /// Library drags: string = effect name (`TimelineLibrary.effects`), dropped on a clip.
    public static let effectType = NSPasteboard.PasteboardType("com.devswizard.wizrec.effect")
    /// Library drags: string = transition name (`TimelineLibrary.transitions`), dropped on a cut or clip edge.
    public static let transitionType = NSPasteboard.PasteboardType("com.devswizard.wizrec.transition")

    /// Thumbnail and waveform source. Nil draws placeholders.
    public var mediaProvider: (any TimelineMediaProvider)? {
        get { canvas.art.provider }
        set { canvas.art.provider = newValue; canvas.needsDisplay = true }
    }

    /// Custom snap rule for drags; nil (default) uses TimelineEngine's `Snapping`.
    public var snapper: (any TimelineSnapping)? {
        get { canvas.snapper }
        set { canvas.snapper = newValue }
    }

    /// Current value projection of the project (rebuilt after each edit).
    public var snapshot: TimelineSnapshot { canvas.rebuildIfNeeded(); return canvas.snapshot }

    /// Current geometry (zoom, scroll, rows) for the view's size.
    public var currentLayout: TimelineLayout { canvas.rebuildIfNeeded(); return canvas.layout }

    /// Horizontal and vertical scroll, points.
    public var scrollOffset: CGPoint {
        get { CGPoint(x: canvas.scrollX, y: canvas.scrollY) }
        set { canvas.scrollX = newValue.x; canvas.scrollY = newValue.y; canvas.clampScroll(); canvas.needsDisplay = true }
    }

    override public var acceptsFirstResponder: Bool { true }

    /// Keys reach the canvas whether the app focuses the view or the canvas
    /// (unhandled canvas keys come back here through the responder chain).
    override public func keyDown(with event: NSEvent) {
        guard window?.firstResponder === self, !canvas.forwardingKey else { return super.keyDown(with: event) }
        canvas.forwardingKey = true
        defer { canvas.forwardingKey = false }
        canvas.keyDown(with: event)
    }

    var editor: TimelineEditor { canvas.rebuildIfNeeded(); return canvas.editor }

    // MARK: Menu / responder-chain actions

    /// Splits the selected clips (or all clips) under the playhead. Key: S.
    @objc public func splitAtPlayhead(_ sender: Any?) { if !editor.splitAtPlayhead() { NSSound.beep() } }
    /// Deletes the selected clips, leaving gaps. Key: ⌫.
    @objc public func delete(_ sender: Any?) { if !editor.deleteSelection(ripple: false) { NSSound.beep() } }
    /// Deletes the selected clips and closes the gaps. Key: ⇧⌫.
    @objc public func rippleDelete(_ sender: Any?) { if !editor.deleteSelection(ripple: true) { NSSound.beep() } }
    /// Key: ⌘=.
    @objc public func zoomIn(_ sender: Any?) { canvas.zoom(to: model.pointsPerSecond * TimelineZoom.step) }
    /// Key: ⌘−.
    @objc public func zoomOut(_ sender: Any?) { canvas.zoom(to: model.pointsPerSecond / TimelineZoom.step) }
    /// Key: ⌘0.
    @objc public func zoomToFit(_ sender: Any?) { canvas.zoomToFit() }
    /// Adds an empty track on top of the stack.
    @objc public func addTrack(_ sender: Any?) {
        if !editor.addTrack(at: canvas.snapshot.tracks.count) { NSSound.beep() }
    }
    @objc public func toggleSnapping(_ sender: Any?) { model.snappingEnabled.toggle() }
    /// Sets the selected clips' speed: `sender` is an NSMenuItem whose `representedObject` is an
    /// NSNumber speed (2 = 2×), or whose `tag` is a percentage (200 = 2×). ⌥ in the menu = ripple.
    @objc public func setClipSpeed(_ sender: Any?) {
        guard let speed = Self.speed(from: sender) else { NSSound.beep(); return }
        let ripple = NSApp?.currentEvent?.modifierFlags.contains(.option) ?? false
        if !editor.setSpeed(speed, ripple: ripple) { NSSound.beep() }
    }
    /// Holds the last frame of the selected clips: `representedObject` NSNumber seconds, default 1 s.
    @objc public func extendFrame(_ sender: Any?) {
        let secs = ((sender as? NSMenuItem)?.representedObject as? NSNumber)?.doubleValue ?? 1
        if !editor.extendFrame(seconds: secs) { NSSound.beep() }
    }
    /// Renames the marker under (or nearest within 6 pt of) the playhead.
    @objc public func renameMarker(_ sender: Any?) {
        guard let m = editor.marker(near: model.playhead, tolerance: canvas.layout.ticks(forWidth: 6)) else {
            NSSound.beep(); return
        }
        canvas.beginRenameMarker(at: m.time)
    }

    static func speed(from sender: Any?) -> Double? {
        if let item = sender as? NSMenuItem {
            if let n = item.representedObject as? NSNumber { return n.doubleValue }
            if item.tag > 0 { return Double(item.tag) / 100 }
        }
        if let n = sender as? NSNumber { return n.doubleValue }
        return nil
    }
    /// Adds a marker at the playhead. Key: M.
    @objc public func addMarker(_ sender: Any?) { if !editor.addMarker(at: model.playhead) { NSSound.beep() } }
    override public func selectAll(_ sender: Any?) { model.selection = Set(canvas.snapshot.allClips.map(\.id)) }
    @objc public func deselectAll(_ sender: Any?) { model.selection = [] }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(splitAtPlayhead(_:)): return !editor.splitTargets(at: model.playhead).isEmpty
        case #selector(delete(_:)), #selector(rippleDelete(_:)): return !editor.deletableSelection.isEmpty
        case #selector(zoomIn(_:)): return model.pointsPerSecond < TimelineZoom.maxPointsPerSecond
        case #selector(zoomOut(_:)): return model.pointsPerSecond > TimelineZoom.minPointsPerSecond
        case #selector(toggleSnapping(_:)):
            item.state = model.snappingEnabled ? .on : .off
            return true
        case #selector(setClipSpeed(_:)): return !editor.retimableSelection.isEmpty
        case #selector(extendFrame(_:)):
            return editor.retimableSelection.contains { canvas.snapshot.clip($0).map { !$0.clip.videoSpans.isEmpty } ?? false }
        case #selector(renameMarker(_:)):
            return editor.marker(near: model.playhead, tolerance: canvas.layout.ticks(forWidth: 6)) != nil
        case #selector(selectAll(_:)): return !canvas.snapshot.allClips.isEmpty
        case #selector(deselectAll(_:)): return !model.selection.isEmpty
        default: return true
        }
    }
}
