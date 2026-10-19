import AppKit
import Foundation
import Testing
import TimelineEngine
import TSCProjKit
@testable import TimelineUI

@MainActor
struct RippleTests {
    func setup(_ p: Project? = nil) throws -> (TimelineModel, TimelineEditor) {
        let model = TimelineModel(undo: UndoStack(project: try p ?? sampleProject()))
        return (model, TimelineEditor(model: model, snapshot: TimelineSnapshot(project: model.project)))
    }

    func starts(_ m: TimelineModel, _ track: Int) -> [Int64: Int64] {
        Dictionary(uniqueKeysWithValues: m.project.tracks[track].clips.map { ($0.id, $0.start) })
    }

    // MARK: Media limits

    @Test func snapshotMediaLimits() throws {
        // Source 5: 400 frames. A clip at 120 showing media 300…390 may grow to 220 and back to −180.
        let bin = """
        [{"id" : 3, "src" : "./media/3/still.png", "rect" : [0, 0, 800, 600], "sourceTracks" : [{"type" : 1, "editRate" : 1, "range" : [0, 1]}]},
         {"id" : 5, "src" : "./media/5/short.mp4", "sourceTracks" : [{"type" : 0, "editRate" : 30, "range" : [0, 400]}]}]
        """
        let p = try makeProject(tracks: tracksJSON(trackJSON(0, [vm(1, start: 0, dur: 90, src: 5),
                                                               vm(2, start: 120, dur: 90, ms: 300, src: 5),
                                                               vm(3, start: 300, dur: 30, type: "IMFile", src: 3)])),
                                sourceBin: bin)
        let s = TimelineSnapshot(project: p)
        let b = try #require(s.clip(2)?.clip)
        #expect(b.minStart == -180 && b.maxEnd == 220)
        #expect(s.clip(3)?.clip.maxEnd == nil)
        let (_, e) = try setup(p)
        #expect(e.planTrim(id: 2, edge: .end, rawDelta: 50, tolerance: 0)?.target == 220)
        #expect(e.planTrim(id: 2, edge: .start, rawDelta: -100, tolerance: 0)?.target == 90)  // neighbour A
        #expect(e.planTrim(id: 1, edge: .start, rawDelta: -10, tolerance: 0)?.target == 0)
        // A ripple trim ignores the neighbour but not the media.
        #expect(e.planTrim(id: 2, edge: .start, rawDelta: -400, tolerance: 0, ripple: true)?.target == -180)
    }

    @Test func unifiedLimitsUseBothHalves() throws {
        let s = TimelineSnapshot(project: try sampleProject())
        let a = try #require(s.clip(10)?.clip)
        #expect(a.minStart == 0)
        #expect(a.maxEnd != nil)
    }

    // MARK: Ripple trim

    @Test func rippleTrimEndPushesLaterClips() throws {
        let (m, e) = try setup()
        let before = m.project.serialized()
        let plan = try #require(e.planTrim(id: 10, edge: .end, rawDelta: 60, tolerance: 0, ripple: true))
        #expect(plan.target == 150)  // B at 120 does not block a ripple trim
        let pv = e.preview(plan)
        #expect(pv[10] == ClipPosition(track: 0, start: 0, duration: 150))
        #expect(pv[20] == ClipPosition(track: 0, start: 180, duration: 90))
        #expect(pv[30] == nil)
        #expect(e.performTrim(plan))
        #expect(starts(m, 0) == [10: 0, 20: 180])
        try m.undo.undo()
        #expect(m.project.serialized() == before)
    }

    @Test func rippleTrimStartKeepsStart() throws {
        let (m, e) = try setup()
        let plan = try #require(e.planTrim(id: 10, edge: .start, rawDelta: 30, tolerance: 0, ripple: true))
        let pv = e.preview(plan)
        #expect(pv[10] == ClipPosition(track: 0, start: 0, duration: 60))
        #expect(pv[20] == ClipPosition(track: 0, start: 90, duration: 90))
        #expect(e.performTrim(plan))
        let a = try #require(m.project.tracks[0].clips.first { $0.id == 10 })
        #expect(a.start == 0 && a.duration == 60 && a.mediaStart == Rational(30))
        #expect(starts(m, 0)[20] == 90)
    }

    @Test func plainTrimPreviewMovesOnlyTheEdge() throws {
        let (_, e) = try setup()
        let plan = try #require(e.planTrim(id: 20, edge: .start, rawDelta: 30, tolerance: 0))
        #expect(e.preview(plan) == [20: ClipPosition(track: 0, start: 150, duration: 60)])
    }

    // MARK: Ripple move

    @Test func rippleMoveAcrossTracks() throws {
        let (m, e) = try setup()
        let before = m.project.serialized()
        // C (track 1, 30–150) → track 0 at 100, in the gap between A (0–90) and B (120–210).
        let plan = try #require(e.planRippleMove(id: 30, rawDelta: 70, trackOffset: -1, tolerance: 0))
        #expect(plan.toTrack == 0 && plan.start == 100 && plan.isValid)
        let pv = e.preview(plan)
        #expect(pv[30] == ClipPosition(track: 0, start: 100, duration: 120))
        #expect(pv[20] == ClipPosition(track: 0, start: 240, duration: 90))
        #expect(pv[10] == ClipPosition(track: 0, start: 0, duration: 90))
        #expect(e.performRippleMove(plan))
        #expect(starts(m, 0) == [10: 0, 30: 100, 20: 240])
        #expect(m.project.tracks[1].clips.isEmpty)
        try m.undo.undo()
        #expect(m.project.serialized() == before)
    }

    @Test func rippleMoveDropInsideClipSnapsToNearestEdge() throws {
        let (_, e) = try setup()
        // Drop at 60, inside A (0–90): nearer to its end.
        let plan = try #require(e.planRippleMove(id: 30, rawDelta: 30, trackOffset: -1, tolerance: 0))
        #expect(plan.start == 90 && plan.guide == 90)
        let early = try #require(e.planRippleMove(id: 30, rawDelta: -10, trackOffset: -1, tolerance: 0))
        #expect(early.start == 0)
    }

    @Test func rippleMoveWithinTrackClosesGapFirst() throws {
        let (m, e) = try setup()
        // B (120–210) to the very start of track 0: A moves right behind it.
        let plan = try #require(e.planRippleMove(id: 20, rawDelta: -120, trackOffset: 0, tolerance: 0))
        #expect(plan.start == 0 && plan.isValid)
        let pv = e.preview(plan)
        #expect(pv[20] == ClipPosition(track: 0, start: 0, duration: 90))
        #expect(pv[10] == ClipPosition(track: 0, start: 90, duration: 90))
        #expect(e.performRippleMove(plan))
        #expect(starts(m, 0) == [20: 0, 10: 90])
    }

    @Test func rippleMoveRefusesLockedTracks() throws {
        let (_, e) = try setup()
        let plan = try #require(e.planRippleMove(id: 30, rawDelta: 0, trackOffset: 1, tolerance: 0))
        #expect(plan.toTrack == 2 && !plan.isValid)
        #expect(!e.performRippleMove(plan))
    }

    // MARK: Gestures

    func window(for view: TimelineView) -> NSWindow {
        let w = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.contentView = view
        return w
    }

    func mouse(_ type: NSEvent.EventType, _ p: CGPoint, in view: NSView, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: flags, timestamp: 0,
                           windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: 1)!
    }

    func makeView() throws -> (TimelineModel, TimelineView) {
        let model = TimelineModel(undo: UndoStack(project: try sampleProject()))
        model.pointsPerSecond = 60  // 2 pt per tick
        let view = TimelineView(model: model)
        view.canvas.fitsOnFirstLayout = false
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 260)
        return (model, view)
    }

    @Test func optionEdgeDragRippleTrims() throws {
        let (model, view) = try makeView()
        let w = window(for: view)
        defer { w.close() }
        let canvas = view.canvas
        let a = try #require(view.currentLayout.clipRect(track: 0, start: 0, duration: 90))
        let p = CGPoint(x: a.maxX - 2, y: a.midY)
        let q = CGPoint(x: p.x + 120, y: p.y)  // +60 ticks
        canvas.mouseDown(with: mouse(.leftMouseDown, p, in: canvas, flags: .option))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, q, in: canvas, flags: .option))
        #expect(canvas.previewPositions[20]?.start == 180)
        savePNG(render(view), "ripple-trim-preview")
        canvas.mouseUp(with: mouse(.leftMouseUp, q, in: canvas, flags: .option))
        #expect(starts(model, 0) == [10: 0, 20: 180])
    }

    @Test func optionBodyDragRippleMoves() throws {
        let (model, view) = try makeView()
        let w = window(for: view)
        defer { w.close() }
        let canvas = view.canvas
        let L = view.currentLayout
        let c = try #require(L.clipRect(track: 1, start: 30, duration: 120))
        let start = CGPoint(x: c.midX, y: c.midY)
        let row0 = L.rowRect(try #require(L.row(forTrack: 0)))
        let end = CGPoint(x: start.x + 140, y: row0.midY)  // +70 ticks → 100
        canvas.mouseDown(with: mouse(.leftMouseDown, start, in: canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: start.x + 10, y: start.y), in: canvas, flags: .option))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, end, in: canvas, flags: .option))
        guard case .rippleMove(_, let plan) = canvas.drag else { Issue.record("not rippling: \(canvas.drag)"); return }
        #expect(plan.start == 100 && plan.toTrack == 0)
        savePNG(render(view), "ripple-move-preview")
        // Releasing ⌥ mid-drag turns it back into a plain move.
        canvas.mouseDragged(with: mouse(.leftMouseDragged, end, in: canvas))
        if case .move = canvas.drag {} else { Issue.record("expected plain move") }
        canvas.mouseDragged(with: mouse(.leftMouseDragged, end, in: canvas, flags: .option))
        canvas.mouseUp(with: mouse(.leftMouseUp, end, in: canvas, flags: .option))
        #expect(starts(model, 0) == [10: 0, 30: 100, 20: 240])
    }
}
