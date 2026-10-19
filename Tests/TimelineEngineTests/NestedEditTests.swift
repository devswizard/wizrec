import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

private func groupTrack(_ i: Int, _ medias: [String], magnetic: Bool = false) -> String {
    #"{"trackIndex" : \#(i), "medias" : [\#(medias.joined(separator: ", "))], "parameters" : {}, "ident" : "", "audioMuted" : false, "videoHidden" : false, "magnetic" : \#(magnetic), "matte" : 0, "solo" : false}"#
}

private func group(_ tracks: [String]) -> String {
    """
    {"id" : 30, "_type" : "Group", "tracks" : [\(tracks.joined(separator: ", "))], "start" : 500, "duration" : 200, \
    "mediaStart" : 0.0, "mediaDuration" : 200.0, "scalar" : 1}
    """
}

@MainActor @Test func moveInsideGroupUsesInnerTracksAndTime() throws {
    let p = try projectWithAttributes([track(0, [leaf(10, start: 0, dur: 100), group([
        groupTrack(0, [leaf(31, start: 0, dur: 50), leaf(32, start: 50, dur: 50)]),
        groupTrack(1, [leaf(33, start: 0, dur: 20)]),
    ])])])
    let move = MoveClip(clipID: 32, toTrack: 1, start: 30)
    try expectReversible(move, on: p)
    try move.apply(to: p)
    let g = try #require(p.tracks[0].clips.last)
    #expect(g.tracks.map { $0.clips.map { [$0.id, $0.start] } } == [[[31, 0]], [[33, 0], [32, 30]]])
    #expect(g.start == 500 && g.duration == 200)  // the group itself is untouched
    try move.revert(on: p)
    expectRejected(MoveClip(clipID: 32, toTrack: 1, start: 10), on: p, .invalid(""))  // overlaps 33
    expectRejected(MoveClip(clipID: 32, toTrack: 2, start: 0), on: p, .trackNotFound(2))

    let ripple = RippleMove(clipID: 31, toTrack: 1, start: 0)
    try expectReversible(ripple, on: p)
    try ripple.apply(to: p)
    let h = try #require(p.tracks[0].clips.last)
    #expect(h.tracks.map { $0.clips.map { [$0.id, $0.start] } } == [[[32, 0]], [[31, 0], [33, 50]]])
}

@MainActor @Test func groupTrackFlagsAndMagneticPacking() throws {
    let p = try projectWithAttributes([track(0, [group([
        groupTrack(0, [leaf(31, start: 10, dur: 50), leaf(32, start: 100, dur: 50)]),
    ])])])
    for flag in TrackFlag.allCases where flag != .magnetic {
        let c = SetGroupTrackFlag(group: 30, track: 0, flag, true)
        try expectReversible(c, on: p)
        try c.apply(to: p)
    }
    let t = try #require(p.tracks[0].clips.first?.tracks.first?.object)
    #expect(t["audioMuted"]?.bool == true && t["videoHidden"]?.bool == true && t["solo"]?.bool == true)
    #expect(t["metadata"]?.object?["IsLocked"]?.string == "True")
    let mag = SetGroupTrackFlag(group: 30, track: 0, .magnetic, true)
    try expectReversible(mag, on: p)
    try mag.apply(to: p)
    #expect(p.tracks[0].clips[0].tracks[0].clips.map(\.start) == [0, 50])
    // A delete on the now-magnetic inner track packs it.
    let del = DeleteClips(clipIDs: [31])
    try expectReversible(del, on: p)
    try del.apply(to: p)
    #expect(p.tracks[0].clips[0].tracks[0].clips.map { [$0.id, $0.start] } == [[32, 0]])
    expectRejected(SetGroupTrackFlag(group: 30, track: 1, .solo, true), on: p, .trackNotFound(1))
    expectRejected(SetGroupTrackFlag(group: 32, track: 0, .solo, true), on: p, .invalid(""))
}

@MainActor @Test func splitAndTrimUseInnerTimelineTicks() throws {
    let p = try projectWithAttributes([track(0, [group([groupTrack(0, [leaf(31, start: 0, dur: 100)])])])])
    let split = SplitClip(clipID: 31, at: 40)  // inner tick 40, not project tick 540
    try split.apply(to: p)
    #expect(p.tracks[0].clips[0].tracks[0].clips.map { [$0.start, $0.duration] } == [[0, 40], [40, 60]])
    let trim = TrimClip(clipID: 31, edge: .end, to: 20)
    try trim.apply(to: p)
    #expect(p.tracks[0].clips[0].tracks[0].clips[0].duration == 20)
}
