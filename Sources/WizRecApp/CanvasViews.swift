import AppKit
import MetalKit
import PlayerKit
import RenderEngine

/// The Metal canvas plus mouse editing: click selects the topmost clip under the
/// pointer, drag moves it (live preview, one undo step on release). Accepts drops of
/// files and bin items (placed at the playhead).
final class EditorCanvasView: MTKView {
    weak var editor: EditorWindowController?
    private var drag: (start: CGPoint, inspection: ClipInspection, moved: Bool)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // VoiceOver: the canvas is the video preview; clips are selected on the timeline.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { String(localized: "Canvas preview") }
    override func accessibilityHelp() -> String? {
        String(localized: "Shows the frame at the playhead. Click a clip to select it, drag to move it.")
    }

    /// View point (AppKit, +y up) → canvas px (origin centre, +y up).
    func canvasPoint(_ p: CGPoint) -> CGPoint? {
        guard let editor else { return nil }
        return CanvasHitTest.canvasPoint(CGPoint(x: p.x, y: bounds.height - p.y), viewSize: bounds.size,
                                         canvasSize: editor.engine.scene.canvasSize)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let editor else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard let c = canvasPoint(p) else { editor.select([]); return }
        let hit = CanvasHitTest.clip(at: c, plan: editor.engine.drawState().plan, project: editor.model.project)
        editor.select(hit.map { [$0] } ?? [])
        if let hit, let insp = editor.inspection(of: hit), insp.visualClipID != nil {
            drag = (p, insp, false)
        } else {
            drag = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var d = drag, let editor else { return }
        let p = convert(event.locationInWindow, from: nil)
        let s = CanvasHitTest.scale(viewSize: bounds.size, canvasSize: editor.engine.scene.canvasSize)
        guard s > 0 else { return }
        let dx = (p.x - d.start.x) / s, dy = (p.y - d.start.y) / s
        guard d.moved || hypot(p.x - d.start.x, p.y - d.start.y) > 2 else { return }
        d.moved = true
        drag = d
        var x = (d.inspection.values[.positionX] ?? 0) + dx
        var y = (d.inspection.values[.positionY] ?? 0) + dy
        if !event.modifierFlags.contains(.option) { x = x.rounded(); y = y.rounded() }
        editor.preview(d.inspection.changes(.positionX, x) + d.inspection.changes(.positionY, y))
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        guard let d = drag, d.moved else { return }
        editor?.commitPreview()
    }

    // MARK: Drops

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        MediaDrop.read(sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let drop = MediaDrop.read(sender.draggingPasteboard), let editor else { return false }
        editor.place(drop, track: nil, at: editor.engine.currentTicks)
        return true
    }
}

/// Outline and handles of the selected clip, drawn over the canvas. Never takes clicks.
final class SelectionOverlayView: NSView {
    weak var editor: EditorWindowController?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let editor, let id = editor.timelineModel.selection.first else { return }
        let plan = editor.engine.drawState().plan
        let project = editor.model.project
        let canvas = plan.canvasSize
        let s = CanvasHitTest.scale(viewSize: bounds.size, canvasSize: canvas)
        guard s > 0 else { return }
        for layer in plan.layers where (CanvasHitTest.topLevelClip(forLayer: layer.clipID, in: project) ?? layer.clipID) == id {
            let w = layer.size.width, h = layer.size.height, c = layer.geometryCrop
            let local = [CGPoint(x: -w / 2 + c.left * w, y: -h / 2 + c.bottom * h),
                         CGPoint(x: w / 2 - c.right * w, y: -h / 2 + c.bottom * h),
                         CGPoint(x: w / 2 - c.right * w, y: h / 2 - c.top * h),
                         CGPoint(x: -w / 2 + c.left * w, y: h / 2 - c.top * h)]
            let pts = local.map { p -> CGPoint in
                let q = p.applying(layer.transform)
                return CGPoint(x: bounds.midX + q.x * s, y: bounds.midY + q.y * s)
            }
            let path = NSBezierPath()
            path.move(to: pts[0])
            for p in pts.dropFirst() { path.line(to: p) }
            path.close()
            path.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            path.stroke()
            for p in pts {
                let r = NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                NSColor.white.setFill()
                NSBezierPath(rect: r).fill()
                NSColor.controlAccentColor.setStroke()
                NSBezierPath(rect: r).stroke()
            }
        }
    }
}
