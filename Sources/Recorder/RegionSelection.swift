import AppKit

/// Full-screen overlay on one display: the user drags a rectangle (Esc / right-click cancels).
/// Reports the rectangle in display-local points, top-left origin — the form
/// `CaptureTarget.region` takes.
@MainActor
final class RegionSelectionOverlay {
    private var window: NSWindow?
    private var completion: ((CGDirectDisplayID, CGRect)?) -> Void = { _ in }

    /// Shows the overlay on `screen` (default: the screen under the mouse).
    func begin(on screen: NSScreen? = nil, completion: @escaping ((CGDirectDisplayID, CGRect)?) -> Void) {
        let target = screen ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let target,
              let number = target.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            completion(nil); return
        }
        self.completion = completion
        let displayID = CGDirectDisplayID(number.uint32Value)
        let w = OverlayWindow(contentRect: target.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        let view = RegionSelectionView(frame: CGRect(origin: .zero, size: target.frame.size))
        view.onDone = { [weak self] rect in
            self?.finish(rect.map { (displayID, $0) })
        }
        w.contentView = view
        w.setFrame(target.frame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(view)
        RecorderExclusions.exclude(windowNumber: w.windowNumber)
        window = w
        NSCursor.crosshair.push()
    }

    private func finish(_ result: (CGDirectDisplayID, CGRect)?) {
        NSCursor.pop()
        if let w = window {
            RecorderExclusions.include(windowNumber: w.windowNumber)
            w.orderOut(nil)
        }
        window = nil
        let c = completion
        completion = { _ in }
        c(result)
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class RegionSelectionView: NSView {
    var onDone: ((CGRect?) -> Void)?
    private var anchor: CGPoint?
    private var current: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var selection: CGRect? {
        guard let a = anchor, let c = current else { return nil }
        return CGRect(x: min(a.x, c.x), y: min(a.y, c.y), width: abs(a.x - c.x), height: abs(a.y - c.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        let hint = "Drag to select the area to record — Esc to cancel" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white]
        let size = hint.size(withAttributes: attrs)
        hint.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 80), withAttributes: attrs)
        guard let r = selection else { return }
        NSColor.clear.setFill()
        r.fill(using: .copy)
        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1))
        path.lineWidth = 2
        path.stroke()
        let label = "\(Int(r.width)) × \(Int(r.height))" as NSString
        label.draw(at: CGPoint(x: r.minX + 4, y: max(4, r.minY - 22)), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        current = anchor
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        guard let a = anchor, let c = current else { onDone?(nil); return }
        let rect = HUDFormat.regionRect(from: a, to: c, displayHeight: bounds.height)
        onDone?(rect.width >= 16 && rect.height >= 16 ? rect : nil)
    }

    override func rightMouseDown(with event: NSEvent) { onDone?(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDone?(nil) } else { super.keyDown(with: event) } // 53 = Esc
    }
}
