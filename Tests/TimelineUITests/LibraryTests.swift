import AppKit
import Foundation
import Testing
import TimelineEngine
import TSCProjKit
@testable import TimelineUI

@MainActor
struct LibraryTests {
    /// Track 0: clips 1 (0–90) and 2 (90–180) touching, then 3 (240–300).
    func project() throws -> Project {
        try makeProject(tracks: tracksJSON(trackJSON(0, [vm(1, start: 0, dur: 90), vm(2, start: 90, dur: 90, ms: 90),
                                                       vm(3, start: 240, dur: 60)])),
                        attrs: "[\(attr())]")
    }

    func makeView() throws -> (TimelineModel, TimelineView) {
        let model = TimelineModel(undo: UndoStack(project: try project()))
        model.pointsPerSecond = 60
        let view = TimelineView(model: model)
        view.canvas.fitsOnFirstLayout = false
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 200)
        return (model, view)
    }

    @Test func catalogMatchesRenderer() {
        #expect(TimelineLibrary.transitions.map(\.name) == ["Fade", "Dissolve", "FadeThroughBlack"])
        #expect(Set(TimelineLibrary.effects.map(\.name)) == ["RoundCorners", "DropShadow", "Mask", "ColorAdjustment"])
        #expect(TimelineLibrary.effect(named: "DropShadow")?.parameters.first { $0.key == "blur" }?.value == 25)
        #expect(TimelineLibrary.transition(named: "Nope") == nil)
    }

    @Test func transitionTargets() throws {
        let (m, _) = try makeView()
        let e = TimelineEditor(model: m, snapshot: TimelineSnapshot(project: m.project))
        #expect(e.transitionTarget(track: 0, at: 92, tolerance: 4)! == (1, 2))
        #expect(e.transitionTarget(track: 0, at: 10, tolerance: 4)! == (nil, 1))
        #expect(e.transitionTarget(track: 0, at: 80, tolerance: 4)! == (1, nil))
        #expect(e.transitionTarget(track: 0, at: 299, tolerance: 4)! == (3, nil))
        #expect(e.transitionTarget(track: 0, at: 200, tolerance: 4) == nil)
        #expect(e.transitionDuration(left: 1, right: 2) == 30)
        #expect(e.transitionDuration(left: 3, right: nil) == 30)
        #expect(e.transitionSpan(left: 1, right: 2)! == (0, 75, 105))
    }

    @Test func dropTransitionOnCutThenRemove() throws {
        let (m, view) = try makeView()
        let canvas = view.canvas
        let L = view.currentLayout
        let row = L.rowRect(try #require(L.row(forTrack: 0)))
        let drop = try #require(canvas.libraryDrop((false, "Fade"), at: CGPoint(x: L.x(ofTicks: 91), y: row.midY)))
        #expect(drop == .transition(name: "Fade", left: 1, right: 2))
        canvas.libraryTarget = drop
        savePNG(render(view), "library-transition-target")
        canvas.libraryTarget = nil
        #expect(canvas.perform(drop))
        #expect(m.undo.undoName == "Add Transition")
        let tr = try #require(view.snapshot.tracks[0].transitions.first)
        #expect(tr.name == "Fade" && tr.start == 75 && tr.end == 105)
        savePNG(render(view), "library-transition")
        // Context menu on the transition offers removal.
        let menu = try #require(canvas.contextMenu(for: .clip(id: 1, track: 0, zone: .body),
                                                   at: CGPoint(x: L.x(ofTicks: 85), y: row.midY)))
        let item = try #require(menu.items.first { $0.title == "Remove Transition" })
        canvas.menuRemoveTransition(item)
        #expect(view.snapshot.tracks[0].transitions.isEmpty)
    }

    @Test func dropFadeInOnClipStart() throws {
        let (_, view) = try makeView()
        let canvas = view.canvas
        let L = view.currentLayout
        let row = L.rowRect(try #require(L.row(forTrack: 0)))
        let drop = try #require(canvas.libraryDrop((false, "FadeThroughBlack"), at: CGPoint(x: L.x(ofTicks: 245), y: row.midY)))
        #expect(drop == .transition(name: "FadeThroughBlack", left: nil, right: 3))
        #expect(canvas.perform(drop))
        let tr = try #require(view.snapshot.tracks[0].transitions.first)
        #expect(tr.leftClipID == nil && tr.rightClipID == 3 && tr.start == 240 && tr.end == 270)
    }

    @Test func dropEffectOnClip() throws {
        let (m, view) = try makeView()
        let canvas = view.canvas
        let L = view.currentLayout
        let row = L.rowRect(try #require(L.row(forTrack: 0)))
        #expect(canvas.libraryDrop((true, "DropShadow"), at: CGPoint(x: L.x(ofTicks: 200), y: row.midY)) == nil)
        let drop = try #require(canvas.libraryDrop((true, "DropShadow"), at: CGPoint(x: L.x(ofTicks: 40), y: row.midY)))
        #expect(drop == .effect(name: "DropShadow", clipID: 1))
        #expect(canvas.perform(drop))
        #expect(m.undo.undoName == "Add Effect")
        #expect(view.snapshot.clip(1)?.clip.effectCount == 1)
        let fx = try #require(m.project.tracks[0].clips.first?.effects.first)
        #expect(fx.name == "DropShadow")
        #expect(fx.parameters?.object["blur"] != nil)
    }

    @Test func pasteboardTypes() {
        let pb = NSPasteboard(name: NSPasteboard.Name("wizrec-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let (_, view) = (try? makeView()) ?? (nil, nil)
        guard let canvas = view?.canvas else { Issue.record("view"); return }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("Dissolve", forType: TimelineView.transitionType)
        pb.writeObjects([item])
        #expect(canvas.libraryItem(pb)! == (false, "Dissolve"))
        pb.clearContents()
        let fx = NSPasteboardItem()
        fx.setString("Mask", forType: TimelineView.effectType)
        pb.writeObjects([fx])
        #expect(canvas.libraryItem(pb)! == (true, "Mask"))
    }
}
