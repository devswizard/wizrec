// Real file drags for scripts/ui-checks: drags files from a small helper window to a screen
// point, the way a drag from Finder does (an NSDraggingSession carrying file URLs, moved by
// HID mouse events). Needs Accessibility permission for the terminal, like mouse.swift.
//
//   swiftc -O drag.swift -o drag
//   ./drag <x> <y> [--hover <s>] <file>…
//
// x, y: global screen points with the origin at the top-left of the main display (the
// coordinates `ax frame` reports). The pointer rests over the target for --hover seconds
// (default 1) before the drop. Prints "drag ended operation=<n>" (0 = the target refused the
// drop) and exits 0, or exits 1 when the session never ended.
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3, let tx = Double(args[0]), let ty = Double(args[1]) else {
    FileHandle.standardError.write(Data("usage: drag <x> <y> [--hover <s>] <file>…\n".utf8))
    exit(2)
}
var hover = 1.0
var files: [URL] = []
var i = 2
while i < args.count {
    if args[i] == "--hover", i + 1 < args.count { hover = Double(args[i + 1]) ?? hover; i += 2; continue }
    files.append(URL(fileURLWithPath: args[i]))
    i += 1
}
guard !files.isEmpty else { FileHandle.standardError.write(Data("no files\n".utf8)); exit(2) }

/// The helper window's frame: 120 pt square near the top-left of the main display.
let side: CGFloat = 120
let mainHeight = NSScreen.screens.first?.frame.height ?? 900
let origin = CGPoint(x: 40, y: mainHeight - 80 - side)          // Cocoa coordinates (bottom-left)
let start = CGPoint(x: origin.x + side / 2, y: 80 + side / 2)    // the same point, top-left coordinates
let target = CGPoint(x: tx, y: ty)

func post(_ type: CGEventType, _ p: CGPoint) {
    guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
    if type == .leftMouseDown || type == .leftMouseUp { e.setIntegerValueField(.mouseEventClickState, value: 1) }
    e.post(tap: .cghidEventTap)
}

final class Source: NSView, NSDraggingSource {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemOrange.setFill()
        bounds.fill()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let items = files.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(x: 30, y: 30, width: 60, height: 60), contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        print("drag ended operation=\(operation.rawValue)")
        fflush(stdout)
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(origin: origin, size: CGSize(width: side, height: side)),
                      styleMask: [.borderless], backing: .buffered, defer: false)
window.level = .floating
window.contentView = Source(frame: NSRect(x: 0, y: 0, width: side, height: side))
window.orderFrontRegardless()
app.activate(ignoringOtherApps: true)

// The mouse script runs on its own thread: the drag session tracks events on the main thread.
Thread.detachNewThread {
    usleep(600_000)
    post(.mouseMoved, start)
    usleep(200_000)
    post(.leftMouseDown, start)
    usleep(150_000)
    let steps = 40
    for k in 1...steps {
        let f = CGFloat(k) / CGFloat(steps)
        post(.leftMouseDragged, CGPoint(x: start.x + (target.x - start.x) * f, y: start.y + (target.y - start.y) * f))
        usleep(20_000)
    }
    // Hover: small moves keep draggingUpdated coming.
    let wiggles = max(1, Int(hover / 0.1))
    for k in 0..<wiggles {
        post(.leftMouseDragged, CGPoint(x: target.x + (k % 2 == 0 ? 1 : 0), y: target.y))
        usleep(100_000)
    }
    post(.leftMouseUp, target)
    usleep(5_000_000)
    print("drag: the session did not end")
    fflush(stdout)
    exit(1)
}
app.run()
