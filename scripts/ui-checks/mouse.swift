// Real mouse clicks for scripts/ui-checks (CGEvent through the HID event tap; needs
// Accessibility permission for the terminal, like System Events UI scripting).
//
//   swiftc -O mouse.swift -o mouse
//   ./mouse click <x> <y> [count]    move there, then `count` clicks (2 = a double-click)
//
// x, y: global screen points with the origin at the top-left of the main display (the
// coordinates `ax frame` reports).
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 4, args[1] == "click", let x = Double(args[2]), let y = Double(args[3]) else {
    FileHandle.standardError.write(Data("usage: mouse click <x> <y> [count]\n".utf8))
    exit(2)
}
let count: Int64 = args.count > 4 ? Int64(args[4]) ?? 1 : 1
let point = CGPoint(x: x, y: y)

func post(_ type: CGEventType, clickState: Int64) {
    guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
        FileHandle.standardError.write(Data("could not create a mouse event\n".utf8))
        exit(1)
    }
    e.setIntegerValueField(.mouseEventClickState, value: clickState)
    e.post(tap: .cghidEventTap)
}

post(.mouseMoved, clickState: 0)
usleep(150_000)
for n in 1...max(1, count) {
    post(.leftMouseDown, clickState: n)
    usleep(30_000)
    post(.leftMouseUp, clickState: n)
    usleep(60_000)   // well inside the double-click interval
}
print("clicked \(count)x at \(Int(x)),\(Int(y))")
