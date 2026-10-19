import AppKit
import Foundation
import Testing
import TimelineEngine
import TSCProjKit
@testable import TimelineUI

@MainActor
struct GroupEditingTests {
    /// Track 0: clip 1 (0–60) and group 50 at 100 for 120 ticks, showing its inner time 20…140.
    /// Inner track 0: clip 51 (0–100); inner track 1: audio clip 52 (50–150).
    func project() throws -> Project {
        let inner = """
        [{"trackIndex" : 0, "medias" : [\(vm(51, start: 0, dur: 100))], "audioMuted" : false, "videoHidden" : false, \
        "magnetic" : false, "solo" : false},
         {"trackIndex" : 1, "medias" : [\(vm(52, start: 50, dur: 100, type: "AMFile", src: 2))], "audioMuted" : false, \
        "videoHidden" : false, "magnetic" : false, "solo" : false}]
        """
        let group = """
        {"id" : 50, "_type" : "Group", "start" : 100, "duration" : 120, "mediaStart" : 20.0, \
        "mediaDuration" : 120.0, "scalar" : 1, "tracks" : \(inner), "attributes" : {"ident" : "Intro"}}
        """
        return try makeProject(tracks: tracksJSON(trackJSON(0, [vm(1, start: 0, dur: 60), group])),
                               attrs: "[\(attr())]")
    }

    func innerClip(_ p: Project, _ id: Int64) -> Clip? {
        p.tracks.flatMap(\.clips).first { $0.id == 50 }?.tracks.flatMap(\.clips).first { $0.id == id }
    }

    @Test func nestedSnapshotMapsToRootTime() throws {
        let p = try project()
        let s = TimelineSnapshot(project: p, openGroups: [50])
        #expect(s.groupPath == [50] && s.groupNames == ["Intro"])
        #expect(s.tracks.count == 2)
        let c51 = try #require(s.clip(51))
        #expect(c51.track == 0 && c51.clip.start == 80 && c51.clip.duration == 100)
        #expect(s.clip(52)?.clip.start == 130)
        #expect(s.groupWindow == 100...220)
        #expect(s.timeMap.inner(130) == 50 && s.timeMap.display(50) == 130)
        // A path through a missing group is cut there.
        #expect(TimelineSnapshot(project: p, openGroups: [99]).groupPath.isEmpty)
        #expect(TimelineSnapshot(project: p, openGroups: [50, 51]).groupPath == [50])
    }

    @Test func nestedEditsUseInnerTime() throws {
        let m = TimelineModel(undo: UndoStack(project: try project()))
        m.openGroups = [50]
        func editor() -> TimelineEditor { TimelineEditor(model: m, snapshot: TimelineSnapshot(project: m.project, openGroups: m.openGroups)) }
        // Move 51 right by 30 (display 80 → 110 = inner 30).
        let plan = editor().planMove(ids: [51], rawDelta: 30, trackOffset: 0, tolerance: 0)
        #expect(plan.isValid)
        #expect(editor().performMove(plan))
        #expect(innerClip(m.project, 51)?.start == 30)
        // Trim 52's end from display 230 to 210 (inner 130).
        let trim = try #require(editor().planTrim(id: 52, edge: .end, rawDelta: -20, tolerance: 0))
        #expect(editor().performTrim(trim))
        #expect(innerClip(m.project, 52)?.duration == 80)
        // Split at the playhead (display 150 = inner 70): both inner clips.
        m.playhead = 150
        #expect(editor().splitAtPlayhead())
        let group = try #require(m.project.tracks[0].clips.first { $0.id == 50 })
        #expect(group.tracks.map { $0.clips.count } == [2, 2])
        // Header flags go to the inner track.
        #expect(editor().toggle(.audioMuted, track: 1))
        #expect(TimelineSnapshot(project: m.project, openGroups: [50]).tracks[1].audioMuted)
        // No adding/removing tracks inside a group yet.
        #expect(!editor().addTrack(at: 0))
        #expect(!editor().removeTrack(at: 0))
    }

    @Test func nestedEditsStopAtInnerTimeZero() throws {
        let m = TimelineModel(undo: UndoStack(project: try project()))
        m.openGroups = [50]
        let e = TimelineEditor(model: m, snapshot: TimelineSnapshot(project: m.project, openGroups: [50]))
        #expect(e.snapshot.timeOrigin == 80)
        // 51 already sits at inner 0: a left move is clamped to nothing.
        #expect(!e.planMove(ids: [51], rawDelta: -50, trackOffset: 0, tolerance: 0).isValid)
        // 52 (inner 50) moved left by 100 lands on inner 0 = display 80.
        let plan = e.planMove(ids: [52], rawDelta: -100, trackOffset: 0, tolerance: 0)
        #expect(plan.isValid && plan.delta == -50)
        #expect(e.performMove(plan))
        #expect(innerClip(m.project, 52)?.start == 0)
        // Snapping inside a group targets the inner origin, not root tick 0.
        let snaps = EdgeSnapper().targets(snapshot: e.snapshot, playhead: 500, excluding: [51, 52])
        #expect(snaps == [80, 500])
    }

    func makeView() throws -> (TimelineModel, TimelineView, NSWindow) {
        let model = TimelineModel(undo: UndoStack(project: try project()))
        model.pointsPerSecond = 60
        let view = TimelineView(model: model)
        view.canvas.fitsOnFirstLayout = false
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 220)
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

    func key(_ code: UInt16, _ chars: String, _ w: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                         keyCode: code)!
    }

    @Test func doubleClickOpensEscCloses() throws {
        let (model, view, w) = try makeView()
        defer { w.close() }
        let canvas = view.canvas
        let g = try #require(view.currentLayout.clipRect(track: 0, start: 100, duration: 120))
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: g.midX, y: g.midY), in: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: g.midX, y: g.midY), in: canvas))
        let item = NSMenuItem(title: "Open", action: #selector(TimelineView.openGroup(_:)), keyEquivalent: "")
        #expect(view.validateMenuItem(item))
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: g.midX, y: g.midY), in: canvas, clicks: 2))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: g.midX, y: g.midY), in: canvas, clicks: 2))
        #expect(model.openGroups == [50])
        #expect(model.selection.isEmpty)
        let L = view.currentLayout
        #expect(L.banner > 0 && L.rows.count == 2)
        let rep = render(view)
        savePNG(rep, "group-open")
        // The banner is drawn and time outside the group is dimmed.
        #expect(L.hit(CGPoint(x: 300, y: 5), in: view.snapshot) == .breadcrumb(level: 0))
        canvas.keyDown(with: key(53, "\u{1b}", w))
        #expect(model.openGroups.isEmpty && model.selection == [50])
        #expect(view.currentLayout.banner == 0)
    }

    @Test func breadcrumbClickAndCloseAction() throws {
        let (model, view, w) = try makeView()
        defer { w.close() }
        model.openGroups = [50]
        let canvas = view.canvas
        let L = view.currentLayout
        let items = canvas.breadcrumbItems(L)
        #expect(items.map(\.title) == ["Timeline", "Intro", "Close Group  esc"])
        // Clicking "Timeline" goes back to the top level.
        let root = items[0].rect
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: root.midX, y: root.midY), in: canvas))
        #expect(model.openGroups.isEmpty)
        model.openGroups = [50]
        let close = NSMenuItem(title: "Close", action: #selector(TimelineView.closeGroup(_:)), keyEquivalent: "")
        #expect(view.validateMenuItem(close))
        view.closeGroup(close)
        #expect(model.openGroups.isEmpty)
        #expect(!view.validateMenuItem(close))
    }

    @Test func twoLevelBreadcrumbAndEsc() throws {
        // Group 50 holds group 60 (inner 0–100) which holds clip 61.
        let deep = """
        {"id" : 60, "_type" : "Group", "start" : 0, "duration" : 100, "mediaStart" : 0.0, "mediaDuration" : 100.0, \
        "scalar" : 1, "attributes" : {"ident" : "Inner"}, "tracks" : [{"trackIndex" : 0, "medias" : [\(vm(61, start: 10, dur: 50))], \
        "audioMuted" : false, "videoHidden" : false, "magnetic" : false, "solo" : false}]}
        """
        let outer = """
        {"id" : 50, "_type" : "Group", "start" : 100, "duration" : 120, "mediaStart" : 20.0, \
        "mediaDuration" : 120.0, "scalar" : 1, "attributes" : {"ident" : "Intro"}, "tracks" : [{"trackIndex" : 0, \
        "medias" : [\(deep)], "audioMuted" : false, "videoHidden" : false, "magnetic" : false, "solo" : false}]}
        """
        let p = try makeProject(tracks: tracksJSON(trackJSON(0, [outer])), attrs: "[\(attr())]")
        let model = TimelineModel(undo: UndoStack(project: p))
        let view = TimelineView(model: model)
        view.canvas.fitsOnFirstLayout = false
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 220)
        let w = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.contentView = view
        defer { w.close() }
        model.openGroups = [50]
        #expect(view.editor.openGroup(60))
        #expect(model.openGroups == [50, 60])
        let s = view.snapshot
        #expect(s.groupNames == ["Intro", "Inner"])
        // Inner 0 of group 60 = inner 0 of 50 = root 80; clip 61 at root 90.
        #expect(s.timeOrigin == 80 && s.clip(61)?.clip.start == 90)
        let items = view.canvas.breadcrumbItems(view.currentLayout)
        #expect(items.map(\.title) == ["Timeline", "Intro", "Inner", "Close Group  esc"])
        let intro = items[1].rect
        view.canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: intro.midX, y: intro.midY), in: view.canvas))
        #expect(model.openGroups == [50] && model.selection == [60])
        view.canvas.keyDown(with: key(53, "\u{1b}", w))
        #expect(model.openGroups.isEmpty && model.selection == [50])
        // Esc at the top level clears the selection.
        view.canvas.keyDown(with: key(53, "\u{1b}", w))
        #expect(model.selection.isEmpty)
    }

    @Test func openPathDropsDeletedGroup() async throws {
        let (model, view, w) = try makeView()
        defer { w.close() }
        model.openGroups = [50]
        #expect(view.snapshot.groupPath == [50])
        try model.undo.perform(DeleteClips(clipIDs: [50]))
        await drainMainQueue()
        _ = view.snapshot
        #expect(model.openGroups.isEmpty)
    }

    @Test func nestedDragMovesInnerClip() throws {
        let (model, view, w) = try makeView()
        defer { w.close() }
        model.openGroups = [50]
        let canvas = view.canvas
        let L = view.currentLayout
        let c = try #require(L.clipRect(track: 0, start: 80, duration: 100))
        let start = CGPoint(x: c.midX, y: c.midY)
        let end = CGPoint(x: start.x + 40, y: start.y)  // +20 ticks
        canvas.mouseDown(with: mouse(.leftMouseDown, start, in: canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: start.x + 10, y: start.y), in: canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, end, in: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, end, in: canvas))
        #expect(innerClip(model.project, 51)?.start == 20)
        #expect(model.undo.undoName == "Move")
    }
}
