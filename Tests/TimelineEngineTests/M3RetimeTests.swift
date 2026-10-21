import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

// MARK: - RippleTrim

@MainActor @Test func rippleTrimEndShiftsLaterClips() throws {
    let p = try projectWithAttributes([track(0, [leaf(10, start: 0, dur: 100, md: "100"), leaf(11, start: 100, dur: 50),
                                                 leaf(12, start: 200, dur: 50)])])
    let grow = RippleTrim(clipID: 10, edge: .end, to: 130)  // no neighbour limit
    try expectReversible(grow, on: p)
    try grow.apply(to: p)
    try expectTracks(p, tracks(track(0, [leaf(10, start: 0, dur: 130, md: "130"), leaf(11, start: 130, dur: 50),
                                         leaf(12, start: 230, dur: 50)])))
    try grow.revert(on: p)
    // Plain TrimClip still stops at the neighbour.
    let plain = TrimClip(clipID: 10, edge: .end, to: 130)
    try plain.apply(to: p)
    #expect(plain.appliedEdge == 100)
}

@MainActor @Test func rippleTrimStartKeepsClipStart() throws {
    let p = try projectWithAttributes([track(0, [leaf(10, start: 50, dur: 100, ms: "20"), leaf(11, start: 150, dur: 50)])])
    let cut = RippleTrim(clipID: 10, edge: .start, to: 80)  // trims 30 off the in-point
    try expectReversible(cut, on: p)
    try cut.apply(to: p)
    #expect(cut.appliedEdge == 80)
    try expectTracks(p, tracks(track(0, [leaf(10, start: 50, dur: 70, ms: "50", md: "70"), leaf(11, start: 120, dur: 50)])))
    try cut.revert(on: p)
    // Extending the in-point is limited by the media (mediaStart 20 → 0) and pushes later clips right.
    let ext = RippleTrim(clipID: 10, edge: .start, to: 0)
    try ext.apply(to: p)
    #expect(ext.appliedEdge == 30)
    try expectTracks(p, tracks(track(0, [leaf(10, start: 50, dur: 120, ms: "0", md: "120"), leaf(11, start: 170, dur: 50)])))
}

@MainActor @Test func trimOnMagneticTrackRipples() throws {
    let p = try projectWithAttributes([track(0, [leaf(10, start: 0, dur: 100, md: "100"), leaf(11, start: 100, dur: 50)])],
                                      magnetic: [0])
    let trim = TrimClip(clipID: 10, edge: .end, to: 60)
    try expectReversible(trim, on: p)
    try trim.apply(to: p)
    try expectTracks(p, tracks(track(0, [leaf(10, start: 0, dur: 60, md: "60"), leaf(11, start: 60, dur: 50)])))
}

// MARK: - RippleMove

@MainActor @Test func rippleMoveClosesAndOpensGaps() throws {
    let p = try projectWithAttributes([
        track(0, [leaf(10, start: 0, dur: 100), leaf(11, start: 100, dur: 50), leaf(12, start: 150, dur: 50)],
              transitions: #"[{"name" : "Fade", "duration" : 5, "rightMedia" : 11}, {"name" : "Cube", "duration" : 5, "leftMedia" : 11, "rightMedia" : 12}]"#),
        track(1, [leaf(20, start: 0, dur: 30), leaf(21, start: 30, dur: 30)]),
    ])
    let move = RippleMove(clipID: 11, toTrack: 1, start: 30)
    try expectReversible(move, on: p)
    try move.apply(to: p)
    try expectTracks(p, tracks(
        track(0, [leaf(10, start: 0, dur: 100), leaf(12, start: 100, dur: 50)],
              transitions: #"[{"name" : "Cube", "duration" : 5, "rightMedia" : 12}]"#),
        track(1, [leaf(20, start: 0, dur: 30), leaf(11, start: 30, dur: 50), leaf(21, start: 80, dur: 30)],
              transitions: #"[{"name" : "Fade", "duration" : 5, "rightMedia" : 11}, {"name" : "Cube", "duration" : 5, "leftMedia" : 11}]"#)))
    try move.revert(on: p)
    expectRejected(RippleMove(clipID: 11, toTrack: 1, start: 10), on: p, .invalid(""))  // inside clip 20
    // Same track: start is read after the gap closes.
    let same = RippleMove(clipID: 10, toTrack: 0, start: 100)
    try expectReversible(same, on: p)
    try same.apply(to: p)
    #expect(p.tracks[0].clips.map { [$0.id, $0.start] } == [[11, 0], [12, 50], [10, 100]])
}

// MARK: - Clip speed

@MainActor @Test func clipSpeedFollowsScalarRule() throws {
    let unified = """
    {"id" : 13, "_type" : "UnifiedMedia", "video" : \(leaf(14, start: 0, dur: 100)), \
    "audio" : \(leaf(15, type: "AMFile", start: 0, dur: 100)), "start" : 0, "duration" : 100, \
    "mediaStart" : 0, "mediaDuration" : 100, "scalar" : 1, \
    "metadata" : {"clipSpeedAttribute" : {"type" : "bool", "value" : false}, "effectApplied" : "none"}}
    """
    let p = try projectWithAttributes([track(0, [unified, leaf(20, start: 200, dur: 10)])])
    let fast = SetClipSpeed(clipID: 13, speed: Rational(3, 2))
    try expectReversible(fast, on: p)
    try fast.apply(to: p)
    // 100 / 1.5 = 66.67 → 66 frames; mediaDuration stays 100, scalar = 66/100 (ED2b).
    let clip = try #require(p.tracks[0].clips.first)
    for part in [clip, try #require(clip.video), try #require(clip.audio)] {
        #expect(part.scalar == Rational(33, 50) && part.duration == 66 && part.mediaDuration == Rational(100))
        #expect(part.object["scalar"] == .string("33/50"))
        #expect(part.object["mediaDuration"]?.int == 100)
    }
    #expect(clip.metadata?["clipSpeedAttribute"]?.object?["value"]?.bool == true)
    #expect(clip.metadata?["effectApplied"]?.string == "Clip Speed")

    let odd = SetClipSpeed(clipID: 20, speed: Rational(7, 3))  // 10 × 3/7 = 4.28 → 4; md kept, scalar 4/10
    try odd.apply(to: p)
    #expect(p.tracks[0].clips[1].object["mediaDuration"]?.int == 10)
    #expect(p.tracks[0].clips[1].object["scalar"] == .string("2/5"))

    // Slowing down into the neighbour throws unless rippled.
    try fast.revert(on: p)
    let q = try projectWithAttributes([track(0, [leaf(10, start: 0, dur: 100), leaf(11, start: 120, dur: 10)])])
    expectRejected(SetClipSpeed(clipID: 10, speed: Rational(1, 2)), on: q, .invalid(""))
    let slow = SetClipSpeed(clipID: 10, speed: Rational(1, 2), ripple: true)
    try expectReversible(slow, on: q)
    try slow.apply(to: q)
    #expect(q.tracks[0].clips.map(\.start) == [0, 220])
    #expect(q.tracks[0].clips[0].object["scalar"]?.int == 2)
    expectRejected(SetClipSpeed(clipID: 10, speed: Rational(0)), on: q, .invalid(""))
}

// MARK: - Extend frame

@MainActor @Test func extendFrameStitchesAFrameImageOfTheVideo() throws {
    // ED1 [obs]: the clip becomes a StitchedMedia of itself + an IMFile on the
    // same video source showing its last frame (media 119 of 20…120).
    let params = #"{"translation0" : 5.0, "geometryCrop0" : 0.1}"#
    let p = try projectWithAttributes([track(0, [leaf(10, start: 0, dur: 100, ms: "20", md: "100", parameters: params),
                                                 leaf(11, start: 100, dur: 10)],
                                             transitions: #"[{"name" : "Fade", "duration" : 5, "leftMedia" : 10}]"#)])
    let hold = ExtendFrame(clipID: 10, duration: 60)
    try expectReversible(hold, on: p)
    try hold.apply(to: p)
    #expect(hold.freezeID == 12 && hold.stitchedID == 13)
    let stitched = """
    {"id" : 13, "_type" : "StitchedMedia", "minMediaStart" : 0.0, \
    "attributes" : {"ident" : "", "gain" : 1.0, "mixToMono" : false, "loudnessNormalization" : true, "sourceFileOffset" : 0}, \
    "parameters" : {"translation0" : 5.0, "geometryCrop0" : 0.0, "geometryCrop1" : 0.0, "geometryCrop2" : 0.0, \
    "geometryCrop3" : 0.0, "volume" : 1.0, "smoothCursorAcrossEditDuration" : 0}, \
    "medias" : [\(leaf(10, start: 0, dur: 100, ms: "20", md: "100", parameters: #"{"geometryCrop0" : 0.1}"#)), \
    {"id" : 12, "_type" : "IMFile", "src" : 1, "trackNumber" : 0, "trimStartSum" : 0, "attributes" : {"ident" : "Frame of "}, \
    "parameters" : {"geometryCrop0" : 0.1}, "effects" : [], "start" : 100, "duration" : 60, "mediaStart" : 119, \
    "mediaDuration" : 1, "scalar" : 1, "animationTracks" : {}}], \
    "effects" : [], "start" : 0, "duration" : 160, "mediaStart" : 0, "mediaDuration" : 160, "scalar" : 1, \
    "metadata" : {"note" : "kept"}, "animationTracks" : {}}
    """
    try expectTracks(p, tracks(track(0, [stitched, leaf(11, start: 160, dur: 10)],
                                     transitions: #"[{"name" : "Fade", "duration" : 5, "leftMedia" : 13}]"#)))

    // Extending again grows the trailing frame segment [inf].
    let more = ExtendFrame(clipID: 13, duration: 30)
    try expectReversible(more, on: p)
    try more.apply(to: p)
    #expect(more.freezeID == 12 && more.stitchedID == 13)
    let s = try #require(p.tracks[0].clips.first)
    #expect([s.duration, s.segments.last?.duration] == [190, 90] && p.tracks[0].clips[1].start == 190)
    expectRejected(ExtendFrame(clipID: 10, duration: 0), on: p, .invalid(""))
    let audio = try projectWithAttributes([track(0, [leaf(10, type: "AMFile", start: 0, dur: 100)])])
    expectRejected(ExtendFrame(clipID: 10, duration: 10), on: audio, .invalid(""))
}

@MainActor @Test func extendFrameOnUnifiedMediaTakesTheVideoChild() throws {
    let unified = """
    {"id" : 20, "_type" : "UnifiedMedia", \
    "video" : {"id" : 21, "_type" : "VMFile", "src" : 3, "trackNumber" : 0, "attributes" : {"ident" : "talk"}, \
    "parameters" : {}, "start" : 0, "duration" : 90, "mediaStart" : 0, "mediaDuration" : 90, "scalar" : 1}, \
    "audio" : {"id" : 22, "_type" : "AMFile", "src" : 3, "trackNumber" : 1, \
    "start" : 0, "duration" : 90, "mediaStart" : 0, "mediaDuration" : 90, "scalar" : 1}, \
    "effects" : [], "start" : 0, "duration" : 90, "mediaStart" : 0, "mediaDuration" : 90, "scalar" : 1}
    """
    let p = try projectWithAttributes([track(0, [unified])])
    let hold = ExtendFrame(clipID: 20, duration: 30)
    try expectReversible(hold, on: p)
    try hold.apply(to: p)
    let s = try #require(p.tracks[0].clips.first)
    #expect(s.kind == .stitched && s.duration == 120 && s.segments.map(\.id) == [20, 23])
    let f = try #require(s.segments.last?.object)
    #expect(f["_type"]?.string == "IMFile" && f["src"]?.int == 3 && f["trackNumber"]?.int == 0)
    let ident = try JSON.parse(#"{"ident" : "Frame of talk"}"#)
    #expect(f["mediaStart"]?.int == 89 && f["attributes"] == ident)
}
