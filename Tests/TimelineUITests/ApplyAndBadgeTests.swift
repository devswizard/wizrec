import AppKit
import Foundation
import Testing
import TimelineEngine
import TSCProjKit
@testable import TimelineUI

/// Library double-click actions, Remove Effect, speed badges and the trim media-limit preview.
@MainActor
struct ApplyAndBadgeTests {
    /// Track 0: clips 1 (0–90) and 2 (90–180) touching, then 3 (240–300).
    /// Track 1 (locked): clip 4 (0–60).
    func project() throws -> Project {
        try makeProject(tracks: tracksJSON(trackJSON(0, [vm(1, start: 0, dur: 90), vm(2, start: 90, dur: 90, ms: 90),
                                                       vm(3, start: 240, dur: 60)]),
                                           trackJSON(1, [vm(4, start: 0, dur: 60)])),
                        attrs: "[\(attr()), \(attr(locked: true))]")
    }

    func makeView() throws -> (TimelineModel, TimelineView) {
        let model = TimelineModel(undo: UndoStack(project: try project()))
        model.pointsPerSecond = 60
        let view = TimelineView(model: model)
        view.canvas.fitsOnFirstLayout = false
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 200)
        return (model, view)
    }

    func transitions(_ view: TimelineView) -> [String] {
        view.snapshot.tracks[0].transitions.map { "\($0.leftClipID ?? 0)-\($0.rightClipID ?? 0)" }.sorted()
    }

    @Test func applyEffectToSelection() throws {
        let (m, view) = try makeView()
        #expect(!view.applyEffect(named: "DropShadow"))  // nothing selected
        m.selection = [1, 3, 4]  // 4 is on a locked track and is skipped
        #expect(view.applyEffect(named: "DropShadow"))
        #expect(m.undo.undoName == "Add Effect")
        let s = view.snapshot
        #expect(s.clip(1)?.clip.effects.map(\.name) == ["DropShadow"])
        #expect(s.clip(3)?.clip.effectCount == 1)
        #expect(s.clip(4)?.clip.effectCount == 0)
        try m.undo.undo()
        #expect(view.snapshot.allClips.allSatisfy { $0.effectCount == 0 })
    }

    @Test func applyTransitionAtCutUnderPlayhead() throws {
        let (m, view) = try makeView()
        m.playhead = 90
        #expect(view.applyTransition(named: "Dissolve"))
        #expect(transitions(view) == ["1-2"])
        #expect(view.snapshot.tracks[0].transitions.first?.name == "Dissolve")
    }

    @Test func applyTransitionOnSelectedClipEdges() throws {
        let (m, view) = try makeView()
        m.playhead = 500
        #expect(!view.applyTransition(named: "Fade"))  // nothing selected, no cut
        m.selection = [2, 3]
        let e = view.editor
        // Clip 2 touches 1 on its left: two-sided there; free end → fade out. Clip 3: fade in + out.
        #expect(e.transitionTargets(tolerance: 0).map { "\($0.left ?? 0)-\($0.right ?? 0)" }
                == ["1-2", "2-0", "0-3", "3-0"])
        #expect(view.applyTransition(named: "Fade"))
        #expect(m.undo.undoName == "Add Transition")
        #expect(transitions(view) == ["0-3", "1-2", "2-0", "3-0"])
    }

    @Test func removeEffectFromContextMenu() throws {
        let (m, view) = try makeView()
        m.selection = [1]
        #expect(view.applyEffect(named: "RoundCorners"))
        #expect(view.applyEffect(named: "DropShadow"))
        let L = view.currentLayout
        let row = L.rowRect(try #require(L.row(forTrack: 0)))
        let menu = try #require(view.canvas.contextMenu(for: .clip(id: 1, track: 0, zone: .body),
                                                        at: CGPoint(x: L.x(ofTicks: 40), y: row.midY)))
        let parent = try #require(menu.items.first { $0.title == "Remove Effect" })
        let items = try #require(parent.submenu?.items)
        #expect(items.map(\.title) == ["Rounded Corners", "Drop Shadow"])
        view.canvas.menuRemoveEffect(items[0])
        #expect(m.undo.undoName == "Remove Effect")
        #expect(view.snapshot.clip(1)?.clip.effects == [TimelineEffectRef(name: "DropShadow", index: 0)])
        // Clips without effects get no submenu.
        let plain = try #require(view.canvas.contextMenu(for: .clip(id: 3, track: 0, zone: .body),
                                                         at: CGPoint(x: L.x(ofTicks: 250), y: row.midY)))
        #expect(!plain.items.contains { $0.title == "Remove Effect" })
        #expect(!view.editor.removeEffect(at: 5, from: 1))
    }

    @Test func unifiedEffectsUseCombinedOrder() throws {
        let p = try makeProject(tracks: tracksJSON(trackJSON(0, [unified(10, start: 0, dur: 90)])))
        let m = TimelineModel(undo: UndoStack(project: p))
        let e = TimelineEditor(model: m, snapshot: TimelineSnapshot(project: p))
        #expect(e.addEffect(named: "Mask", to: 10))  // visual → the video part
        let e2 = TimelineEditor(model: m, snapshot: TimelineSnapshot(project: m.project))
        #expect(e2.snapshot.clip(10)?.clip.effects == [TimelineEffectRef(name: "Mask", index: 0)])
        #expect(e2.removeEffect(at: 0, from: 10))
        #expect(TimelineSnapshot(project: m.project).clip(10)?.clip.effectCount == 0)
    }

    /// Gestures that would change nothing push no (empty) undo entry (qa, QA-8).
    @Test func noOpEditsStayOffTheUndoStack() throws {
        let (m, view) = try makeView()
        let e = view.editor
        let count = m.undo.changeCount
        m.selection = [1]
        #expect(!e.setSpeed(1))  // already 1×
        // Move / ripple move to the same place.
        #expect(!e.planMove(ids: [1], rawDelta: 0, trackOffset: 0, tolerance: 0).isValid)
        #expect(e.planRippleMove(id: 1, rawDelta: 0, trackOffset: 0, tolerance: 0)?.isValid == false)
        // Trim to the current edge, or past a media limit the edge already sits on.
        let same = try #require(e.planTrim(id: 1, edge: .end, rawDelta: 0, tolerance: 0))
        #expect(!e.performTrim(same))
        let atZero = try #require(e.planTrim(id: 1, edge: .start, rawDelta: -10, tolerance: 0))
        #expect(atZero.target == 0 && !e.performTrim(atZero))
        // Same marker twice; marker moved onto itself.
        #expect(e.addMarker(at: 30, name: "A"))
        let e2 = view.editor
        #expect(!e2.addMarker(at: 30, name: "A"))
        #expect(!e2.moveMarker(from: 30, to: 30))
        #expect(m.undo.changeCount == count + 1)  // only the first marker
    }

    @Test func speedBadges() throws {
        #expect(TimelineCanvas.speedLabel(2) == "2×")
        #expect(TimelineCanvas.speedLabel(0.5) == "0.5×")
        #expect(TimelineCanvas.speedLabel(1.25) == "1.25×")
        #expect(TimelineCanvas.speedLabel(1.0 / 3) == "0.33×")
        let p = try makeProject(tracks: tracksJSON(trackJSON(0, [vm(1, start: 0, dur: 45, scalar: "\"1/2\"", md: "90")])))
        let c = try #require(TimelineSnapshot(project: p).clip(1)?.clip)
        #expect(c.speed == 2)
        #expect(TimelineCanvas.badges(for: c, width: 30).isEmpty)
        #expect(TimelineCanvas.badges(for: c, width: 50) == ["2×"])
        var fx = c; fx.effectCount = 2
        #expect(TimelineCanvas.badges(for: fx, width: 120) == ["2×", "fx 2"])
        // A short row (no name strip) still draws the speed pill.
        let m = TimelineModel(undo: UndoStack(project: p))
        m.pointsPerSecond = 120
        let view = TimelineView(model: m)
        view.canvas.fitsOnFirstLayout = false
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 120)
        savePNG(render(view), "speed-badge")
    }

    @Test func trimMediaLimitPreview() throws {
        // Source 5 has 400 frames; clip 2 shows media 300…390 at 120, so its end stops at 220.
        let bin = """
        [{"id" : 5, "src" : "./media/5/short.mp4", "sourceTracks" : [{"type" : 0, "editRate" : 30, "range" : [0, 400]}]}]
        """
        let p = try makeProject(tracks: tracksJSON(trackJSON(0, [vm(2, start: 120, dur: 90, ms: 300, src: 5)])),
                                sourceBin: bin)
        let m = TimelineModel(undo: UndoStack(project: p))
        m.pointsPerSecond = 60
        let view = TimelineView(model: m)
        view.canvas.fitsOnFirstLayout = false
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 160)
        let e = view.editor
        let short = try #require(e.planTrim(id: 2, edge: .end, rawDelta: 5, tolerance: 0))
        #expect(e.mediaLimit(for: short)! == (220, false))
        let far = try #require(e.planTrim(id: 2, edge: .end, rawDelta: 80, tolerance: 0))
        #expect(far.target == 220)
        #expect(e.mediaLimit(for: far)! == (220, true))
        let left = try #require(e.planTrim(id: 2, edge: .start, rawDelta: -500, tolerance: 0))
        #expect(left.target == 0)  // timeline start binds before the media (−180)
        #expect(e.mediaLimit(for: left)?.tick == -180)
        // Preview draws the ghost and the limit bar (smoke test: renders without trapping).
        view.canvas.drag = .trim(origin: .zero, plan: far)
        savePNG(render(view), "trim-media-limit")
        view.canvas.drag = .none
    }
}
