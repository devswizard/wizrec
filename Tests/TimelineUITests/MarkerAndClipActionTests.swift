import AppKit
import Foundation
import Testing
import TimelineEngine
import TSCProjKit
@testable import TimelineUI

@MainActor
struct MarkerAndClipActionTests {
    func makeView() throws -> (TimelineModel, TimelineView, NSWindow) {
        let model = TimelineModel(undo: UndoStack(project: try sampleProject()))
        model.pointsPerSecond = 60  // 2 pt per tick
        let view = TimelineView(model: model)
        view.canvas.fitsOnFirstLayout = false
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 260)
        let w = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.contentView = view
        return (model, view, w)
    }

    func mouse(_ type: NSEvent.EventType, _ p: CGPoint, in view: NSView, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                           windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                           clickCount: clicks, pressure: 1)!
    }

    @Test func dragMarkerInRuler() throws {
        let (model, view, w) = try makeView()
        defer { w.close() }
        #expect(view.editor.addMarker(at: 100))
        let canvas = view.canvas
        let L = view.currentLayout
        let y = L.metrics.rulerHeight - 6
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: L.x(ofTicks: 100), y: y), in: canvas))
        guard case .marker(let from, _, _) = canvas.drag else { Issue.record("no marker drag: \(canvas.drag)"); return }
        #expect(from == 100)
        // Drag to 147 → snaps to C's end at 150 (8 pt = 4 ticks tolerance).
        let q = CGPoint(x: L.x(ofTicks: 147), y: y)
        canvas.mouseDragged(with: mouse(.leftMouseDragged, q, in: canvas))
        #expect(canvas.displayedMarkers.map(\.time) == [150])
        canvas.mouseUp(with: mouse(.leftMouseUp, q, in: canvas))
        #expect(model.undo.undoName == "Move Marker")
        #expect(view.snapshot.markers.map(\.time) == [150])
        // A click without moving seeks to the marker.
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: L.x(ofTicks: 150), y: y), in: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: L.x(ofTicks: 150), y: y), in: canvas))
        #expect(model.playhead == 150)
    }

    @Test func doubleClickRenamesMarker() throws {
        let (model, view, w) = try makeView()
        defer { w.close() }
        #expect(view.editor.addMarker(at: 60, name: "Intro"))
        let canvas = view.canvas
        let L = view.currentLayout
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: L.x(ofTicks: 60), y: L.metrics.rulerHeight - 6), in: canvas,
                                     clicks: 2))
        let field = try #require(canvas.markerEditor?.field)
        #expect(field.stringValue == "Intro")
        field.stringValue = "Chapter 1"
        #expect(canvas.endRenameMarker(commit: true))
        #expect(model.undo.undoName == "Rename Marker")
        #expect(view.snapshot.markers.first?.name == "Chapter 1")
        #expect(canvas.markerEditor == nil && field.superview == nil)
        // Cancel leaves the name alone.
        canvas.beginRenameMarker(at: 60)
        canvas.markerEditor?.field.stringValue = "Nope"
        #expect(!canvas.endRenameMarker(commit: false))
        #expect(view.snapshot.markers.first?.name == "Chapter 1")
        savePNG(render(view), "marker-renamed")
    }

    @Test func renameMarkerActionValidatesOnPlayhead() throws {
        let (model, view, w) = try makeView()
        defer { w.close() }
        let item = NSMenuItem(title: "Rename Marker", action: #selector(TimelineView.renameMarker(_:)), keyEquivalent: "")
        #expect(!view.validateMenuItem(item))
        #expect(view.editor.addMarker(at: 90))
        model.playhead = 91
        #expect(view.validateMenuItem(item))
        view.renameMarker(item)
        #expect(view.canvas.markerEditor?.time == 90)
        view.canvas.endRenameMarker(commit: false)
    }

    @Test func clipSpeedAction() throws {
        let (model, view, w) = try makeView()
        defer { w.close() }
        let item = NSMenuItem(title: "200%", action: #selector(TimelineView.setClipSpeed(_:)), keyEquivalent: "")
        item.tag = 200
        #expect(!view.validateMenuItem(item))
        model.selection = [10]
        #expect(view.validateMenuItem(item))
        view.setClipSpeed(item)
        let a = try #require(model.project.tracks[0].clips.first { $0.id == 10 })
        #expect(a.duration == 45)
        #expect(a.scalar == Rational(1, 2))
        // Represented NSNumber wins over the tag.
        item.representedObject = NSNumber(value: 0.5)
        model.selection = [20]
        view.setClipSpeed(item)
        // B (120–210) at half speed would grow to 180 ticks; nothing follows it, so it fits.
        #expect(model.project.tracks[0].clips.first { $0.id == 20 }?.duration == 180)
        #expect(TimelineView.speed(from: NSNumber(value: 1.5)) == 1.5)
    }

    @Test func extendFrameAction() throws {
        let (model, view, w) = try makeView()
        defer { w.close() }
        let item = NSMenuItem(title: "Extend Frame", action: #selector(TimelineView.extendFrame(_:)), keyEquivalent: "")
        model.selection = [30]  // audio only: nothing to hold
        #expect(!view.validateMenuItem(item))
        model.selection = [20]
        #expect(view.validateMenuItem(item))
        view.extendFrame(item)
        #expect(model.undo.undoName == "Extend Frame")
        let clips = model.project.tracks[0].clips
        // ED1 [obs]: the clip becomes a StitchedMedia of itself + a frame image.
        #expect(clips.count == 2)
        #expect(clips.last?.kind == .stitched && clips.last?.start == 120 && clips.last?.duration == 120)
    }
}
