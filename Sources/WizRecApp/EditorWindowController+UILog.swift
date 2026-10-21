import AppKit
import PlayerKit
import TimelineUI

/// `-WizRec.LogUI YES` (argument domain, UI checks only): edits, the selection, where the
/// selected clip's canvas handles and timeline clip are on screen, and the items of every menu
/// that opens, as `WizRec: …` log lines the checks read. Off otherwise (no cost).
extension EditorWindowController {
    static var logsUI: Bool { UserDefaults.standard.bool(forKey: "WizRec.LogUI") }

    /// Starts logging opened menus (context menus included).
    func startUILog() {
        guard Self.logsUI else { return }
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            guard let menu = note.object as? NSMenu else { return }
            let items = menu.items.map { i in
                i.isSeparatorItem ? "-" : i.title + (i.isEnabled ? "" : "(off)") + (i.state == .on ? "(on)" : "")
            }
            print("WizRec: menu \(items.joined(separator: "|"))")
            fflush(stdout)
        }
    }

    /// After a project change: the undo and redo names.
    func logEdit() {
        guard Self.logsUI else { return }
        print("WizRec: edit undo=\(model.undo.undoName ?? "-") redo=\(model.undo.redoName ?? "-")")
        fflush(stdout)
    }

    /// The selection and, for one selected clip, its handles and timeline position in screen
    /// points (top-left origin, as `ax frame` and mouse.swift use).
    func logSelection() {
        guard Self.logsUI, let window else { return }
        let sel = timelineModel.selection.sorted()
        var line = "WizRec: selected \(sel)"
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        func screen(_ p: CGPoint, in view: NSView) -> String {
            let s = window.convertPoint(toScreen: view.convert(p, to: nil))
            return "\(Int(s.x.rounded())),\(Int((mainHeight - s.y).rounded()))"
        }
        if sel.count == 1, let id = sel.first {
            let overlay = canvas
            if let f = canvasFrame(of: id) {
                let size = overlay.bounds.size, canvasSize = engine.scene.canvasSize
                func v(_ p: CGPoint) -> CGPoint { CanvasGeometry.viewPoint(p, viewSize: size, canvasSize: canvasSize) }
                line += " center=\(screen(v(f.center), in: overlay)) corner2=\(screen(v(f.corners[2]), in: overlay))"
                line += " knob=\(screen(CanvasGeometry.rotateKnob(f, viewSize: size, canvasSize: canvasSize), in: overlay))"
                if let m = f.edgeMidpoints[.left] { line += " cropHandle=\(screen(v(m), in: overlay))" }
            }
            let layout = timelineView.currentLayout
            if let (track, c) = timelineView.snapshot.clip(id),
               let r = layout.clipRect(track: track, start: c.start, duration: c.duration) {
                let visible = r.intersection(layout.clipArea)
                let mid = CGPoint(x: (visible.isNull ? r : visible).midX, y: timelineView.bounds.height - r.midY)
                line += " timeline=\(screen(mid, in: timelineView))"
            }
            if let i = inspection(of: id) {
                let vals = [InspectorField.positionX, .positionY, .scale, .rotation, .cropLeft]
                    .map { "\($0.rawValue)=\(String(format: "%.3f", i.values[$0] ?? 0))" }
                line += " " + vals.joined(separator: " ")
            }
        }
        print(line)
        fflush(stdout)
    }
}
