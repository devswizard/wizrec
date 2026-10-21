import AppKit
import Foundation
import Testing
import TimelineEngine
import TSCProjKit
@testable import TimelineUI

/// The timeline's hover feedback for media-bin drops shows the drop rules' placement
/// (`DropRules.place`), the same one the drop makes.
@MainActor @Suite struct DropPreviewTests {
    /// One 2 s clip (ticks 0–60 at editRate 30) on the only track.
    func makeView() throws -> TimelineView {
        let p = try makeProject(tracks: tracksJSON(trackJSON(0, [vm(10, start: 0, dur: 60)])), attrs: "[\(attr())]")
        let model = TimelineModel(undo: UndoStack(project: p))
        model.pointsPerSecond = 60
        let view = TimelineView(model: model)
        view.canvas.fitsOnFirstLayout = false
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 200)
        return view
    }

    @Test func previewFollowsTheDropRules() throws {
        let view = try makeView()
        let c = view.canvas
        // The still image (source 3): a free spot takes it where dropped.
        let free = try #require(c.preview(.sources([3]), track: 0, ticks: 90))
        #expect(free.placement.rule == .target && free.placement.track == 0 && free.placement.start == 90)
        #expect(free.duration > 0)
        // 0.5 s into the clip (inside the insert window, first half): inserted at its start.
        let insert = try #require(c.preview(.sources([3]), track: 0, ticks: 15))
        #expect(insert.placement.rule == .insertAtClipStart && insert.placement.start == 0)
        #expect(insert.placement.push == insert.duration)
        // 1.5 s in (second half), no higher track: a new track on top.
        let top = try #require(c.preview(.sources([3]), track: 0, ticks: 45))
        #expect(top.placement.rule == .newTopTrack && top.placement.track == 1)
        // The same placement DropClip makes.
        let drop = DropClip(sourceID: 3, .timeline(track: 0, at: .timeline(15)))
        try drop.apply(to: view.model.project)
        #expect(drop.placement == insert.placement)
    }

    /// Finder files preview once the app reports their clip duration (`fileClipDuration`, probed
    /// on hover); before that, and without a reporter, there is no preview.
    @Test func filesPreviewWithTheProbedDuration() throws {
        let view = try makeView()
        let file = URL(fileURLWithPath: "/tmp/a.mp4")
        #expect(view.canvas.preview(.files([file]), track: 0, ticks: 15) == nil)
        var known: Int64?
        view.model.fileClipDuration = { _ in known }
        #expect(view.canvas.preview(.files([file]), track: 0, ticks: 15) == nil)   // still probing
        known = 40
        let p = try #require(view.canvas.preview(.files([file]), track: 0, ticks: 15))
        #expect(p.duration == 40 && p.placement.rule == .insertAtClipStart && p.placement.push == 40)
        let free = try #require(view.canvas.preview(.files([file]), track: 0, ticks: 90))
        #expect(free.placement.rule == .target && free.placement.start == 90 && free.duration == 40)
    }

    /// Inside an open group the preview is the group drop's placement (`DropRules.place` with the
    /// group), shown in display time. Group 50 at 100 shows inner 20…140; inner clip 51 is 0–100.
    @Test func groupDropPreviewUsesTheInnerTracks() throws {
        let inner = """
        [{"trackIndex" : 0, "medias" : [\(vm(51, start: 0, dur: 100))], "audioMuted" : false, "videoHidden" : false, \
        "magnetic" : false, "solo" : false}]
        """
        let group = """
        {"id" : 50, "_type" : "Group", "start" : 100, "duration" : 120, "mediaStart" : 20.0, \
        "mediaDuration" : 120.0, "scalar" : 1, "tracks" : \(inner), "attributes" : {"ident" : "Intro"}}
        """
        let p = try makeProject(tracks: tracksJSON(trackJSON(0, [group])), attrs: "[\(attr())]")
        let model = TimelineModel(undo: UndoStack(project: p))
        model.openGroups = [50]
        let view = TimelineView(model: model)
        view.canvas.fitsOnFirstLayout = false
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 200)
        // Display 90 = inner 10, 10 ticks into clip 51: inserted at its start (display 80).
        let insert = try #require(view.canvas.preview(.sources([3]), track: 0, ticks: 90))
        #expect(insert.placement.rule == .insertAtClipStart && insert.placement.start == 80)
        // Display 180 = inner 100, after clip 51: the drop's own spot.
        let free = try #require(view.canvas.preview(.sources([3]), track: 0, ticks: 180))
        #expect(free.placement.rule == .target && free.placement.start == 180)
        // The same placement the drop command makes (inner time).
        let drop = DropClip(sourceID: 3, group: 50, .timeline(track: 0, at: .inner(10)))
        try drop.apply(to: model.project)
        #expect(drop.placement?.start == 0 && drop.placement?.rule == .insertAtClipStart)
    }
}
