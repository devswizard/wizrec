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

    @Test func filesAndGroupsHaveNoPreview() throws {
        let view = try makeView()
        #expect(view.canvas.preview(.files([URL(fileURLWithPath: "/tmp/a.mp4")]), track: 0, ticks: 15) == nil)
    }
}
