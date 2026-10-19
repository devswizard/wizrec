import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

/// Source 1: video stream 0 of 130 ticks, audio stream 1 of 150 ticks
/// (stream editRate 30 = the test project's editRate).
private let sources = """
[{"id" : 1, "src" : "./media/1/a.mp4", "rect" : [0, 0, 640, 360], "sourceTracks" : [
   {"type" : 0, "editRate" : 30, "range" : [0, 130], "sampleRate" : 30},
   {"type" : 2, "editRate" : 30, "range" : [0, 150], "sampleRate" : 48000}]},
 {"id" : 2, "src" : "./media/2/s.tscshadervid", "sourceTracks" : [
   {"type" : 0, "editRate" : 30, "range" : [0, 9223372036854775807], "sampleRate" : 30}]}]
"""

@MainActor @Test func trimEndShrinks() throws {
    let effects = #"[{"effectName" : "dummy", "start" : 20, "duration" : 80}]"#
    let p = try makeProject(tracks: tracks(track(0, [leaf(10, start: 0, dur: 100, ms: "5", effects: effects)])),
                            sourceBin: sources)
    let trim = TrimClip(clipID: 10, edge: .end, to: 60)
    try expectReversible(trim, on: p)
    try trim.apply(to: p)
    #expect(trim.appliedEdge == 60)
    // Effect windows are on media time and stay as they are.
    try expectTracks(p, tracks(track(0, [leaf(10, start: 0, dur: 60, ms: "5", effects: effects)])))
}

@MainActor @Test func trimEndClampsToNeighbour() throws {
    let p = try makeProject(tracks: tracks(track(0, [
        leaf(10, start: 0, dur: 50, src: 2), leaf(11, start: 80, dur: 20, src: 2),
    ])), sourceBin: sources)
    let trim = TrimClip(clipID: 10, edge: .end, to: 500)
    try expectReversible(trim, on: p)
    try trim.apply(to: p)
    #expect(trim.appliedEdge == 80)
    try expectTracks(p, tracks(track(0, [
        leaf(10, start: 0, dur: 80, src: 2), leaf(11, start: 80, dur: 20, src: 2),
    ])))
}

@MainActor @Test func trimEndClampsToAvailableMedia() throws {
    // 130 ticks of video, clip starts at media 20 → at most 110 ticks long.
    let p = try makeProject(tracks: tracks(track(0, [leaf(10, start: 10, dur: 100, ms: "20")])),
                            sourceBin: sources)
    let trim = TrimClip(clipID: 10, edge: .end, to: 500)
    try trim.apply(to: p)
    #expect(trim.appliedEdge == 120)
    try expectTracks(p, tracks(track(0, [leaf(10, start: 10, dur: 110, ms: "20")])))

    // At 2× speed (scalar 1/2) the same 110 media ticks last 55 timeline ticks.
    let q = try makeProject(tracks: tracks(track(0, [
        leaf(10, start: 0, dur: 50, ms: "20", md: "100", scalar: #""1/2""#),
    ])), sourceBin: sources)
    let fast = TrimClip(clipID: 10, edge: .end, to: 500)
    try expectReversible(fast, on: q)
    try fast.apply(to: q)
    #expect(fast.appliedEdge == 55)
    try expectTracks(q, tracks(track(0, [
        leaf(10, start: 0, dur: 55, ms: "20", md: "110", scalar: #""1/2""#),
    ])))
}

@MainActor @Test func trimStartShrinksAndMovesMediaStart() throws {
    let params = """
    {"opacity" : {"type" : "double", "defaultValue" : 1.0, "keyframes" : [
        {"endTime" : 60, "time" : 50, "value" : 0.0, "duration" : 10}]}}
    """
    let p = try makeProject(tracks: tracks(track(0, [
        leaf(10, start: 10, dur: 100, md: "100", parameters: params),
    ])), sourceBin: sources)
    let trim = TrimClip(clipID: 10, edge: .start, to: 30)
    try expectReversible(trim, on: p)
    try trim.apply(to: p)
    // Keyframes stay on media time: same keyframe, now 30 ticks closer to the edge.
    try expectTracks(p, tracks(track(0, [
        leaf(10, start: 30, dur: 80, ms: "20", md: "80", parameters: params),
    ])))
}

@MainActor @Test func trimStartExtendsUntilMediaOrNeighbour() throws {
    // mediaStart 30 → can reveal 30 ticks; the neighbour ends at 80 → only 20.
    let p = try makeProject(tracks: tracks(track(0, [
        leaf(11, start: 0, dur: 80, src: 2), leaf(10, start: 100, dur: 20, ms: "30"),
    ])), sourceBin: sources)
    let trim = TrimClip(clipID: 10, edge: .start, to: 0)
    try expectReversible(trim, on: p)
    try trim.apply(to: p)
    #expect(trim.appliedEdge == 80)
    try expectTracks(p, tracks(track(0, [
        leaf(11, start: 0, dur: 80, src: 2), leaf(10, start: 80, dur: 40, ms: "10"),
    ])))

    let q = try makeProject(tracks: tracks(track(0, [leaf(10, start: 100, dur: 20, ms: "30")])),
                            sourceBin: sources)
    let media = TrimClip(clipID: 10, edge: .start, to: 0)
    try media.apply(to: q)
    #expect(media.appliedEdge == 70)
    try expectTracks(q, tracks(track(0, [leaf(10, start: 70, dur: 50, ms: "0")])))
}

@MainActor @Test func trimStartWithSpeedIsExact() throws {
    // scalar 304/457: moving the start by 100 ticks moves mediaStart by 11425/76.
    let p = try makeProject(tracks: tracks(track(0, [
        leaf(10, start: 0, dur: 3040, md: "4570", scalar: #""304/457""#),
    ])), sourceBin: "[]")
    let trim = TrimClip(clipID: 10, edge: .start, to: 100)
    try expectReversible(trim, on: p)
    try trim.apply(to: p)
    try expectTracks(p, tracks(track(0, [
        leaf(10, start: 100, dur: 2940, ms: #""11425/76""#, md: #""335895/76""#, scalar: #""304/457""#),
    ])))
}

@MainActor @Test func trimUnifiedMediaIsLimitedByShorterHalf() throws {
    func unified(dur: Int64) -> String {
        """
        {"id" : 20, "_type" : "UnifiedMedia", \
        "video" : \(leaf(21, start: 0, dur: dur, trackNumber: 0)), \
        "audio" : \(leaf(22, type: "AMFile", start: 0, dur: dur, trackNumber: 1)), \
        "start" : 0, "duration" : \(dur), "mediaStart" : 0, "mediaDuration" : \(dur), "scalar" : 1}
        """
    }
    let p = try makeProject(tracks: tracks(track(0, [unified(dur: 100)])), sourceBin: sources)
    let trim = TrimClip(clipID: 20, edge: .end, to: 1000)
    try expectReversible(trim, on: p)
    try trim.apply(to: p)
    #expect(trim.appliedEdge == 130)  // video 130 < audio 150
    try expectTracks(p, tracks(track(0, [unified(dur: 130)])))
}

@MainActor @Test func trimImageMovesTrimStartSum() throws {
    func image(start: Int64, dur: Int64, trimmed: Int64) -> String {
        """
        {"id" : 10, "_type" : "IMFile", "src" : 1, "trackNumber" : 0, "trimStartSum" : \(trimmed), \
        "start" : \(start), "duration" : \(dur), "mediaStart" : 0, "mediaDuration" : 1, "scalar" : 1}
        """
    }
    let p = try makeProject(tracks: tracks(track(0, [image(start: 50, dur: 100, trimmed: 0)])))
    let shrink = TrimClip(clipID: 10, edge: .start, to: 70)
    try expectReversible(shrink, on: p)
    try shrink.apply(to: p)
    try expectTracks(p, tracks(track(0, [image(start: 70, dur: 80, trimmed: 20)])))

    // Images have no media limit: both edges can grow freely.
    let grow = TrimClip(clipID: 10, edge: .end, to: 1000)
    try grow.apply(to: p)
    let back = TrimClip(clipID: 10, edge: .start, to: 0)
    try back.apply(to: p)
    try expectTracks(p, tracks(track(0, [image(start: 0, dur: 1000, trimmed: 0)])))
}

@MainActor @Test func trimRejectsEmptyClip() throws {
    let p = try makeProject(tracks: tracks(track(0, [leaf(10, start: 10, dur: 100)])), sourceBin: sources)
    expectRejected(TrimClip(clipID: 10, edge: .end, to: 10), on: p, .invalid(""))
    expectRejected(TrimClip(clipID: 10, edge: .start, to: 110), on: p, .invalid(""))
    expectRejected(TrimClip(clipID: 7, edge: .start, to: 20), on: p, .clipNotFound(7))
}

@MainActor @Test func trimDemoScreenRecordingToStreamLength() throws {
    let p = try demoProject()
    // ScreenVMFile 6 inside the group: stream 0 of the .trec is 1132415 / 44100 s
    // = 18118640000 ticks; the clip already spans the whole frames of it.
    let trim = TrimClip(clipID: 6, edge: .end, to: 30_000_000_000)
    try trim.apply(to: p)
    #expect(trim.appliedEdge == 18_110_400_000)  // 770 frames: rounded down to a frame
    try trim.revert(on: p)

    let shorter = TrimClip(clipID: 6, edge: .start, to: 2_352_000_000)  // 100 frames
    try expectReversible(shorter, on: p)
    try shorter.apply(to: p)
    let group = try #require(p.tracks.first?.clips.first)
    let clip = try #require(group.tracks.flatMap(\.clips).first { $0.id == 6 })
    #expect(clip.start == 2_352_000_000)
    #expect(clip.mediaStart == Rational(2_352_000_000))
    #expect(clip.end == 18_110_400_000)
}
