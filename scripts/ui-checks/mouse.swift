// Real mouse input for scripts/ui-checks (CGEvent through the HID event tap; needs
// Accessibility permission for the terminal, like System Events UI scripting).
//
//   swiftc -O mouse.swift -o mouse
//   ./mouse click <x> <y> [count]           move there, then `count` clicks (2 = a double-click)
//   ./mouse rightclick <x> <y>              a right click (opens a context menu)
//   ./mouse drag <x0> <y0> <x1> <y1> [s]    press at x0,y0, move to x1,y1 over s seconds (default 0.6), release
//
// x, y: global screen points with the origin at the top-left of the main display (the
// coordinates `ax frame` reports).
import CoreGraphics
import Foundation

let args = CommandLine.arguments
func usage() -> Never {
    FileHandle.standardError.write(Data("usage: mouse click <x> <y> [count] | rightclick <x> <y> | drag <x0> <y0> <x1> <y1> [s]\n".utf8))
    exit(2)
}
guard args.count >= 4, let x = Double(args[2]), let y = Double(args[3]) else { usage() }
let point = CGPoint(x: x, y: y)

func post(_ type: CGEventType, at p: CGPoint, button: CGMouseButton = .left, clickState: Int64) {
    guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button) else {
        FileHandle.standardError.write(Data("could not create a mouse event\n".utf8))
        exit(1)
    }
    e.setIntegerValueField(.mouseEventClickState, value: clickState)
    e.post(tap: .cghidEventTap)
}

switch args[1] {
case "click":
    let count: Int64 = args.count > 4 ? Int64(args[4]) ?? 1 : 1
    post(.mouseMoved, at: point, clickState: 0)
    usleep(150_000)
    for n in 1...max(1, count) {
        post(.leftMouseDown, at: point, clickState: n)
        usleep(30_000)
        post(.leftMouseUp, at: point, clickState: n)
        usleep(60_000)   // well inside the double-click interval
    }
    print("clicked \(count)x at \(Int(x)),\(Int(y))")
case "rightclick":
    post(.mouseMoved, at: point, clickState: 0)
    usleep(150_000)
    post(.rightMouseDown, at: point, button: .right, clickState: 1)
    usleep(40_000)
    post(.rightMouseUp, at: point, button: .right, clickState: 1)
    print("right-clicked at \(Int(x)),\(Int(y))")
case "drag":
    guard args.count >= 6, let x1 = Double(args[4]), let y1 = Double(args[5]) else { usage() }
    let seconds = args.count > 6 ? Double(args[6]) ?? 0.6 : 0.6
    let end = CGPoint(x: x1, y: y1)
    post(.mouseMoved, at: point, clickState: 0)
    usleep(150_000)
    post(.leftMouseDown, at: point, clickState: 1)
    usleep(100_000)
    let steps = 30
    for k in 1...steps {
        let f = CGFloat(k) / CGFloat(steps)
        post(.leftMouseDragged, at: CGPoint(x: point.x + (end.x - point.x) * f, y: point.y + (end.y - point.y) * f), clickState: 1)
        usleep(useconds_t(seconds / Double(steps) * 1_000_000))
    }
    usleep(150_000)
    post(.leftMouseUp, at: end, clickState: 1)
    print("dragged \(Int(x)),\(Int(y)) → \(Int(x1)),\(Int(y1))")
default:
    usage()
}
