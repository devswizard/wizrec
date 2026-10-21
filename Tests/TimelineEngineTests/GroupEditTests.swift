import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

// Projects here use editRate 30 (one tick per frame) on the default 1920×1080 canvas.

private func gTrack(_ i: Int, _ medias: [String], magnetic: Bool = false, transitions: String? = nil) -> String {
    let t = transitions.map { #", "transitions" : \#($0)"# } ?? ""
    return #"{"trackIndex" : \#(i), "medias" : [\#(medias.joined(separator: ", "))]\#(t), "parameters" : {}, "ident" : "", "audioMuted" : false, "videoHidden" : false, "magnetic" : \#(magnetic), "matte" : 0, "solo" : false}"#
}

private func group(_ id: Int, _ tracks: [String], start: Int64 = 500, dur: Int64 = 200, ms: String = "0.0",
                   md: String = "200.0", scalar: String = "1") -> String {
    """
    {"id" : \(id), "_type" : "Group", "tracks" : [\(tracks.joined(separator: ", "))], \
    "attributes" : {"ident" : "Group 1", "maxDurationAttr" : 7}, "start" : \(start), "duration" : \(dur), \
    "mediaStart" : \(ms), "mediaDuration" : \(md), "scalar" : \(scalar), "metadata" : {"note" : "kept"}}
    """
}

/// Video-only source id 2: 90 frames at 30 fps, 1280×720 (fits the canvas: scale 1).
private let videoSource = """
{"id" : 2, "src" : "./media/1/v.mov", "rect" : [0, 0, 1280, 720], "sourceTracks" : [\
{"range" : [0, 90], "type" : 0, "editRate" : 30, "trackRect" : [0, 0, 1280, 720], "numChannels" : 0}]}
"""

@MainActor
private func project(_ trackJSON: [String], magnetic: Set<Int> = []) throws -> Project {
    let attrs = trackJSON.indices.map { i in
        #"{"ident" : "", "audioMuted" : false, "videoHidden" : false, "magnetic" : \#(magnetic.contains(i)), "matte" : 0, "solo" : false}"#
    }
    let text = """
    {"editRate" : 30, "sourceBin" : [\(videoSource)], "timeline" : {"id" : 1, \
    "sceneTrack" : {"scenes" : [{"csml" : {"tracks" : [\(trackJSON.joined(separator: ", "))]}}]}, \
    "trackAttributes" : [\(attrs.joined(separator: ", "))]}}
    """
    return try Project(data: Data(text.utf8))
}

/// The VMFile `InsertClip` makes from `videoSource`.
private func newVideo(_ id: Int64, start: Int64) -> String {
    let crops = (0..<4).map { #""geometryCrop\#($0)" : {"type" : "double", "defaultValue" : 0.0, "interp" : "eioe"}"# }
    return """
    {"id" : \(id), "_type" : "VMFile", "src" : 2, "trackNumber" : 0, "attributes" : {"ident" : "v"}, \
    "parameters" : {\(crops.joined(separator: ", "))}, "effects" : [], \
    "start" : \(start), "duration" : 90, "mediaStart" : 0, "mediaDuration" : 90, "scalar" : 1, \
    "metadata" : {"audiateLinkedSession" : "", "clipSpeedAttribute" : {"type" : "bool", "value" : false}, \
    "colorAttribute" : {"type" : "color", "value" : [0, 0, 0, 0]}, "default-scale" : "1", "effectApplied" : "none", \
    "lockAspectRatio" : {"type" : "bool", "value" : true}}, \
    "animationTracks" : {}}
    """
}

@MainActor private func trackAttributesText(_ p: Project) -> Data {
    (M2.trackAttributesPath.resolve(in: p.root) ?? .null).serialized()
}

// MARK: - AddGroupTrack / RemoveGroupTrack

@MainActor @Test func addGroupTrackInsertsAndRenumbers() throws {
    let p = try project([track(0, [group(30, [gTrack(0, [leaf(31, start: 0, dur: 50)]), gTrack(1, [leaf(32, start: 0, dur: 20)])])])])
    let attrs = trackAttributesText(p)
    let add = AddGroupTrack(group: 30, at: 1)
    try expectReversible(add, on: p)
    try add.apply(to: p)
    try expectTracks(p, tracks(track(0, [group(30, [
        gTrack(0, [leaf(31, start: 0, dur: 50)]), gTrack(1, []), gTrack(2, [leaf(32, start: 0, dur: 20)]),
    ])])))
    #expect(trackAttributesText(p) == attrs)  // inner tracks have no trackAttributes entry
    try add.revert(on: p)

    let top = AddGroupTrack(group: 30, at: 2)
    try expectReversible(top, on: p)
    try top.apply(to: p)
    let innerCounts: [Int] = p.tracks[0].clips[0].tracks.map { $0.clips.count }
    #expect(innerCounts == [1, 1, 0])
    try top.revert(on: p)

    expectRejected(AddGroupTrack(group: 30, at: 3), on: p, .trackNotFound(3))
    expectRejected(AddGroupTrack(group: 31, at: 0), on: p, .invalid(""))
    expectRejected(AddGroupTrack(group: 99, at: 0), on: p, .clipNotFound(99))
}

@MainActor @Test func removeGroupTrackDropsClipsAndTransitions() throws {
    let transition = #"[{"name" : "Fade", "duration" : 5, "leftMedia" : 31, "rightMedia" : 33}]"#
    let p = try project([track(0, [group(30, [
        gTrack(0, [leaf(31, start: 0, dur: 50), leaf(33, start: 50, dur: 50)], transitions: transition),
        gTrack(1, [leaf(32, start: 0, dur: 20)]),
    ])])])
    let remove = RemoveGroupTrack(group: 30, at: 0)
    try expectReversible(remove, on: p)
    try remove.apply(to: p)
    // Timing of the group is unchanged; track 1 becomes track 0.
    try expectTracks(p, tracks(track(0, [group(30, [gTrack(0, [leaf(32, start: 0, dur: 20)])])])))
    expectRejected(RemoveGroupTrack(group: 30, at: 0), on: p, .invalid(""))  // last track
    try remove.revert(on: p)
    expectRejected(RemoveGroupTrack(group: 30, at: 2), on: p, .trackNotFound(2))
}

@MainActor @Test func groupTrackCommandsReachNestedGroups() throws {
    let inner = group(40, [gTrack(0, [leaf(41, start: 0, dur: 30)])], start: 10, dur: 30, md: "30.0")
    let p = try project([track(0, [group(30, [gTrack(0, [inner])])])])
    let add = AddGroupTrack(group: 40, at: 0)
    try expectReversible(add, on: p)
    try add.apply(to: p)
    try expectTracks(p, tracks(track(0, [group(30, [gTrack(0, [
        group(40, [gTrack(0, []), gTrack(1, [leaf(41, start: 0, dur: 30)])], start: 10, dur: 30, md: "30.0"),
    ])])])))
    try expectReversible(RemoveGroupTrack(group: 40, at: 1), on: p)
}

// MARK: - Time mapping

@MainActor @Test func groupTimingMapsThroughEveryGroup() throws {
    // Outer: start 500, mediaStart 20, scalar 2 (half speed). Inner (on the
    // outer's inner timeline): start 40, mediaStart 5, scalar 1/2.
    let inner = group(40, [gTrack(0, [])], start: 40, dur: 30, ms: "5.0", md: "60.0", scalar: #""1/2""#)
    let p = try project([track(0, [group(30, [gTrack(0, [inner])], ms: "20.0", md: "100.0", scalar: "2")])])
    #expect(try GroupTiming.innerTime(group: 30, timeline: 560, in: p) == Rational(50))
    #expect(try GroupTiming.innerTime(group: 30, timeline: 561, in: p) == Rational(101, 2))
    // 560 → outer 50 → inner 5 + (50 − 40) × 2 = 25.
    #expect(try GroupTiming.innerTime(group: 40, timeline: 560, in: p) == Rational(25))
    #expect(try GroupTiming.timelineTime(group: 40, inner: 25, in: p) == Rational(560))
    #expect(try GroupTiming.timelineTime(group: 30, inner: 20, in: p) == Rational(500))
    #expect(throws: EditError.self) { try GroupTiming.innerTime(group: 41, timeline: 0, in: p) }
}

// MARK: - InsertClipInGroup

@MainActor @Test func insertInGroupAtInnerTime() throws {
    let p = try project([track(0, [group(30, [gTrack(0, [leaf(31, start: 0, dur: 50)]), gTrack(1, [])])])])
    let insert = InsertClipInGroup(sourceID: 2, group: 30, track: 1, at: .inner(60))
    try expectReversible(insert, on: p)
    try insert.apply(to: p)
    #expect(insert.clipID == 32)  // above maxID 31
    // Ends at 150 ≤ visible end 200: the group keeps its timing.
    try expectTracks(p, tracks(track(0, [group(30, [gTrack(0, [leaf(31, start: 0, dur: 50)]), gTrack(1, [newVideo(32, start: 60)])])])))
    try insert.revert(on: p)
    #expect(insert.clipID == nil)

    // Sorted into place among existing clips.
    let before = InsertClipInGroup(sourceID: 2, group: 30, track: 0, at: .inner(50))
    try before.apply(to: p)
    try expectTracks(p, tracks(track(0, [group(30, [gTrack(0, [leaf(31, start: 0, dur: 50), newVideo(32, start: 50)]), gTrack(1, [])])])))
    try before.revert(on: p)

    expectRejected(InsertClipInGroup(sourceID: 2, group: 30, track: 0, at: .inner(10)), on: p, .invalid(""))  // overlaps 31
    expectRejected(InsertClipInGroup(sourceID: 2, group: 30, track: 3, at: .inner(0)), on: p, .trackNotFound(3))
    expectRejected(InsertClipInGroup(sourceID: 2, group: 30, track: -1, at: .inner(0)), on: p, .trackNotFound(-1))
    expectRejected(InsertClipInGroup(sourceID: 9, group: 30, track: 1, at: .inner(0)), on: p, .invalid(""))
    expectRejected(InsertClipInGroup(sourceID: 2, group: 31, track: 0, at: .inner(0)), on: p, .invalid(""))

    // Past the visible end (200): accepted as is, hidden; the group keeps its timing (§8.6).
    let late = InsertClipInGroup(sourceID: 2, group: 30, track: 1, at: .inner(201))
    try expectReversible(late, on: p)
    try late.apply(to: p)
    try expectTracks(p, tracks(track(0, [group(30, [gTrack(0, [leaf(31, start: 0, dur: 50)]), gTrack(1, [newVideo(32, start: 201)])])])))
    try late.revert(on: p)

    // Track index = inner track count: a new top inner track (a drop above the inner tracks).
    let above = InsertClipInGroup(sourceID: 2, group: 30, track: 2, at: .inner(0))
    try expectReversible(above, on: p)
    try above.apply(to: p)
    try expectTracks(p, tracks(track(0, [group(30, [gTrack(0, [leaf(31, start: 0, dur: 50)]), gTrack(1, []),
                                                    gTrack(2, [newVideo(32, start: 0)])])])))
}

@MainActor @Test func insertInGroupMapsTimelineTimeWithoutClamping() throws {
    // Group trimmed on the left (mediaStart 20) at half speed (scalar 2).
    let p = try project([track(0, [group(30, [gTrack(0, [])], ms: "20.0", md: "100.0", scalar: "2")])])
    // Timeline 480 → inner 10, before the window start 20: kept, not clamped (§8.6).
    let early = InsertClipInGroup(sourceID: 2, group: 30, track: 0, at: .timeline(480))
    try expectReversible(early, on: p)
    try early.apply(to: p)
    try expectTracks(p, tracks(track(0, [group(30, [gTrack(0, [newVideo(31, start: 10)])], ms: "20.0", md: "100.0", scalar: "2")])))
    try early.revert(on: p)
    // Timeline 561 → inner 50.5 → 50. Clip end 140 > visible end 120: the group does not grow.
    let insert = InsertClipInGroup(sourceID: 2, group: 30, track: 0, at: .timeline(561))
    try expectReversible(insert, on: p)
    try insert.apply(to: p)
    try expectTracks(p, tracks(track(0, [group(30, [gTrack(0, [newVideo(31, start: 50)])], ms: "20.0", md: "100.0", scalar: "2")])))
    try insert.revert(on: p)
    // Before the inner timeline's zero: a negative inner start is kept.
    let negative = InsertClipInGroup(sourceID: 2, group: 30, track: 0, at: .timeline(400))  // inner 20 − 50 = −30
    try negative.apply(to: p)
    try expectTracks(p, tracks(track(0, [group(30, [gTrack(0, [newVideo(31, start: -30)])], ms: "20.0", md: "100.0", scalar: "2")])))
}

@MainActor @Test func insertInGroupNeverGrowsGroupOrNeighbours() throws {
    let p = try project([track(0, [group(30, [gTrack(0, [])]), leaf(50, start: 720, dur: 10)])])
    // Inner 150 → ends 240, past the window end 200 and past clip 50's start: nothing moves.
    let late = InsertClipInGroup(sourceID: 2, group: 30, track: 0, at: .inner(150))
    try expectReversible(late, on: p)
    try late.apply(to: p)
    try expectTracks(p, tracks(track(0, [group(30, [gTrack(0, [newVideo(51, start: 150)])]), leaf(50, start: 720, dur: 10)])))

    // On a magnetic top-level track the next clip stays too.
    let m = try project([track(0, [group(30, [gTrack(0, [])], start: 0), leaf(50, start: 200, dur: 10)])], magnetic: [0])
    let push = InsertClipInGroup(sourceID: 2, group: 30, track: 0, at: .inner(150))
    try expectReversible(push, on: m)
    try push.apply(to: m)
    try expectTracks(m, tracks(track(0, [group(30, [gTrack(0, [newVideo(51, start: 150)])], start: 0),
                                         leaf(50, start: 200, dur: 10)])))
}

@MainActor @Test func insertInNestedGroupGrowsNoLevel() throws {
    let inner = group(40, [gTrack(0, [])], start: 100, dur: 50, md: "50.0")
    let p = try project([track(0, [group(30, [gTrack(0, [inner])])])])
    // Project 610 → outer inner 110 → inner-group inner 10; the clip ends at 100, past both windows.
    let insert = InsertClipInGroup(sourceID: 2, group: 40, track: 0, at: .timeline(610))
    try expectReversible(insert, on: p)
    try insert.apply(to: p)
    try expectTracks(p, tracks(track(0, [group(30, [gTrack(0, [
        group(40, [gTrack(0, [newVideo(41, start: 10)])], start: 100, dur: 50, md: "50.0"),
    ])])])))
    try insert.revert(on: p)
    let deep = InsertClipInGroup(sourceID: 2, group: 40, track: 0, at: .inner(51))
    try expectReversible(deep, on: p)
    try deep.apply(to: p)
    try expectTracks(p, tracks(track(0, [group(30, [gTrack(0, [
        group(40, [gTrack(0, [newVideo(41, start: 51)])], start: 100, dur: 50, md: "50.0"),
    ])])])))
}

@MainActor @Test func insertOnMagneticGroupTrackPacks() throws {
    let p = try project([track(0, [group(30, [gTrack(0, [leaf(31, start: 0, dur: 40), leaf(32, start: 40, dur: 40)], magnetic: true)])])])
    // Requested at 30: past 31's midpoint (20), before 32's (60) → between them.
    let insert = InsertClipInGroup(sourceID: 2, group: 30, track: 0, at: .inner(30))
    try expectReversible(insert, on: p)
    try insert.apply(to: p)
    // 31 [0,40), new [40,130), 32 [130,170): fits the 200-tick group.
    try expectTracks(p, tracks(track(0, [group(30, [gTrack(0, [
        leaf(31, start: 0, dur: 40), newVideo(33, start: 40), leaf(32, start: 130, dur: 40),
    ], magnetic: true)])])))
}

@MainActor @Test func groupCommandsWorkThroughUndoStack() throws {
    let p = try project([track(0, [group(30, [gTrack(0, [])])])])
    let original = p.serialized()
    let stack = UndoStack(project: p)
    try stack.perform(AddGroupTrack(group: 30, at: 1))
    try stack.perform(InsertClipInGroup(sourceID: 2, group: 30, track: 1, at: .inner(0)))
    try stack.perform(RemoveGroupTrack(group: 30, at: 0))
    let done = p.serialized()
    // Round trip through text keeps the edit exactly.
    #expect(try Project(data: done).serialized() == done)
    try stack.undo(); try stack.undo(); try stack.undo()
    #expect(p.serialized() == original)
    try stack.redo(); try stack.redo(); try stack.redo()
    #expect(p.serialized() == done)
}

// MARK: - Real files

@MainActor @Test func groupEditsOnDemoProjectAreLossless() throws {
    let p = try demoProject()
    let original = p.serialized()
    let g = try #require(p.tracks.flatMap(\.clips).first { $0.kind == .group })
    let n = g.tracks.count
    let add = AddGroupTrack(group: g.id, at: n)
    try expectReversible(add, on: p)
    try add.apply(to: p)
    let after = try #require(p.tracks.flatMap(\.clips).first { $0.id == g.id })
    #expect(after.tracks.count == n + 1)
    #expect(after.tracks.enumerated().allSatisfy { $1.object["trackIndex"]?.int == Int64($0) })
    let srcID = try #require(p.root["sourceBin"]?.array?.items.first?.object?["id"]?.int)
    let insert = InsertClipInGroup(sourceID: srcID, group: g.id, track: n, at: .inner(0))
    let maxID = p.maxID
    try expectReversible(insert, on: p)
    try insert.apply(to: p)
    #expect(try #require(insert.clipID) > maxID)
    let saved = p.serialized()
    #expect(try Project(data: saved).serialized() == saved)
    try insert.revert(on: p)
    try add.revert(on: p)
    #expect(p.serialized() == original)
}

@MainActor @Test(.enabled(if: FileManager.default.fileExists(atPath:
    "/Applications/Camtasia.app/Contents/Resources/ThemeEditorDemo.tscproj")))
func groupTrackCommandsOnInstalledSampleGroup() throws {
    // Read in place; never copied into the repo.
    let p = try Project(contentsOf: URL(fileURLWithPath: "/Applications/Camtasia.app/Contents/Resources/ThemeEditorDemo.tscproj"))
    let g = try #require(p.tracks.flatMap(\.clips).first { $0.kind == .group })
    try expectReversible(AddGroupTrack(group: g.id, at: 0), on: p)
    try expectReversible(RemoveGroupTrack(group: g.id, at: g.tracks.count - 1), on: p)
}
