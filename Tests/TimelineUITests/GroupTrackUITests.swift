import AppKit
import Foundation
import Testing
import TimelineEngine
import TSCProjKit
@testable import TimelineUI

/// Records performed group-track commands (menu-state probes build commands but never apply them).
@MainActor
final class RecordingGroupTracks: GroupTrackCommands {
    final class Rec: EditCommand {
        let name: String
        let done: () -> Void
        init(_ name: String, _ done: @escaping () -> Void) { self.name = name; self.done = done }
        func apply(to project: Project) throws { done() }
        func revert(on project: Project) throws {}
    }
    var adds: [(group: Int64, index: Int)] = []
    var removes: [(group: Int64, index: Int)] = []
    func addTrack(group: Int64, at index: Int) -> (any EditCommand)? {
        Rec("Add Track") { [weak self] in self?.adds.append((group, index)) }
    }
    func removeTrack(group: Int64, at index: Int) -> (any EditCommand)? {
        Rec("Remove Track") { [weak self] in self?.removes.append((group, index)) }
    }
}

@MainActor
struct GroupTrackUITests {
    /// Same layout as `GroupEditingTests.project()`: group 50 at root 100 (inner 20…140,
    /// time map origin 80) with inner track 0 = clip 51, inner track 1 = clip 52.
    func project() throws -> Project { try GroupEditingTests().project() }

    func editor(_ m: TimelineModel) -> TimelineEditor {
        TimelineEditor(model: m, snapshot: TimelineSnapshot(project: m.project, openGroups: m.openGroups))
    }

    @Test func innerTracksUnavailableWithoutEngineCommands() throws {
        let m = TimelineModel(undo: UndoStack(project: try project()))
        m.openGroups = [50]
        #expect(!editor(m).canAddTrack && !editor(m).canRemoveTrack(at: 0))
        #expect(!editor(m).addTrack(at: 0) && !editor(m).removeTrack(at: 1))
        #expect(!m.undo.canUndo)
    }

    @Test func addAndRemoveInnerTracksGoThroughGroupCommands() throws {
        let m = TimelineModel(undo: UndoStack(project: try project()))
        let rec = RecordingGroupTracks()
        m.groupTracks = rec
        m.openGroups = [50]
        #expect(editor(m).canAddTrack)
        #expect(editor(m).addTrack(at: 99))  // clamped to the top (2 inner tracks)
        #expect(editor(m).addTrack(at: -3))  // clamped to the bottom
        #expect(rec.adds.map(\.group) == [50, 50] && rec.adds.map(\.index) == [2, 0])
        m.selection = [52]
        #expect(editor(m).removeTrack(at: 1))
        #expect(rec.removes.map(\.index) == [1])
        #expect(m.selection.isEmpty)  // clips of the removed track are deselected
        #expect(!editor(m).removeTrack(at: 5))
        #expect(m.undo.undoName == "Remove Track")
        // Top level still uses the scene commands.
        m.openGroups = []
        let before = m.project.tracks.count
        #expect(editor(m).addTrack(at: 0))
        #expect(m.project.tracks.count == before + 1 && rec.adds.count == 2)
    }

    @Test func lastInnerTrackCannotBeRemoved() throws {
        let inner = #"[{"trackIndex" : 0, "medias" : [\#(vm(51, start: 0, dur: 100))], "audioMuted" : false, "videoHidden" : false, "magnetic" : false, "solo" : false}]"#
        let group = """
        {"id" : 50, "_type" : "Group", "start" : 0, "duration" : 100, "mediaStart" : 0.0, \
        "mediaDuration" : 100.0, "scalar" : 1, "tracks" : \(inner), "attributes" : {"ident" : "G"}}
        """
        let p = try makeProject(tracks: tracksJSON(trackJSON(0, [group])), attrs: "[\(attr())]")
        let m = TimelineModel(undo: UndoStack(project: p))
        let rec = RecordingGroupTracks()
        m.groupTracks = rec
        m.openGroups = [50]
        #expect(!editor(m).canRemoveTrack(at: 0) && !editor(m).removeTrack(at: 0))
        #expect(rec.removes.isEmpty)
    }

    @Test func groupDropTargetUsesInnerTimeAndTrack() throws {
        let m = TimelineModel(undo: UndoStack(project: try project()))
        #expect(editor(m).groupDropTarget(track: 0, ticks: 140) == nil)  // top level
        m.openGroups = [50]
        let e = editor(m)
        #expect(e.groupDropTarget(track: 1, ticks: 140) == GroupDropTarget(group: 50, groupPath: [50], track: 1, ticks: 60))
        // Clamped to the visible window root 100…220 = inner 20…140.
        #expect(e.groupDropTarget(track: 0, ticks: 30)?.ticks == 20)
        #expect(e.groupDropTarget(track: 0, ticks: 400)?.ticks == 140)
        #expect(e.groupDropTarget(track: 7, ticks: 140) == nil)
    }

    func makeView() throws -> (TimelineModel, TimelineView, NSWindow) {
        let model = TimelineModel(undo: UndoStack(project: try project()))
        model.pointsPerSecond = 60
        model.snappingEnabled = false
        let view = TimelineView(model: model)
        view.canvas.fitsOnFirstLayout = false
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 220)
        let w = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.contentView = view
        return (model, view, w)
    }

    @Test func mediaDropInsideOpenGroupCallsOnGroupDrop() throws {
        let (model, view, w) = try makeView()
        defer { w.close() }
        var top: [(DropPayload, Int, Int64)] = []
        var inner: [(DropPayload, GroupDropTarget)] = []
        model.onDrop = { p, t, x in top.append((p, t, x)); return true }
        model.openGroups = [50]
        let L = view.currentLayout
        let row = try #require(L.row(forTrack: 1))
        let p = CGPoint(x: L.x(ofTicks: 140), y: L.rowRect(row).midY)
        // No group handler: refused, and `onDrop` is never used inside a group.
        #expect(!view.canvas.acceptsMediaDrops)
        #expect(!view.canvas.performMediaDrop(.sources([1]), at: p))
        model.onGroupDrop = { pl, t in inner.append((pl, t)); return true }
        #expect(view.canvas.acceptsMediaDrops)
        #expect(view.canvas.performMediaDrop(.sources([1]), at: p))
        #expect(top.isEmpty)
        #expect(inner.count == 1)
        #expect(inner.first?.0 == .sources([1]))
        #expect(inner.first?.1 == GroupDropTarget(group: 50, groupPath: [50], track: 1, ticks: 60))
        // Back at the top level drops go to `onDrop` with root ticks.
        model.openGroups = []
        #expect(view.canvas.performMediaDrop(.sources([2]), at: CGPoint(x: L.x(ofTicks: 140), y: p.y)))
        #expect(top.count == 1 && top.first?.2 == 140 && inner.count == 1)
    }

    @Test func headerMenuAndActionsInsideGroup() throws {
        let (model, view, w) = try makeView()
        defer { w.close() }
        model.openGroups = [50]
        let canvas = view.canvas
        canvas.rebuildIfNeeded()
        func titles(_ menu: NSMenu?) -> [String: Bool] {
            Dictionary(uniqueKeysWithValues: (menu?.items ?? []).filter { !$0.isSeparatorItem }.map { ($0.title, $0.isEnabled) })
        }
        // Without engine support the items are shown but disabled.
        var menu = titles(canvas.contextMenu(for: .header(track: 1, control: nil)))
        #expect(menu["Add Track Above"] == false && menu["Remove Track"] == false)
        let addItem = NSMenuItem(title: "Add", action: #selector(TimelineView.addTrack(_:)), keyEquivalent: "")
        #expect(!view.validateMenuItem(addItem))

        let rec = RecordingGroupTracks()
        model.groupTracks = rec
        menu = titles(canvas.contextMenu(for: .header(track: 1, control: nil)))
        #expect(menu["Add Track Above"] == true && menu["Add Track Below"] == true && menu["Remove Track"] == true)
        #expect(titles(canvas.contextMenu(for: .empty(ticks: 0)))["Add Track"] == true)
        #expect(view.validateMenuItem(addItem))
        view.addTrack(nil)
        #expect(rec.adds.map(\.index) == [2])

        // removeTrack: represented track index, else the selected clip's track.
        let removeItem = NSMenuItem(title: "Remove", action: #selector(TimelineView.removeTrack(_:)), keyEquivalent: "")
        #expect(!view.validateMenuItem(removeItem))  // nothing selected, no index
        model.selection = [52]
        #expect(view.validateMenuItem(removeItem))
        view.removeTrack(removeItem)
        #expect(rec.removes.map(\.index) == [1])
        removeItem.representedObject = NSNumber(value: 0)
        view.removeTrack(removeItem)
        #expect(rec.removes.map(\.index) == [1, 0])
    }
}
