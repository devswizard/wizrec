import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

// TL15-2: MoveTrack, RenameTrack, SplitAllTracks, TimelineSelection.

/// trackAttributes entry with a recognisable name and lock state.
private func attrs(_ ident: String, locked: Bool = false) -> String {
    """
    {"ident" : "\(ident)", "audioMuted" : false, "videoHidden" : false, "magnetic" : false, "matte" : 0, \
    "solo" : false, "metadata" : {"IsLocked" : "\(locked ? "True" : "False")", "trackHeight" : "56"}}
    """
}

@MainActor private func project(_ trackJSON: [String], attributes: [String]) throws -> Project {
    let text = """
    {"editRate" : 30, "sourceBin" : [], "timeline" : {"id" : 1, \
    "sceneTrack" : {"scenes" : [{"csml" : {"tracks" : [\(trackJSON.joined(separator: ", "))]}}]}, \
    "trackAttributes" : [\(attributes.joined(separator: ", "))], "captionAttributes" : {}}}
    """
    return try Project(data: Data(text.utf8))
}

@MainActor private func threeTracks(locked: Int? = nil) throws -> Project {
    try project([
        track(0, [leaf(10, start: 0, dur: 100), leaf(11, start: 100, dur: 50)]),
        track(1, [leaf(12, start: 40, dur: 100)]),
        track(2, [leaf(13, start: 50, dur: 10), leaf(14, start: 60, dur: 100)]),
    ], attributes: [attrs("A", locked: locked == 0), attrs("B", locked: locked == 1), attrs("C", locked: locked == 2)])
}

private func idents(_ p: Project) -> [String] {
    (p.timeline?.trackAttributes ?? []).map { $0["ident"]?.string ?? "?" }
}

@MainActor @Test func moveTrackCarriesItsAttributes() throws {
    let p = try threeTracks()
    let up = MoveTrack(from: 0, to: 2)    // Move to Top
    try expectReversible(up, on: p)
    try up.apply(to: p)
    try expectTracks(p, tracks(
        track(0, [leaf(12, start: 40, dur: 100)]),
        track(1, [leaf(13, start: 50, dur: 10), leaf(14, start: 60, dur: 100)]),
        track(2, [leaf(10, start: 0, dur: 100), leaf(11, start: 100, dur: 50)])))
    #expect(idents(p) == ["B", "C", "A"])
    try expectReversible(MoveTrack(from: 2, to: 1), on: p)   // Move Down
    expectRejected(MoveTrack(from: 1, to: 1), on: p, .invalid(""))
    expectRejected(MoveTrack(from: 3, to: 0), on: p, .trackNotFound(3))
    expectRejected(MoveTrack(from: 0, to: -1), on: p, .trackNotFound(-1))
}

@MainActor @Test func renameTrackWritesIdent() throws {
    let p = try threeTracks()
    let r = RenameTrack(track: 1, name: "Voice-over")
    try expectReversible(r, on: p)
    try r.apply(to: p)
    #expect(idents(p) == ["A", "Voice-over", "C"])
    #expect(p.timeline?.trackAttributes[1].keys == ["ident", "audioMuted", "videoHidden", "magnetic", "matte", "solo",
                                                    "metadata"])
    try expectReversible(RenameTrack(track: 1, name: ""), on: p)
    expectRejected(RenameTrack(track: 1, name: "Voice-over"), on: p, .invalid(""))
    expectRejected(RenameTrack(track: 5, name: "x"), on: p, .trackNotFound(5))
}

@MainActor @Test func splitAllTracksSplitsEveryClipUnderThePlayhead() throws {
    let p = try threeTracks(locked: 2)
    let s = SplitAllTracks(at: 70)
    try expectReversible(s, on: p)
    try s.apply(to: p)
    // Track 0: clip 10 split at 70; track 1: clip 12 split; track 2 locked: untouched.
    #expect(s.rightIDs == [15, 16])
    #expect(p.tracks[0].clips.map { [$0.id, $0.start, $0.duration] } == [[10, 0, 70], [15, 70, 30], [11, 100, 50]])
    #expect(p.tracks[1].clips.map { [$0.id, $0.start, $0.duration] } == [[12, 40, 30], [16, 70, 70]])
    #expect(p.tracks[2].clips.map(\.id) == [13, 14])
    try s.revert(on: p)
    // At a clip edge (100 = end of 10, start of 11) nothing on track 0 is split.
    let edge = SplitAllTracks(at: 100)
    try edge.apply(to: p)
    #expect(edge.rightIDs == [15] && p.tracks[0].clips.map(\.id) == [10, 11])
    try edge.revert(on: p)
    expectRejected(SplitAllTracks(at: 500), on: p, .invalid(""))

    let undo = UndoStack(project: p)
    let before = p.serialized()
    try undo.perform(SplitAllTracks(at: 70))
    #expect(undo.undoName == "Split")
    try undo.undo()
    #expect(p.serialized() == before)
}

@MainActor @Test func selectionQueries() throws {
    let p = try threeTracks(locked: 1)
    #expect(TimelineSelection.all(in: p) == [10, 11, 12, 13, 14])
    #expect(TimelineSelection.clips(at: 55, in: p) == [10, 12, 13])
    #expect(TimelineSelection.clips(at: 55, in: p, unlockedOnly: true) == [10, 13])
    #expect(TimelineSelection.clips(at: 100, in: p) == [11, 12, 14])      // end is exclusive
    #expect(TimelineSelection.clips(at: 400, in: p).isEmpty)
    #expect(TimelineSelection.preceding(14, in: p) == [13])
    #expect(TimelineSelection.succeeding(10, in: p) == [11])
    #expect(TimelineSelection.succeeding(11, in: p).isEmpty)
    #expect(TimelineSelection.preceding(99, in: p).isEmpty)
}
