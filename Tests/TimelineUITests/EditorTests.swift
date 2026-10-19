import Foundation
import Testing
import TimelineEngine
import TSCProjKit
@testable import TimelineUI

/// A command that always fails, to test rollback.
@MainActor
final class FailingCommand: EditCommand {
    let name = "Fail"
    func apply(to project: Project) throws { throw EditError.invalid("nope") }
    func revert(on project: Project) throws {}
}

@MainActor
struct EditorTests {
    func setup() throws -> (TimelineModel, TimelineEditor) {
        let model = TimelineModel(undo: UndoStack(project: try sampleProject()))
        return (model, TimelineEditor(model: model, snapshot: TimelineSnapshot(project: model.project)))
    }

    func starts(_ m: TimelineModel) -> [[Int64]] { m.project.tracks.map { $0.clips.map(\.start) } }
    func ids(_ m: TimelineModel) -> [[Int64]] { m.project.tracks.map { $0.clips.map(\.id) } }

    // MARK: Move

    @Test func moveSnapsToNeighbourEdge() throws {
        let (_, e) = try setup()
        // B (120–210) dragged left by 27 → start 93; A ends at 90, within tolerance 5 → snaps to 90.
        let plan = e.planMove(ids: [20], rawDelta: -27, trackOffset: 0, tolerance: 5)
        #expect(plan.delta == -30 && plan.guide == 90 && plan.isValid)
        let free = e.planMove(ids: [20], rawDelta: -27, trackOffset: 0, tolerance: 1)
        #expect(free.delta == -27 && free.guide == nil)
    }

    @Test func moveWithSnappingOff() throws {
        let (m, e) = try setup()
        m.snappingEnabled = false
        let plan = e.planMove(ids: [20], rawDelta: -27, trackOffset: 0, tolerance: 5)
        #expect(plan.delta == -27 && plan.guide == nil)
    }

    @Test func moveValidity() throws {
        let (_, e) = try setup()
        // Onto A: overlap.
        #expect(!e.planMove(ids: [20], rawDelta: -100, trackOffset: 0, tolerance: 0).isValid)
        // Track 0 → 2 is locked.
        #expect(!e.planMove(ids: [20], rawDelta: 0, trackOffset: 2, tolerance: 0).isValid)
        // Track offset clamps to the existing tracks; C on track 1 moved up to 2 (locked) is invalid,
        // moved down onto track 0 (A at 0–90, B at 120–210) overlaps.
        #expect(e.planMove(ids: [30], rawDelta: 0, trackOffset: 5, tolerance: 0).trackOffset == 1)
        #expect(!e.planMove(ids: [30], rawDelta: 0, trackOffset: -1, tolerance: 0).isValid)
        // Never before 0.
        let left = e.planMove(ids: [30], rawDelta: -500, trackOffset: 0, tolerance: 0)
        #expect(left.delta == -30 && left.isValid)
        // No-op is not a move.
        #expect(!e.planMove(ids: [30], rawDelta: 0, trackOffset: 0, tolerance: 0).isValid)
    }

    @Test func performMoveAcrossTracksIsOneUndoStep() throws {
        let (m, e) = try setup()
        let before = m.project.serialized()
        // C (30–150, track 1) → track 0 at 300.
        let plan = e.planMove(ids: [30], rawDelta: 270, trackOffset: -1, tolerance: 0)
        #expect(plan.isValid)
        #expect(e.performMove(plan))
        #expect(ids(m) == [[10, 20, 30], [], []])
        #expect(starts(m)[0] == [0, 120, 300])
        #expect(m.undo.undoName == "Move")
        try m.undo.undo()
        #expect(m.project.serialized() == before)
    }

    @Test func multiMoveKeepsRelativePositions() throws {
        let (m, e) = try setup()
        let before = m.project.serialized()
        // A and B right by 60: B must move first or A would land on it.
        let plan = e.planMove(ids: [10, 20], rawDelta: 60, trackOffset: 0, tolerance: 0)
        #expect(plan.isValid)
        #expect(e.performMove(plan))
        #expect(starts(m)[0] == [60, 180])
        #expect(m.undo.undoName == "Move")
        try m.undo.undo()
        #expect(m.project.serialized() == before)
    }

    // MARK: Trim

    @Test func trimPlansClampToNeighbours() throws {
        let (_, e) = try setup()
        // B's start left by 50 → 70, but A ends at 90.
        #expect(e.planTrim(id: 20, edge: .start, rawDelta: -50, tolerance: 0)?.target == 90)
        // B's end can't pass its start + 1 frame.
        #expect(e.planTrim(id: 20, edge: .end, rawDelta: -500, tolerance: 0)?.target == 121)
        // A's end snaps to the playhead at 0? No: tolerance 3 around 60 finds nothing; C starts at 30.
        #expect(e.planTrim(id: 10, edge: .end, rawDelta: -28, tolerance: 3)?.target == 62)
        let snapped = e.planTrim(id: 10, edge: .end, rawDelta: -58, tolerance: 3)
        #expect(snapped?.target == 30 && snapped?.guide == 30)
    }

    @Test func performTrim() throws {
        let (m, e) = try setup()
        let before = m.project.serialized()
        let plan = try #require(e.planTrim(id: 20, edge: .start, rawDelta: 30, tolerance: 0))
        #expect(e.performTrim(plan))
        let b = try #require(m.project.tracks[0].clips.first { $0.id == 20 })
        #expect(b.start == 150 && b.duration == 60 && b.mediaStart == Rational(330))
        try m.undo.undo()
        #expect(m.project.serialized() == before)
    }

    @Test func lockedTrackRefusesTrim() throws {
        let p = try makeProject(tracks: tracksJSON(trackJSON(0, [vm(1, start: 0, dur: 30)])),
                                attrs: "[\(attr(locked: true))]")
        let m = TimelineModel(undo: UndoStack(project: p))
        #expect(TimelineEditor(model: m, snapshot: TimelineSnapshot(project: p)).planTrim(id: 1, edge: .end, rawDelta: -5, tolerance: 0) == nil)
    }

    // MARK: Split

    @Test func splitTargets() throws {
        let (m, e) = try setup()
        m.playhead = 60
        #expect(Set(e.splitTargets(at: 60)) == [10, 30])
        m.selection = [30]
        #expect(e.splitTargets(at: 60) == [30])
        m.selection = [20]
        #expect(e.splitTargets(at: 60).isEmpty)
        // On an edge: nothing to split.
        m.selection = []
        #expect(e.splitTargets(at: 210).isEmpty)
    }

    @Test func splitAtPlayheadIsOneUndoStep() throws {
        let (m, e) = try setup()
        let before = m.project.serialized()
        m.playhead = 60
        #expect(e.splitAtPlayhead())
        #expect(m.project.tracks[0].clips.count == 3)
        #expect(m.project.tracks[1].clips.count == 2)
        #expect(m.undo.undoName == "Split")
        try m.undo.undo()
        #expect(m.project.serialized() == before)
    }

    // MARK: Delete, tracks, flags (ContractM2 commands; stubs until timeline merges)

    @Test func deleteSelection() throws {
        let (m, e) = try setup()
        let before = m.project.serialized()
        m.selection = [20]
        if e.deleteSelection(ripple: true) {
            #expect(ids(m)[0] == [10])
            #expect(m.selection.isEmpty)
            #expect(m.undo.undoName == "Ripple Delete")
        } else {
            #expect(m.project.serialized() == before)
            #expect(m.lastError?.hasPrefix("Ripple Delete") == true)
            #expect(m.selection == [20])
        }
        m.selection = []
        #expect(!e.deleteSelection(ripple: false))
    }

    @Test func deleteSkipsLockedTracks() throws {
        let p = try makeProject(tracks: tracksJSON(trackJSON(0, [vm(1, start: 0, dur: 30)])),
                                attrs: "[\(attr(locked: true))]")
        let m = TimelineModel(undo: UndoStack(project: p))
        m.selection = [1]
        let e = TimelineEditor(model: m, snapshot: TimelineSnapshot(project: p))
        #expect(e.deletableSelection.isEmpty)
        #expect(!e.deleteSelection(ripple: false))
    }

    @Test func toggleTrackFlagUsesSetTrackFlag() throws {
        let (m, e) = try setup()
        let before = m.project.serialized()
        if e.toggle(.audioMuted, track: 1) {
            #expect(TimelineSnapshot(project: m.project).tracks[1].audioMuted)
            #expect(m.undo.undoName == "Change Track")
        } else {
            #expect(m.project.serialized() == before)
            #expect(m.lastError != nil)
        }
        #expect(!e.toggle(.locked, track: 9))
    }

    @Test func addAndRemoveTrack() throws {
        let (m, e) = try setup()
        let count = m.project.tracks.count
        if e.addTrack(at: 99) { #expect(m.project.tracks.count == count + 1) } else {
            #expect(m.project.tracks.count == count)
        }
        m.selection = [30]
        let e2 = TimelineEditor(model: m, snapshot: TimelineSnapshot(project: m.project))
        if e2.removeTrack(at: 1) { #expect(m.selection.isEmpty) } else { #expect(m.selection == [30]) }
        #expect(!e2.removeTrack(at: 42))
    }

    // MARK: Composite

    @Test func compositeRollsBackOnFailure() throws {
        let (m, _) = try setup()
        let before = m.project.serialized()
        let c = CompositeCommand(name: "Both", [MoveClip(clipID: 30, toTrack: 1, start: 400), FailingCommand()])
        #expect(throws: EditError.self) { try m.undo.perform(c) }
        #expect(m.project.serialized() == before)
        #expect(!m.undo.canUndo)
    }

    @Test func compositeUndoRedo() throws {
        let (m, _) = try setup()
        let before = m.project.serialized()
        let c = CompositeCommand(name: "Two", [MoveClip(clipID: 30, toTrack: 1, start: 400),
                                               SplitClip(clipID: 20, at: 150)])
        try m.undo.perform(c)
        let after = m.project.serialized()
        try m.undo.undo()
        #expect(m.project.serialized() == before)
        try m.undo.redo()
        #expect(m.project.serialized() == after)
    }

    // MARK: Engine snapping, magnetic tracks, markers

    @Test func engineSnappingIncludesMarkers() throws {
        let (m, _) = try setup()
        let e0 = TimelineEditor(model: m, snapshot: TimelineSnapshot(project: m.project))
        #expect(e0.addMarker(at: 300))
        let e = TimelineEditor(model: m, snapshot: TimelineSnapshot(project: m.project))
        #expect(e.snapshot.markers.map(\.time) == [300])
        // B (120–210) dragged right by 88 → end 298 snaps to the marker at 300.
        let plan = e.planMove(ids: [20], rawDelta: 88, trackOffset: 0, tolerance: 3)
        #expect(plan.delta == 90 && plan.guide == 300)
        // A custom snapper (no markers) does not see it.
        var custom = e
        custom.snapper = EdgeSnapper()
        #expect(custom.planMove(ids: [20], rawDelta: 88, trackOffset: 0, tolerance: 3).guide == nil)
        #expect(e.marker(near: 302, tolerance: 3)?.time == 300)
        #expect(e.removeMarker(near: 302, tolerance: 3))
        #expect(TimelineSnapshot(project: m.project).markers.isEmpty)
    }

    @Test func magneticTrackAcceptsOverlappingMove() throws {
        let p = try makeProject(
            tracks: tracksJSON(trackJSON(0, [vm(1, start: 0, dur: 60), vm(2, start: 60, dur: 60)]),
                               trackJSON(1, [vm(3, start: 0, dur: 30)])),
            attrs: "[\(attr(magnetic: true)), \(attr())]")
        let m = TimelineModel(undo: UndoStack(project: p))
        let e = TimelineEditor(model: m, snapshot: TimelineSnapshot(project: p))
        // Clip 3 dropped onto the middle of clip 1 on the magnetic track: allowed.
        let plan = e.planMove(ids: [3], rawDelta: 30, trackOffset: -1, tolerance: 0)
        #expect(plan.isValid)
        #expect(e.performMove(plan))
        #expect(m.project.tracks[1].clips.isEmpty)
        #expect(m.project.tracks[0].clips.count == 3)
        // Trimming the end of a clip on a magnetic track is not limited by the next clip.
        let e2 = TimelineEditor(model: m, snapshot: TimelineSnapshot(project: m.project))
        let first = try #require(e2.snapshot.tracks[0].clips.first)
        #expect(e2.planTrim(id: first.id, edge: .end, rawDelta: 40, tolerance: 0)?.target == first.end + 40)
    }

    // MARK: Snapper

    @Test func edgeSnapperTargets() throws {
        let s = TimelineSnapshot(project: try sampleProject())
        let snap = EdgeSnapper()
        #expect(snap.snap(edges: [118], tolerance: 3, snapshot: s, playhead: 500, excluding: []) ==
                TimelineSnap(delta: 2, guide: 120))
        #expect(snap.snap(edges: [498], tolerance: 3, snapshot: s, playhead: 500, excluding: []) ==
                TimelineSnap(delta: 2, guide: 500))
        #expect(snap.snap(edges: [118], tolerance: 3, snapshot: s, playhead: 500, excluding: [20]) == nil)
        #expect(snap.snap(edges: [2], tolerance: 3, snapshot: s, playhead: 500, excluding: [10]) ==
                TimelineSnap(delta: -2, guide: 0))
    }
}
