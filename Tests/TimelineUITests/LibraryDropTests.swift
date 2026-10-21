import AppKit
import Foundation
import Testing
import TimelineEngine
import TSCProjKit
@testable import TimelineUI

/// Library tiles the app places (APP15-1b): the timeline asks the app on hover and hands it the
/// drop with its target; effects and transitions dropped on the canvas use the clip-level API.
@MainActor @Suite struct LibraryDropTests {
    /// Track 0: clip 1 (0–60) and clip 3 (60–120), touching.
    func makeView() throws -> (TimelineModel, TimelineView) {
        let p = try makeProject(tracks: tracksJSON(trackJSON(0, [vm(1, start: 0, dur: 60), vm(3, start: 60, dur: 60)])),
                                attrs: "[\(attr())]")
        let model = TimelineModel(undo: UndoStack(project: p))
        model.pointsPerSecond = 60
        let view = TimelineView(model: model)
        view.canvas.fitsOnFirstLayout = false
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 200)
        return (model, view)
    }

    @Test func appTilesAreAskedOnHoverAndPerformedOnDrop() throws {
        let (m, view) = try makeView()
        let c = view.canvas
        let L = view.currentLayout
        let row = L.rowRect(try #require(L.row(forTrack: 0)))
        var calls: [(String, TimelineLibraryTarget, Bool)] = []
        m.onLibraryDrop = { type, name, target, perform in
            calls.append((name, target, perform))
            return type == TimelineView.calloutType || target.clipID != nil
        }
        // An annotation over clip 3: accepted, with the clip and time as target.
        let p = CGPoint(x: L.x(ofTicks: 90), y: row.midY)
        let drop = try #require(c.appLibraryDrop((TimelineView.calloutType, "callout-a"), at: p))
        guard case .app(_, "callout-a", let target) = drop else { Issue.record("not an app drop"); return }
        #expect(target.clipID == 3 && target.track == 0 && target.ticks == 90)
        #expect(calls.last?.2 == false)
        #expect(c.perform(drop))
        #expect(calls.last?.2 == true && calls.last?.0 == "callout-a")
        // An audio item needs a clip: refused over empty space.
        let empty = CGPoint(x: L.x(ofTicks: 300), y: row.midY)
        #expect(c.appLibraryDrop((TimelineView.audioItemType, "fadeIn"), at: empty) == nil)
        // No handler: refused.
        m.onLibraryDrop = nil
        #expect(c.appLibraryDrop((TimelineView.calloutType, "callout-a"), at: p) == nil)
        #expect(TimelineView.appLibraryTypes.count == 4)
    }

    @Test func transitionOnBothEdgesOfAClipIsOneStep() throws {
        let (m, view) = try makeView()
        #expect(view.applyTransition(named: "Fade", toEdgesOf: 3))
        #expect(m.undo.undoName == "Add Transition")
        let tr = view.snapshot.tracks[0].transitions
        #expect(tr.count == 2)
        #expect(tr.contains { $0.leftClipID == 1 && $0.rightClipID == 3 })
        #expect(tr.contains { $0.leftClipID == 3 && $0.rightClipID == nil })
        try m.undo.undo()
        #expect(view.snapshot.tracks[0].transitions.isEmpty)
        #expect(view.addEffect(named: "RoundCorners", to: 1))
        #expect(view.snapshot.clip(1)?.clip.effects.map(\.name) == ["RoundCorners"])
        #expect(!view.applyTransition(named: "Fade", toEdgesOf: 99))
    }
}
