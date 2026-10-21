import AppKit
import Foundation
import Testing
import TimelineEngine
import TSCProjKit
@testable import TimelineUI

/// Clip and track context menus (APP15-1c, ui-workflow.md §9): the timeline's own items, the
/// app's extra items in their sections, and that each item does its edit.
@MainActor @Suite struct ContextMenuTests {
    /// Track 0: clip 1 (0–60) and clip 3 (100–160); track 1 empty.
    func makeView() throws -> (TimelineModel, TimelineView) {
        let p = try makeProject(tracks: tracksJSON(trackJSON(0, [vm(1, start: 0, dur: 60), vm(3, start: 100, dur: 60)]),
                                                   trackJSON(1, [])),
                                attrs: "[\(attr()), \(attr())]")
        let model = TimelineModel(undo: UndoStack(project: p))
        let view = TimelineView(model: model)
        view.canvas.fitsOnFirstLayout = false
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 200)
        return (model, view)
    }

    func titles(_ menu: NSMenu?) -> [String] { (menu?.items ?? []).map { $0.isSeparatorItem ? "-" : $0.title } }

    @Test func clipMenuOffersEditTimingAndTrackItems() throws {
        let (m, view) = try makeView()
        m.selection = [1]
        m.playhead = 30
        let menu = try #require(view.canvas.contextMenu(for: .clip(id: 1, track: 0, zone: .body)))
        let t = titles(menu)
        #expect(Array(t.prefix(5)) == ["Split at Playhead", "Delete", "Ripple Delete", "-", "Clip Speed"])
        for want in ["Extend Frame", "Add Track Above", "Remove Track", "Lock Track", "Mute Track Audio",
                     "Hide Track Video", "Magnetic Track"] {
            #expect(t.contains(want), "\(want)")
        }
        #expect(menu.items.allSatisfy { $0.isSeparatorItem || $0.isEnabled || $0.title == "Extend Frame" })
        let speeds = try #require(menu.items.first { $0.title == "Clip Speed" }?.submenu)
        #expect(speeds.items.map(\.title) == ["25 %", "50 %", "75 %", "100 %", "150 %", "200 %", "400 %"])
        #expect(speeds.items.first { $0.state == .on }?.title == "100 %")
        // 200 % from the menu: one undo step.
        let double = try #require(speeds.items.first { $0.tag == 200 })
        view.canvas.menuSetSpeed(double)
        #expect(m.undo.undoName == "Clip Speed")
        #expect(view.snapshot.clip(1)?.clip.speed == 2)
    }

    @Test func trackSwitchesToggleAndShowTheirState() throws {
        let (m, view) = try makeView()
        var menu = try #require(view.canvas.contextMenu(for: .header(track: 1, control: nil)))
        let lock = try #require(menu.items.first { $0.title == "Lock Track" })
        #expect(lock.state == .off)
        view.canvas.menuToggleTrackFlag(lock)
        #expect(view.snapshot.track(1)?.locked == true)
        #expect(m.undo.canUndo)
        menu = try #require(view.canvas.contextMenu(for: .header(track: 1, control: nil)))
        #expect(menu.items.first { $0.title == "Lock Track" }?.state == .on)
        let mute = try #require(menu.items.first { $0.title == "Mute Track Audio" })
        view.canvas.menuToggleTrackFlag(mute)
        #expect(view.snapshot.track(1)?.audioMuted == true)
        // The empty part of a track row offers the same track items.
        let row = titles(view.canvas.contextMenu(for: .track(0, ticks: 80)))
        #expect(row.contains("Add Track Below") && row.contains("Hide Track Video") && row.contains("Zoom to Fit"))
    }

    @Test func appItemsJoinTheirSections() throws {
        let (m, view) = try makeView()
        m.selection = [1]
        var seen: [TimelineMenuContext] = []
        m.contextMenuItems = { ctx in
            seen.append(ctx)
            switch ctx.target {
            case .clip:
                return [.clipboard: [NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")],
                        .edit: [NSMenuItem(title: "Ripple Cut", action: nil, keyEquivalent: "")]]
            default:
                return [.clipboard: [NSMenuItem(title: "Paste", action: nil, keyEquivalent: "")]]
            }
        }
        let clip = titles(view.canvas.contextMenu(for: .clip(id: 1, track: 0, zone: .body)))
        #expect(Array(clip.prefix(6)) == ["Copy", "-", "Split at Playhead", "Delete", "Ripple Delete", "Ripple Cut"])
        #expect(seen.last?.target == .clip(1) && seen.last?.track == 0)
        let empty = titles(view.canvas.contextMenu(for: .empty(ticks: 0)))
        #expect(empty.first == "Paste" && empty.contains("Add Track"))
        #expect(seen.last?.target == .background)
    }
}
