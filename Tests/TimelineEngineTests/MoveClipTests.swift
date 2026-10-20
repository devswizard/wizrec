import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

@MainActor @Test func moveToAnotherTrackKeepsStartOrder() throws {
    let p = try makeProject(tracks: tracks(
        track(0, [leaf(10, start: 0, dur: 100)]),
        track(1, [leaf(11, start: 200, dur: 100)])
    ))
    let move = MoveClip(clipID: 10, toTrack: 1, start: 50)
    try expectReversible(move, on: p)
    try move.apply(to: p)
    try expectTracks(p, tracks(
        track(0, []),
        track(1, [leaf(10, start: 50, dur: 100), leaf(11, start: 200, dur: 100)])
    ))
}

@MainActor @Test func moveWithinTrack() throws {
    let p = try makeProject(tracks: tracks(track(0, [leaf(10, start: 0, dur: 100), leaf(11, start: 100, dur: 100)])))
    let move = MoveClip(clipID: 10, toTrack: 0, start: 300)
    try expectReversible(move, on: p)
    try move.apply(to: p)
    try expectTracks(p, tracks(track(0, [leaf(11, start: 100, dur: 100), leaf(10, start: 300, dur: 100)])))
}

@MainActor @Test func moveRejectsOverlapAndBadTargets() throws {
    let group = """
    {"id" : 30, "_type" : "Group", "start" : 500, "duration" : 50, "mediaStart" : 0.0, "mediaDuration" : 50.0, \
    "scalar" : 1, "tracks" : [\(track(0, [leaf(31, start: 0, dur: 50)]))]}
    """
    let p = try makeProject(tracks: tracks(
        track(0, [leaf(10, start: 0, dur: 100), group]),
        track(1, [leaf(11, start: 200, dur: 100)])
    ))
    expectRejected(MoveClip(clipID: 10, toTrack: 1, start: 150), on: p, .invalid(""))  // overlaps 11 by 50
    expectRejected(MoveClip(clipID: 10, toTrack: 1, start: 299), on: p, .invalid(""))  // overlaps by 1
    expectRejected(MoveClip(clipID: 10, toTrack: 5, start: 0), on: p, .trackNotFound(5))
    expectRejected(MoveClip(clipID: 10, toTrack: 1, start: -10), on: p, .invalid(""))
    expectRejected(MoveClip(clipID: 31, toTrack: 1, start: 0), on: p, .trackNotFound(1))  // group has one inner track
    expectRejected(MoveClip(clipID: 99, toTrack: 1, start: 0), on: p, .clipNotFound(99))
    // Touching edges is not an overlap.
    let touch = MoveClip(clipID: 10, toTrack: 1, start: 100)
    try expectReversible(touch, on: p)
}

@MainActor @Test func moveCarriesFadesAndSplitsBrokenTransitions() throws {
    let transitions = """
    [{"name" : "Fade", "duration" : 10, "rightMedia" : 10},
     {"name" : "RadialWipe", "duration" : 10, "leftMedia" : 10, "rightMedia" : 11},
     {"name" : "Fade", "duration" : 10, "leftMedia" : 11}]
    """
    let p = try makeProject(tracks: tracks(
        track(0, [leaf(10, start: 0, dur: 100), leaf(11, start: 100, dur: 100)], transitions: transitions),
        track(1, [])
    ))
    let move = MoveClip(clipID: 10, toTrack: 1, start: 0)
    try expectReversible(move, on: p)
    try move.apply(to: p)
    try expectTracks(p, tracks(
        // The two-sided wipe splits: 11 keeps a start half in place [obs, TR2].
        track(0, [leaf(11, start: 100, dur: 100)],
              transitions: #"[{"name" : "RadialWipe", "duration" : 10, "rightMedia" : 11}, {"name" : "Fade", "duration" : 10, "leftMedia" : 11}]"#),
        // The destination had no "transitions" key: it is appended; 10 takes the end half.
        #"{"trackIndex" : 1, "medias" : [\#(leaf(10, start: 0, dur: 100))], "parameters" : {}, "#
            + #""transitions" : [{"name" : "Fade", "duration" : 10, "rightMedia" : 10}, {"name" : "RadialWipe", "duration" : 10, "leftMedia" : 10}]}"#
    ))
}

@MainActor @Test func moveWithinTrackKeepsTransitionWhileAdjacent() throws {
    let transitions = #"[{"name" : "RadialWipe", "duration" : 10, "leftMedia" : 10, "rightMedia" : 11}]"#
    let p = try makeProject(tracks: tracks(track(0, [
        leaf(9, start: 0, dur: 20), leaf(10, start: 40, dur: 60), leaf(11, start: 100, dur: 100),
    ], transitions: transitions)))
    // Moving 10 left by 10 breaks the contact with 11: the transition splits
    // into an end half on 10 (appended) and a start half on 11 (in place).
    let apart = MoveClip(clipID: 10, toTrack: 0, start: 30)
    try expectReversible(apart, on: p)
    try apart.apply(to: p)
    try expectTracks(p, tracks(track(0, [
        leaf(9, start: 0, dur: 20), leaf(10, start: 30, dur: 60), leaf(11, start: 100, dur: 100),
    ], transitions: #"[{"name" : "RadialWipe", "duration" : 10, "rightMedia" : 11}, {"name" : "RadialWipe", "duration" : 10, "leftMedia" : 10}]"#)))
    try apart.revert(on: p)

    // A no-op move keeps it.
    let same = MoveClip(clipID: 10, toTrack: 0, start: 40)
    let before = p.serialized()
    try same.apply(to: p)
    #expect(p.serialized() == before)
    try same.revert(on: p)
}

@MainActor @Test func moveUnifiedMediaMovesItsHalves() throws {
    func unified(start: Int64) -> String {
        """
        {"id" : 20, "_type" : "UnifiedMedia", "video" : \(leaf(21, start: start, dur: 50)), \
        "audio" : \(leaf(22, type: "AMFile", start: start, dur: 50, trackNumber: 1)), \
        "start" : \(start), "duration" : 50, "mediaStart" : 0, "mediaDuration" : 50, "scalar" : 1}
        """
    }
    let p = try makeProject(tracks: tracks(track(0, [unified(start: 10)]), track(1, [])))
    let move = MoveClip(clipID: 20, toTrack: 1, start: 70)
    try expectReversible(move, on: p)
    try move.apply(to: p)
    try expectTracks(p, tracks(track(0, []), track(1, [unified(start: 70)])))
}

@MainActor @Test func moveDemoGroupToEmptyTrack() throws {
    let p = try demoProject()
    let move = MoveClip(clipID: 4, toTrack: 1, start: 705_600_000)
    try expectReversible(move, on: p)
    try move.apply(to: p)
    #expect(p.tracks[0].clips.isEmpty)
    #expect(p.tracks[1].clips.map(\.id) == [4])
    #expect(p.tracks[1].clips[0].start == 705_600_000)
}
