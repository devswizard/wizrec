import AppKit
import MetalKit
import PlayerKit
import RenderEngine

/// The Metal canvas plus mouse editing (ui-workflow.md §8, our own design): click selects the
/// topmost clip under the pointer; dragging its body moves it, a corner scales it about its
/// centre, the knob above it rotates it (⇧ snaps to 15°), and in crop mode the edge handles crop
/// it. Every drag previews live and is one undo step on release (TimelineEngine `SetParameter`
/// through the document model), so the inspector follows. Accepts drops of files and bin items
/// (placed at the playhead).
final class EditorCanvasView: MTKView {
    weak var editor: EditorWindowController?
    /// A press on the selected clip: what it grabbed, where (view and canvas points), the clip's
    /// values and frame at the press, and whether it has moved past the threshold.
    private struct Drag {
        var handle: CanvasHandle
        var start: CGPoint
        var startCanvas: CGPoint
        var inspection: ClipInspection
        var frame: CanvasFrame?
        var moved = false
    }
    private var drag: Drag?
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Draw a focus ring while focused from the keyboard (Tab); a click clears it.
    var showsKeyboardFocus = false {
        didSet { if showsKeyboardFocus != oldValue { noteFocusRingMaskChanged() } }
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        guard showsKeyboardFocus, window?.firstResponder === self else { return }
        bounds.insetBy(dx: 1, dy: 1).fill()
    }
    override func resignFirstResponder() -> Bool {
        showsKeyboardFocus = false
        return super.resignFirstResponder()
    }
    override func accessibilityIdentifier() -> String { "editor.canvas" }
    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }
    override func setAccessibilityFocused(_ focused: Bool) {
        if focused { window?.makeFirstResponder(self) }
    }

    // VoiceOver: the canvas is the video preview; clips are selected on the timeline.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { String(localized: "Canvas preview") }
    override func accessibilityHelp() -> String? {
        String(localized: "Shows the frame at the playhead. Click a clip to select it; drag it to move, its corners to scale, the knob above it to rotate. Crop Mode adds edge handles.")
    }

    /// View point (AppKit, +y up) → canvas px (origin centre, +y up).
    func canvasPoint(_ p: CGPoint) -> CGPoint? {
        guard let editor else { return nil }
        return CanvasHitTest.canvasPoint(CGPoint(x: p.x, y: bounds.height - p.y), viewSize: bounds.size,
                                         canvasSize: editor.engine.scene.canvasSize)
    }

    /// View point → canvas px, also outside the canvas (drags).
    private func unboundedCanvasPoint(_ p: CGPoint) -> CGPoint {
        CanvasGeometry.canvasPoint(p, viewSize: bounds.size, canvasSize: editor?.engine.scene.canvasSize ?? .zero)
    }

    /// The handle of the selected clip under view point `p`, with its frame.
    func selectedHandle(at p: CGPoint) -> (id: Int64, handle: CanvasHandle, frame: CanvasFrame)? {
        guard let editor, editor.timelineModel.selection.count == 1, let id = editor.timelineModel.selection.first,
              let f = editor.canvasFrame(of: id),
              let h = CanvasGeometry.handle(at: p, frame: f, cropMode: editor.ui.cropMode, viewSize: bounds.size,
                                            canvasSize: editor.engine.scene.canvasSize) else { return nil }
        return (id, h, f)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        showsKeyboardFocus = false
        guard let editor else { return }
        let p = convert(event.locationInWindow, from: nil)
        drag = nil
        // A handle of the selected clip wins over whatever is drawn under it.
        if let (id, h, f) = selectedHandle(at: p), h != .body, let insp = editor.inspection(of: id), insp.visualClipID != nil {
            drag = Drag(handle: h, start: p, startCanvas: unboundedCanvasPoint(p), inspection: insp, frame: f)
            return
        }
        guard let c = canvasPoint(p) else { editor.select([]); return }
        let hit = CanvasHitTest.clip(at: c, plan: editor.engine.drawState().plan, project: editor.model.project)
        editor.select(hit.map { [$0] } ?? [])
        if let hit, let insp = editor.inspection(of: hit), insp.visualClipID != nil {
            drag = Drag(handle: .body, start: p, startCanvas: c, inspection: insp, frame: editor.canvasFrame(of: hit))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var d = drag, let editor else { return }
        let p = convert(event.locationInWindow, from: nil)
        let s = CanvasHitTest.scale(viewSize: bounds.size, canvasSize: editor.engine.scene.canvasSize)
        guard s > 0 else { return }
        guard d.moved || hypot(p.x - d.start.x, p.y - d.start.y) > 2 else { return }
        d.moved = true
        drag = d
        let i = d.inspection
        let now = unboundedCanvasPoint(p)
        switch d.handle {
        case .body:
            let dx = (p.x - d.start.x) / s, dy = (p.y - d.start.y) / s
            var x = (i.values[.positionX] ?? 0) + dx
            var y = (i.values[.positionY] ?? 0) + dy
            if !event.modifierFlags.contains(.option) { x = x.rounded(); y = y.rounded() }
            editor.preview(i.changes(.positionX, x) + i.changes(.positionY, y))
        case .corner:
            guard let f = d.frame else { return }
            let v = CanvasGeometry.scale(from: i.values[.scale] ?? 1, center: f.center, start: d.startCanvas, current: now)
            editor.preview(i.changes(.scale, v))
        case .rotate:
            guard let f = d.frame else { return }
            let v = CanvasGeometry.rotation(from: i.values[.rotation] ?? 0, center: f.center, start: d.startCanvas,
                                            current: now, snap: event.modifierFlags.contains(.shift))
            editor.preview(i.changes(.rotation, v))
        case .crop(let edge):
            guard let f = d.frame else { return }
            let v = CanvasGeometry.crop(edge, frame: f, start: d.startCanvas, current: now)
            editor.preview(i.changes(edge.field, v))
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        guard let d = drag, d.moved else { return }
        editor?.commitPreview()
    }

    // MARK: Cursor feedback

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch selectedHandle(at: p)?.handle {
        case .corner: NSCursor.crosshair.set()
        case .rotate: NSCursor.pointingHand.set()
        case .crop(let e): (e == .left || e == .right ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
        case .body: NSCursor.openHand.set()
        case nil: NSCursor.arrow.set()
        }
    }

    // MARK: Context menu

    /// Right-click selects the clip under the pointer, then shows the canvas menu for it.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let editor else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        var clip: Int64?
        if let c = canvasPoint(p) {
            clip = CanvasHitTest.clip(at: c, plan: editor.engine.drawState().plan, project: editor.model.project)
        }
        if let clip, !editor.timelineModel.selection.contains(clip) { editor.select([clip]) }
        if clip == nil, let sel = editor.timelineModel.selection.first, selectedHandle(at: p) != nil { clip = sel }
        return editor.canvasMenu(clip: clip)
    }

    // MARK: Drops

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let ok = MediaDrop.read(sender.draggingPasteboard) != nil
        editor?.ui.canvasDropTargeted = ok
        return ok ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        MediaDrop.read(sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { editor?.ui.canvasDropTargeted = false }

    override func draggingEnded(_ sender: any NSDraggingInfo) { editor?.ui.canvasDropTargeted = false }

    /// A drop adds at the playhead on the lowest track with room for the whole clip, else on a
    /// new top track (ui-workflow.md §4); dropped projects open in their own window.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        editor?.ui.canvasDropTargeted = false
        guard let drop = MediaDrop.read(sender.draggingPasteboard), let editor else { return false }
        editor.place(drop, track: nil, at: editor.engine.currentTicks)
        return true
    }
}

/// Outline and handles of the selected clip, drawn over the canvas. Never takes clicks.
/// Normal mode: outline, corner squares (scale) and a rotation knob above the top edge. Crop
/// mode: the uncropped media dashed, the visible rectangle solid, and a bar on each edge.
final class SelectionOverlayView: NSView {
    weak var editor: EditorWindowController?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let editor, editor.timelineModel.selection.count == 1, let id = editor.timelineModel.selection.first,
              let f = editor.canvasFrame(of: id) else { return }
        let canvas = editor.engine.scene.canvasSize
        func view(_ p: CGPoint) -> CGPoint { CanvasGeometry.viewPoint(p, viewSize: bounds.size, canvasSize: canvas) }
        func outline(_ pts: [CGPoint]) -> NSBezierPath {
            let path = NSBezierPath()
            path.move(to: pts[0])
            for p in pts.dropFirst() { path.line(to: p) }
            path.close()
            return path
        }
        let accent = NSColor.controlAccentColor
        let pts = f.corners.map(view)
        if editor.ui.cropMode {
            let full = outline(f.fullCorners.map(view))
            full.lineWidth = 1
            full.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.7).setStroke()
            full.stroke()
            let path = outline(pts)
            path.lineWidth = 2
            accent.setStroke()
            path.stroke()
            for edge in CanvasCropEdge.allCases {
                guard let m = f.edgeMidpoints[edge] else { continue }
                let c = view(m)
                let horizontal = edge == .top || edge == .bottom
                let r = horizontal ? NSRect(x: c.x - 10, y: c.y - 3, width: 20, height: 6)
                    : NSRect(x: c.x - 3, y: c.y - 10, width: 6, height: 20)
                accent.setFill()
                NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
                NSColor.white.setStroke()
                NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).stroke()
            }
            return
        }
        let path = outline(pts)
        path.lineWidth = 1.5
        accent.setStroke()
        path.stroke()
        let knob = CanvasGeometry.rotateKnob(f, viewSize: bounds.size, canvasSize: canvas)
        let top = CGPoint(x: (pts[2].x + pts[3].x) / 2, y: (pts[2].y + pts[3].y) / 2)
        let stem = NSBezierPath()
        stem.move(to: top)
        stem.line(to: knob)
        stem.lineWidth = 1
        stem.stroke()
        let k = NSBezierPath(ovalIn: NSRect(x: knob.x - 5, y: knob.y - 5, width: 10, height: 10))
        NSColor.white.setFill(); k.fill()
        accent.setStroke(); k.stroke()
        for p in pts {
            let r = NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            NSColor.white.setFill()
            NSBezierPath(rect: r).fill()
            accent.setStroke()
            NSBezierPath(rect: r).stroke()
        }
    }
}
