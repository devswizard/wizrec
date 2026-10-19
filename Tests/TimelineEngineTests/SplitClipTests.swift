import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

@MainActor @Test func splitPlainClip() throws {
    let p = try makeProject(tracks: tracks(track(0, [leaf(10, start: 0, dur: 100, ms: "5")])))
    let split = SplitClip(clipID: 10, at: 40)
    try expectReversible(split, on: p)
    try split.apply(to: p)
    #expect(split.rightID == 11)
    try expectTracks(p, tracks(track(0, [
        leaf(10, start: 0, dur: 40, ms: "5"),
        leaf(11, start: 40, dur: 60, ms: "45"),
    ])))
}

@MainActor @Test func splitHonoursScalarExactly() throws {
    // scalar 304/457 (≈1.5× speed): mediaDuration × scalar = duration.
    let p = try makeProject(tracks: tracks(track(0, [
        leaf(10, start: 0, dur: 3040, md: "4570", scalar: #""304/457""#),
    ])))
    let split = SplitClip(clipID: 10, at: 100)
    try expectReversible(split, on: p)
    try split.apply(to: p)
    // 100 / (304/457) = 11425/76; 4570 − 11425/76 = 335895/76.
    try expectTracks(p, tracks(track(0, [
        leaf(10, start: 0, dur: 100, md: #""11425/76""#, scalar: #""304/457""#),
        leaf(11, start: 100, dur: 2940, ms: #""11425/76""#, md: #""335895/76""#, scalar: #""304/457""#),
    ])))
}

@MainActor @Test func splitKeepsDoubleStyleAndUntouchedLexemes() throws {
    // Groups store mediaStart/mediaDuration as doubles ("0.0").
    let inner = track(0, [leaf(31, start: 0, dur: 100)])
    func group(_ id: Int64, start: Int64, dur: Int64, ms: String, md: String, innerIDs: Int64) -> String {
        """
        {"id" : \(id), "_type" : "Group", "start" : \(start), "duration" : \(dur), "mediaStart" : \(ms), \
        "mediaDuration" : \(md), "scalar" : 1, "tracks" : [\(track(0, [leaf(innerIDs, start: 0, dur: 100)]))], \
        "parameters" : {"translation0" : 172.70, "volume" : 1.0}, "effects" : [], "attributes" : {"ident" : "G"}}
        """
    }
    _ = inner
    let p = try makeProject(tracks: tracks(track(0, [
        group(30, start: 0, dur: 100, ms: "0.0", md: "100.0", innerIDs: 31),
    ])))
    let split = SplitClip(clipID: 30, at: 40)
    try expectReversible(split, on: p)
    try split.apply(to: p)
    try expectTracks(p, tracks(track(0, [
        group(30, start: 0, dur: 40, ms: "0.0", md: "40.0", innerIDs: 31),
        group(32, start: 40, dur: 60, ms: "40.0", md: "60.0", innerIDs: 33),
    ])))
}

@MainActor @Test func splitUnifiedMediaSplitsBothHalves() throws {
    func unified(_ id: Int64, start: Int64, dur: Int64, ms: String) -> String {
        """
        {"id" : \(id), "_type" : "UnifiedMedia", \
        "video" : \(leaf(id + 1, start: start, dur: dur, ms: ms, trackNumber: 0)), \
        "audio" : \(leaf(id + 2, type: "AMFile", start: start, dur: dur, ms: ms, trackNumber: 1)), \
        "start" : \(start), "duration" : \(dur), "mediaStart" : \(ms), "mediaDuration" : \(dur), \
        "scalar" : 1, "effects" : [], "metadata" : {}}
        """
    }
    let p = try makeProject(tracks: tracks(track(0, [unified(20, start: 10, dur: 90, ms: "7")])))
    let split = SplitClip(clipID: 20, at: 40)
    try expectReversible(split, on: p)
    try split.apply(to: p)
    try expectTracks(p, tracks(track(0, [
        unified(20, start: 10, dur: 30, ms: "7"),
        unified(23, start: 40, dur: 60, ms: "37"),
    ])))
}

@MainActor @Test func splitGroupRemapsNestedIDsAndInnerTransitions() throws {
    func group(_ id: Int64, start: Int64, dur: Int64, ms: String) -> String {
        let inner = track(0, [leaf(id + 1, start: 0, dur: 50), leaf(id + 2, start: 50, dur: 50)],
                          transitions: #"[{"name" : "Fade", "duration" : 10, "leftMedia" : \#(id + 1), "rightMedia" : \#(id + 2)}]"#)
        return """
        {"id" : \(id), "_type" : "Group", "start" : \(start), "duration" : \(dur), "mediaStart" : \(ms), \
        "mediaDuration" : \(dur), "scalar" : 1, "tracks" : [\(inner)]}
        """
    }
    let p = try makeProject(tracks: tracks(track(0, [group(30, start: 0, dur: 100, ms: "0")])))
    let split = SplitClip(clipID: 30, at: 25)
    try expectReversible(split, on: p)
    try split.apply(to: p)
    try expectTracks(p, tracks(track(0, [
        group(30, start: 0, dur: 25, ms: "0"),
        group(33, start: 25, dur: 75, ms: "25"),
    ])))
    #expect(Set(allIDs(p)).count == allIDs(p).count)
}

@MainActor @Test func splitStitchedMediaPartitionsSegments() throws {
    func seg(_ id: Int64, _ start: Int64, _ dur: Int64) -> String {
        #"{"id" : \#(id), "_type" : "AMFile", "src" : 1, "start" : \#(start), "duration" : \#(dur), "mediaStart" : \#(start * 2), "mediaDuration" : \#(dur), "scalar" : 1}"#
    }
    func stitched(_ id: Int64, start: Int64, dur: Int64, ms: Int64, segs: [String]) -> String {
        """
        {"id" : \(id), "_type" : "StitchedMedia", "start" : \(start), "duration" : \(dur), \
        "mediaStart" : \(ms), "mediaDuration" : \(dur), "scalar" : 1, "minMediaStart" : 0.0, \
        "medias" : [\(segs.joined(separator: ", "))]}
        """
    }
    // Inner timeline: 41 [0,100), 42 [100,250), 43 [250,400); window [50,350).
    let p = try makeProject(tracks: tracks(track(0, [
        stitched(40, start: 0, dur: 300, ms: 50, segs: [seg(41, 0, 100), seg(42, 100, 150), seg(43, 250, 150)]),
    ])))
    let split = SplitClip(clipID: 40, at: 100)  // inner boundary 150
    try expectReversible(split, on: p)
    try split.apply(to: p)
    // Left [50,150) uses 41, 42. Right [150,350) uses 42, 43, rebased by −100.
    try expectTracks(p, tracks(track(0, [
        stitched(40, start: 0, dur: 100, ms: 50, segs: [seg(41, 0, 100), seg(42, 100, 150)]),
        """
        {"id" : 44, "_type" : "StitchedMedia", "start" : 100, "duration" : 200, \
        "mediaStart" : 50, "mediaDuration" : 200, "scalar" : 1, "minMediaStart" : 0.0, "medias" : [\
        {"id" : 45, "_type" : "AMFile", "src" : 1, "start" : 0, "duration" : 150, "mediaStart" : 200, "mediaDuration" : 150, "scalar" : 1}, \
        {"id" : 46, "_type" : "AMFile", "src" : 1, "start" : 150, "duration" : 150, "mediaStart" : 500, "mediaDuration" : 150, "scalar" : 1}]}
        """,
    ])))
}

@MainActor @Test func splitKeepsKeyframesEffectsAndAnimationsOnMediaTime() throws {
    let params = """
    {"opacity" : {"type" : "double", "defaultValue" : 1.0, "interp" : "linr", "keyframes" : [
        {"endTime" : 30, "time" : 10, "value" : 0.0, "interp" : "linr", "duration" : 20},
        {"endTime" : 80, "time" : 40, "value" : 1.0, "interp" : "linr", "duration" : 40},
        {"endTime" : 100, "time" : 90, "value" : 0.5, "interp" : "linr", "duration" : 10}]},
     "transcription" : {"type" : "string", "keyframes" : [
        {"endTime" : 0, "time" : 0, "value" : "hello", "duration" : 0},
        {"endTime" : 50, "time" : 50, "value" : "world", "duration" : 0},
        {"endTime" : 70, "time" : 70, "value" : "again", "duration" : 0}]},
     "scale0" : 0.5}
    """
    let effects = """
    [{"effectName" : "dummy", "start" : 20, "duration" : 80},
     {"effectName" : "RoundCorners", "parameters" : {"radius" : 12.0}},
     {"effectName" : "dummy", "start" : 70, "duration" : 20}]
    """
    let anim = """
    {"visual" : [{"endTime" : 30, "duration" : 20, "range" : [10, 20]},
                 {"endTime" : 80, "duration" : 40, "range" : [40, 40], "interp" : "eioe"},
                 {"endTime" : 100, "duration" : 10, "range" : [90, 10]}]}
    """
    let p = try makeProject(tracks: tracks(track(0, [
        leaf(10, start: 0, dur: 120, parameters: params, effects: effects, anim: anim),
    ])))
    let split = SplitClip(clipID: 10, at: 60)
    try expectReversible(split, on: p)
    try split.apply(to: p)

    // Keyframes, effect windows and animation segments are on the media time
    // axis (time-mapping.md §6–7): the right half's mediaStart moves to 60
    // and everything else stays byte-for-byte on both halves.
    try expectTracks(p, tracks(track(0, [
        leaf(10, start: 0, dur: 60, parameters: params, effects: effects, anim: anim),
        leaf(11, start: 60, dur: 60, ms: "60", parameters: params, effects: effects, anim: anim),
    ])))
    // The right half shows the same parameter values as before at each instant.
    let right = try #require(p.tracks.first?.clips.last)
    let opacity = try #require(right.parameters["opacity"])
    #expect(opacity.value(at: Int64(right.mediaTime(atTimeline: 60).double)) == 0.5)
}

@MainActor @Test func splitImageMovesTrimStartSumNotMediaTime() throws {
    func image(_ id: Int64, start: Int64, dur: Int64, trimmed: Int64) -> String {
        """
        {"id" : \(id), "_type" : "IMFile", "src" : 1, "trackNumber" : 0, "trimStartSum" : \(trimmed), \
        "start" : \(start), "duration" : \(dur), "mediaStart" : 0, "mediaDuration" : 1, "scalar" : 1}
        """
    }
    let p = try makeProject(tracks: tracks(track(0, [image(10, start: 0, dur: 100, trimmed: 0)])))
    let split = SplitClip(clipID: 10, at: 30)
    try expectReversible(split, on: p)
    try split.apply(to: p)
    try expectTracks(p, tracks(track(0, [
        image(10, start: 0, dur: 30, trimmed: 0),
        image(11, start: 30, dur: 70, trimmed: 30),
    ])))
}

@MainActor @Test func splitSnapsToOutputFrames() throws {
    // 705600000 ticks/s at 30 fps: one frame = 23520000 ticks.
    let frame: Int64 = 23_520_000
    let text = """
    {"editRate" : 705600000, "videoFormatFrameRate" : 30, "allowSubFrameEditing" : false,
     "timeline" : {"id" : 1, "sceneTrack" : {"scenes" : [{"csml" : {"tracks" :
       \(tracks(track(0, [leaf(10, start: 0, dur: 100 * frame)])))}}]}}}
    """
    let p = try Project(data: Data(text.utf8))
    let split = SplitClip(clipID: 10, at: 40 * frame + frame / 3)  // nearer frame 40
    try split.apply(to: p)
    #expect(split.appliedTime == 40 * frame)
    #expect(p.tracks[0].clips[1].start == 40 * frame)
    #expect(p.tracks[0].clips[1].mediaStart == Rational(40 * frame))

    // Sub-frame editing on: no snapping.
    let q = try Project(data: Data(text.replacingOccurrences(of: "false", with: "true").utf8))
    let fine = SplitClip(clipID: 10, at: 40 * frame + 7)
    try fine.apply(to: q)
    #expect(fine.appliedTime == 40 * frame + 7)
}

@MainActor @Test func splitMovesEndTransitionToRightHalf() throws {
    let transitions = """
    [{"name" : "Fade", "duration" : 10, "rightMedia" : 10},
     {"name" : "RadialWipe", "duration" : 10, "leftMedia" : 10, "rightMedia" : 11}]
    """
    let p = try makeProject(tracks: tracks(track(0, [
        leaf(10, start: 0, dur: 100), leaf(11, start: 100, dur: 100),
    ], transitions: transitions)))
    let split = SplitClip(clipID: 10, at: 50)
    try expectReversible(split, on: p)
    try split.apply(to: p)
    try expectTracks(p, tracks(track(0, [
        leaf(10, start: 0, dur: 50), leaf(12, start: 50, dur: 50, ms: "50"), leaf(11, start: 100, dur: 100),
    ], transitions: """
    [{"name" : "Fade", "duration" : 10, "rightMedia" : 10},
     {"name" : "RadialWipe", "duration" : 10, "leftMedia" : 12, "rightMedia" : 11}]
    """)))
}

@MainActor @Test func splitRejectsBadInput() throws {
    let unified = """
    {"id" : 20, "_type" : "UnifiedMedia", "video" : \(leaf(21, start: 200, dur: 50)), \
    "audio" : \(leaf(22, type: "AMFile", start: 200, dur: 50)), "start" : 200, "duration" : 50, \
    "mediaStart" : 0, "mediaDuration" : 50, "scalar" : 1}
    """
    let p = try makeProject(tracks: tracks(track(0, [leaf(10, start: 100, dur: 100), unified])))
    expectRejected(SplitClip(clipID: 10, at: 100), on: p, .invalid(""))   // at start edge
    expectRejected(SplitClip(clipID: 10, at: 200), on: p, .invalid(""))   // at end edge
    expectRejected(SplitClip(clipID: 10, at: 20), on: p, .invalid(""))    // outside
    expectRejected(SplitClip(clipID: 99, at: 150), on: p, .clipNotFound(99))
    expectRejected(SplitClip(clipID: 21, at: 220), on: p, .invalid(""))   // half of a UnifiedMedia
    let never = SplitClip(clipID: 10, at: 150)
    #expect(throws: EditError.self) { try never.revert(on: p) }
}

@MainActor @Test func splitDemoGroupAndNestedClip() throws {
    let p = try demoProject()
    let oldMax = p.maxID
    let group = try #require(p.tracks.first?.clips.first)
    let duration = group.duration

    let split = SplitClip(clipID: group.id, at: 9_008_160_000)  // frame 383 at 30 fps
    try expectReversible(split, on: p)
    try split.apply(to: p)
    let clips = try #require(p.tracks.first?.clips)
    #expect(clips.count == 2)
    #expect(clips[0].id == group.id && clips[0].duration == 9_008_160_000)
    #expect(clips[1].id > oldMax && clips[1].start == 9_008_160_000)
    #expect(clips[0].duration + clips[1].duration == duration)
    #expect(clips[1].object["mediaStart"]?.number?.lexeme == "9008160000.0")
    #expect(clips[1].children.allSatisfy { $0.id > oldMax })
    #expect(Set(allIDs(p)).count == allIDs(p).count)
    // Round-trips through the serialiser.
    #expect(try JSON.parse(p.serialized()) == JSON.object(p.root))

    // A clip inside the group, split in the group's inner time.
    let inner = SplitClip(clipID: 6, at: 5_000_000_000)
    try expectReversible(inner, on: p)
}
