import AppKit
import TimelineEngine

// Additive public API of `TimelineView` (API_CHANGE TimelineUI, 2026-10-19).
extension TimelineView: NSMenuItemValidation {
    /// Pasteboard type for media-bin drags: one string per item, the `sourceBin` id.
    public static let sourceIDType = NSPasteboard.PasteboardType("com.devswizard.wizrec.source-id")

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
        case #selector(selectAll(_:)): return !canvas.snapshot.allClips.isEmpty
        case #selector(deselectAll(_:)): return !model.selection.isEmpty
        default: return true
        }
    }
}
