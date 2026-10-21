import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

// Media-bin drops onto the canvas and onto busy timeline spots (TL14-1):
// ui-workflow.md §4 (canvas cases ui1–ui3), group-edits.md §8.7 (every row of
// the table, top level and inside an open group), ED3. Projects use Camtasia's
// editRate 705600000 at 30 fps (one frame = 23520000 ticks) on the default
// 1920×1080 canvas. Times are the landed starts of the saves (cursor time minus
// the grab offset) where the spec gives them.

private let frame: Int64 = 23_520_000
private func f(_ n: Int64) -> Int64 { n * frame }

private func long(_ v: String) -> String { #"{"type" : "double", "defaultValue" : \#(v), "interp" : "eioe"}"# }

/// Source 1: a 20 s 1920×1080 video (600 frames). Source 2: the 1600×900 photo.
private let bin = """
[{"id" : 1, "src" : "./media/1/video.mp4", "rect" : [0, 0, 1920, 1080], "sourceTracks" : [\
{"range" : [0, 600], "type" : 0, "editRate" : 30, "trackRect" : [0, 0, 1920, 1080], "numChannels" : 0}]}, \
{"id" : 2, "src" : "./media/2/photo.png", "rect" : [0, 0, 1600, 900], "sourceTracks" : [\
{"range" : [0, 1], "type" : 1, "editRate" : 30, "trackRect" : [0, 0, 1600, 900], "numChannels" : 0}]}]
"""

private func video(_ id: Int64, start: Int64, dur: Int64 = f(300)) -> String {
    """
    {"id" : \(id), "_type" : "VMFile", "src" : 1, "trackNumber" : 0, "parameters" : {}, "effects" : [], \
    "start" : \(start), "duration" : \(dur), "mediaStart" : 0, "mediaDuration" : \(dur), "scalar" : 1, \
    "metadata" : {}, "animationTracks" : {}}
    """
}

private func photo(_ id: Int64, start: Int64, dur: Int64 = f(150)) -> String {
    """
    {"id" : \(id), "_type" : "IMFile", "src" : 2, "trackNumber" : 0, "trimStartSum" : 0, "parameters" : {}, \
    "effects" : [], "start" : \(start), "duration" : \(dur), "mediaStart" : 0, "mediaDuration" : 1, "scalar" : 1, \
    "metadata" : {}, "animationTracks" : {}}
    """
}

private let insertMetadata = """
{"audiateLinkedSession" : "", "clipSpeedAttribute" : {"type" : "bool", "value" : false}, \
"colorAttribute" : {"type" : "color", "value" : [0, 0, 0, 0]}, "default-scale" : "1", "effectApplied" : "none", \
"lockAspectRatio" : {"type" : "bool", "value" : true}}
"""

private func crops(_ name: String) -> String {
    (0..<4).map { #""\#(name)\#($0)" : \#(long("0.0"))"# }.joined(separator: ", ")
}

/// The 5 s photo `InsertClip` makes at top level (scale 1: no scale keys).
private func dropped(_ id: Int64, start: Int64) -> String {
    """
    {"id" : \(id), "_type" : "IMFile", "src" : 2, "trackNumber" : 0, "trimStartSum" : 0, \
    "attributes" : {"ident" : "photo"}, "parameters" : {\(crops("sourceCrop")), \(crops("geometryCrop"))}, \
    "effects" : [], "start" : \(start), "duration" : \(f(150)), "mediaStart" : 0, "mediaDuration" : 1, "scalar" : 1, \
    "metadata" : \(insertMetadata), "animationTracks" : {}}
    """
}

/// The 5 s photo `InsertClipInGroup` makes in the 50 %/X 200 group (canvas default re-expressed).
private func droppedInGroup(_ id: Int64, start: Int64) -> String {
    let t = #""translation0" : \#(long("-400.0")), "scale0" : \#(long("2.0")), "scale1" : \#(long("2.0"))"#
    return """
    {"id" : \(id), "_type" : "IMFile", "src" : 2, "trackNumber" : 0, "trimStartSum" : 0, \
    "attributes" : {"ident" : "photo"}, "parameters" : {\(t), \(crops("sourceCrop")), \(crops("geometryCrop"))}, \
    "effects" : [], "start" : \(start), "duration" : \(f(150)), "mediaStart" : 0, "mediaDuration" : 1, "scalar" : 1, \
    "metadata" : \(insertMetadata), "animationTracks" : {}}
    """
}

private let attrs = #"{"ident" : "", "audioMuted" : false, "videoHidden" : false, "magnetic" : false, "matte" : 0, "solo" : false, "metadata" : {"IsLocked" : "False", "trackHeight" : "56"}}"#

/// A top-level project with one `trackAttributes` entry per track (`attr` overrides by index).
@MainActor private func top(_ tracks: [[String]], attr: [Int: String] = [:]) throws -> Project {
    let ts = tracks.enumerated().map { track($0.offset, $0.element) }.joined(separator: ", ")
    let as_ = tracks.indices.map { attr[$0] ?? attrs }.joined(separator: ", ")
    let text = """
    {"editRate" : 705600000, "videoFormatFrameRate" : 30, "width" : 1920.0, "height" : 1080.0, "sourceBin" : \(bin), \
    "timeline" : {"id" : 1, "sceneTrack" : {"scenes" : [{"csml" : {"tracks" : [\(ts)]}}]}, "trackAttributes" : [\(as_)]}}
    """
    return try Project(data: Data(text.utf8))
}

/// `format/video-photo-base`: the video 0–10 s on track 0, the photo 0–5 s on track 1.
private let base: [[String]] = [[video(11, start: 0)], [photo(12, start: 0)]]

private func expected(_ tracks: [[String]]) -> String {
    "[" + tracks.enumerated().map { track($0.offset, $0.element) }.joined(separator: ", ") + "]"
}

private func innerTrack(_ i: Int, _ medias: [String]) -> String {
    #"{"trackIndex" : \#(i), "medias" : [\#(medias.joined(separator: ", "))], "parameters" : {}, "ident" : "", "audioMuted" : false, "videoHidden" : false, "magnetic" : false, "matte" : 0, "solo" : false}"#
}

/// The open `g1-group` (scale 50 %, X 200) at `start`/`ms`/`dur` frames with `inner` tracks.
private func group(_ inner: [[String]], start: Int64 = 0, ms: Int64 = 0, dur: Int64 = 300) -> String {
    let ts = inner.enumerated().map { innerTrack($0.offset, $0.element) }.joined(separator: ", ")
    return """
    {"id" : 10, "_type" : "Group", "parameters" : {"translation0" : 200.0, "scale0" : 0.5, "scale1" : 0.5}, \
    "tracks" : [\(ts)], "attributes" : {"ident" : "Group 1"}, "effects" : [], \
    "start" : \(f(start)), "duration" : \(f(dur)), "mediaStart" : \(f(ms)), "mediaDuration" : \(f(dur)), "scalar" : 1, \
    "metadata" : {"isOpen" : true}, "animationTracks" : {}}
    """
}

/// `mb-base`: the video on inner track 0 (0–10 s), the photo on inner track 1 (0–5 s).
private let groupBase: [[String]] = [[video(11, start: 0)], [photo(12, start: 0)]]

/// Applies `drop` reversibly, checks the placement, the scene, losslessness and
/// (in a group) that the group's timing and the project length are unchanged.
@MainActor private func check(_ drop: DropClip, on p: Project, _ rule: DropPlacement.Rule, _ want: String,
                              sourceLocation: SourceLocation = #_sourceLocation) throws {
    let duration = try DropRules.clipDuration(source: drop.sourceID, in: p)
    let before = p.serialized()
    let placed = try DropRules.place(drop.target, group: drop.group, duration: duration, in: p,
                                     insertWindow: drop.insertWindow)
    #expect(p.serialized() == before, "place mutated the project", sourceLocation: sourceLocation)
    #expect(placed.rule == rule, "rule \(placed.rule)", sourceLocation: sourceLocation)
    let keys = ["start", "duration", "mediaStart", "mediaDuration", "scalar"]
    let timing: [JSON?]? = drop.group.flatMap { try? Locator.locate($0, in: p).clip }.map { g in keys.map { g[$0] } }
    let length = p.duration
    try expectReversible(drop, on: p, sourceLocation: sourceLocation)
    try drop.apply(to: p)
    #expect(drop.placement == placed, sourceLocation: sourceLocation)
    try expectTracks(p, want, sourceLocation: sourceLocation)
    if let timing, let g = drop.group {
        let after = try Locator.locate(g, in: p).clip
        #expect(keys.map { after[$0] } == timing, "group timing changed", sourceLocation: sourceLocation)
        #expect(p.duration == length, "project length changed", sourceLocation: sourceLocation)
    }
    let saved = p.serialized()
    #expect(try Project(data: saved).serialized() == saved, sourceLocation: sourceLocation)
}

// MARK: - §8.7 at top level

@MainActor @Test func d1BusySpotGoesToHigherTrackWithRoom() throws {
    // Track 0 mid-video at 5 s; track 1 free from 5 s → photo on track 1 at 5.0 s.
    let p = try top(base)
    let drop = DropClip(sourceID: 2, .timeline(track: 0, at: .timeline(f(150))))
    try check(drop, on: p, .lowestTrackWithRoom, expected([[video(11, start: 0)], [photo(12, start: 0), dropped(13, start: f(150))]]))
    #expect(drop.clipID == 13)
}

@MainActor @Test func d6BusySpotMidLongVideoGoesToHigherTrack() throws {
    // Video 0–20 s; track 1 busy until 10 s. Drop at 15 s → track 1 at 15 s.
    let p = try top([[video(11, start: 0, dur: f(600))], [photo(12, start: 0), photo(13, start: f(150))]])
    try check(DropClip(sourceID: 2, .timeline(track: 0, at: .timeline(f(450)))), on: p, .lowestTrackWithRoom, expected([
        [video(11, start: 0, dur: f(600))], [photo(12, start: 0), photo(13, start: f(150)), dropped(14, start: f(450))],
    ]))
}

@MainActor @Test func d4NearClipStartInsertsAndPushesThatTrackOnly() throws {
    // Track 0 at 1 s (video starts at 0): photo inserted at 0, video pushed to 5 s; track 1 untouched.
    let p = try top(base)
    try check(DropClip(sourceID: 2, .timeline(track: 0, at: .timeline(f(30)))), on: p, .insertAtClipStart, expected([
        [dropped(13, start: 0), video(11, start: f(150))], [photo(12, start: 0)],
    ]))
}

@MainActor @Test func d5JustAfterBoundaryInsertsAtThatClipsStart() throws {
    // Photo 0–5 s and video 5–15 s on track 0; drop at 5.3 s → inserted at 5 s, video pushed to 10 s.
    let p = try top([[photo(12, start: 0), video(11, start: f(150))], [photo(14, start: 0)]])
    try check(DropClip(sourceID: 2, .timeline(track: 0, at: .timeline(f(159)))), on: p, .insertAtClipStart, expected([
        [photo(12, start: 0), dropped(15, start: f(150)), video(11, start: f(300))], [photo(14, start: 0)],
    ]))
}

@MainActor @Test func d2BusyTopTrackMakesNewTopTrack() throws {
    // The top track (photo) at 2.7 s: past the 1 s insert window, no track above → new track 2.
    let p = try top(base)
    try check(DropClip(sourceID: 2, .timeline(track: 1, at: .timeline(f(81)))), on: p, .newTopTrack, expected([
        [video(11, start: 0)], [photo(12, start: 0)], [dropped(13, start: f(81))],
    ]))
    #expect(p.timeline?.trackAttributes.count == 3)
}

@MainActor @Test func d3BusyWithBusyTrackAboveMakesNewTopTrack() throws {
    // Track 1 at 6.73 s (1.73 s into the second photo, past the 1 s window), track 2 busy → new track 3.
    let p = try top([[video(11, start: 0)], [photo(12, start: 0), photo(13, start: f(150))], [video(14, start: 0)]])
    try check(DropClip(sourceID: 2, .timeline(track: 1, at: .timeline(f(202)))), on: p, .newTopTrack, expected([
        [video(11, start: 0)], [photo(12, start: 0), photo(13, start: f(150))], [video(14, start: 0)],
        [dropped(15, start: f(202))],
    ]))
}

// MARK: - §8.7 inside an open group

@MainActor private func groupProject(_ inner: [[String]], start: Int64 = 0, ms: Int64 = 0, dur: Int64 = 300) throws -> Project {
    try top([[group(inner, start: start, ms: ms, dur: dur)]])
}

private func groupExpected(_ inner: [[String]], start: Int64 = 0, ms: Int64 = 0, dur: Int64 = 300) -> String {
    expected([[group(inner, start: start, ms: ms, dur: dur)]])
}

@MainActor @Test func g1GroupBusySpotGoesToHigherInnerTrack() throws {
    // Inner track 0 mid-video at 7.63 s; inner track 1 free from 5 s → inner track 1 at 7.63 s.
    let p = try groupProject(groupBase)
    try check(DropClip(sourceID: 2, group: 10, .timeline(track: 0, at: .inner(f(229)))), on: p, .lowestTrackWithRoom,
              groupExpected([[video(11, start: 0)], [photo(12, start: 0), droppedInGroup(13, start: f(229))]]))
}

@MainActor @Test func g4GroupNearStartInsertsAndPushesPastWindow() throws {
    // Inner track 0 near the video's start: inserted at inner 0; the video pushed to 5–15 s, past the 10 s
    // window; the group does not grow. Camtasia's drop was ≈ 1.7 s in, outside WizRec's 1 s window, so 0.9 s here.
    let p = try groupProject(groupBase)
    try check(DropClip(sourceID: 2, group: 10, .timeline(track: 0, at: .inner(f(27)))), on: p, .insertAtClipStart,
              groupExpected([[droppedInGroup(13, start: 0), video(11, start: f(150))], [photo(12, start: 0)]]))
}

@MainActor @Test func g2GroupBusyWithBusyInnerTrackAboveMakesNewInnerTrack() throws {
    // Inner track 0 at 3 s (outside the window), inner track 1 busy → new inner track 2 at 3 s.
    // Camtasia's clip landed at 6.07 s (hover lag, §8.7); WizRec keeps the drop time.
    let p = try groupProject(groupBase)
    try check(DropClip(sourceID: 2, group: 10, .timeline(track: 0, at: .inner(f(90)))), on: p, .newTopTrack,
              groupExpected([[video(11, start: 0)], [photo(12, start: 0)], [droppedInGroup(13, start: f(90))]]))
}

@MainActor @Test func g3GroupAllBusyMakesNewInnerTrack() throws {
    // Inner track 0 at ≈ 1.7 s, all inner tracks above busy. Camtasia added nothing (§8.7: a refusal);
    // WizRec adds a new top inner track [WizRec, the forgiving variant].
    let inner = [[video(11, start: 0)], [photo(12, start: 0)], [video(14, start: 0)]]
    let p = try groupProject(inner)
    try check(DropClip(sourceID: 2, group: 10, .timeline(track: 0, at: .inner(f(51)))), on: p, .newTopTrack,
              groupExpected(inner + [[droppedInGroup(15, start: f(51))]]))
}

@MainActor @Test func g5GroupThirtyPercentIntoVideoWithNoRoomMakesNewInnerTrack() throws {
    // After g4 (photo 0–5 s, video 5–15 s on inner track 0), inner track 0 at 8 s (30 % into the video), the inner
    // track above busy. Camtasia added nothing; WizRec adds a new top inner track [WizRec, forgiving variant].
    let inner = [[photo(12, start: 0), video(11, start: f(150))], [video(14, start: 0)]]
    let p = try groupProject(inner)
    try check(DropClip(sourceID: 2, group: 10, .timeline(track: 0, at: .inner(f(240)))), on: p, .newTopTrack,
              groupExpected(inner + [[droppedInGroup(15, start: f(240))]]))
}

@MainActor @Test func groupTimelineTimeMapsThroughTheGroup() throws {
    // Group at 4.7 s, mediaStart 2 s, 8 s long: timeline 9.7 s → inner 7 s, mid-video → inner track 1.
    let p = try groupProject(groupBase, start: 141, ms: 60, dur: 240)
    try check(DropClip(sourceID: 2, group: 10, .timeline(track: 0, at: .timeline(f(291)))), on: p, .lowestTrackWithRoom,
              groupExpected([[video(11, start: 0)], [photo(12, start: 0), droppedInGroup(13, start: f(210))]],
                            start: 141, ms: 60, dur: 240))
}

// MARK: - §4 canvas drops

@MainActor @Test func ui1CanvasAtZeroWithAllTracksBusyMakesNewTopTrack() throws {
    let p = try top(base)
    try check(DropClip(sourceID: 2, .canvas(playhead: 0)), on: p, .newTopTrack, expected(base + [[dropped(13, start: 0)]]))
}

@MainActor @Test func ui2CanvasTakesLowestTrackWithRoom() throws {
    // Playhead 7 s: track 1 free from 5 s (track 2 also free) → track 1.
    let tracks = [[video(11, start: 0)], [photo(12, start: 0)], [photo(13, start: 0)]]
    let p = try top(tracks)
    try check(DropClip(sourceID: 2, .canvas(playhead: f(210))), on: p, .lowestTrackWithRoom, expected([
        [video(11, start: 0)], [photo(12, start: 0), dropped(14, start: f(210))], [photo(13, start: 0)],
    ]))
}

@MainActor @Test func ui3CanvasSkipsTrackWithoutRoomForTheWholeClip() throws {
    // Playhead 5.5 s: track 1 has only 1.5 s free before its next clip → track 2.
    let tracks = [[video(11, start: 0)], [photo(12, start: 0), photo(14, start: f(210))], [photo(13, start: 0)]]
    let p = try top(tracks)
    try check(DropClip(sourceID: 2, .canvas(playhead: f(165))), on: p, .lowestTrackWithRoom, expected([
        [video(11, start: 0)], [photo(12, start: 0), photo(14, start: f(210))], [photo(13, start: 0), dropped(15, start: f(165))],
    ]))
}

@MainActor @Test func canvasInGroupMapsThePlayheadOntoInnerTracks() throws {
    // Group at 4.7 s, mediaStart 2 s: playhead 7.7 s → inner 5 s; inner track 1 free from 5 s.
    let p = try groupProject(groupBase, start: 141, ms: 60, dur: 240)
    try check(DropClip(sourceID: 2, group: 10, .canvas(playhead: f(231))), on: p, .lowestTrackWithRoom,
              groupExpected([[video(11, start: 0)], [photo(12, start: 0), droppedInGroup(13, start: f(150))]],
                            start: 141, ms: 60, dur: 240))
}

// MARK: - Free spots, above the top, details

@MainActor @Test func freeSpotAndAboveTopKeepTodaysBehaviour() throws {
    let p = try top(base)
    try check(DropClip(sourceID: 2, .timeline(track: 1, at: .timeline(f(150)))), on: p, .target, expected([
        [video(11, start: 0)], [photo(12, start: 0), dropped(13, start: f(150))],
    ]))
    let q = try top(base)
    try check(DropClip(sourceID: 2, .timeline(track: 2, at: .timeline(f(40)))), on: q, .newTopTrack,
              expected(base + [[dropped(13, start: f(40))]]))
    // In a group: above the inner tracks → new top inner track; past the window, not clamped.
    let g = try groupProject(groupBase)
    try check(DropClip(sourceID: 2, group: 10, .timeline(track: 2, at: .inner(f(400)))), on: g, .newTopTrack,
              groupExpected(groupBase + [[droppedInGroup(13, start: f(400))]]))
}

@MainActor @Test func insertWindowBoundsAndOverride() throws {
    let p = try top([[video(11, start: 0)], [video(12, start: 0)]])
    let d = f(150)
    func rule(_ t: Int64, window: Int64? = nil) throws -> DropPlacement.Rule {
        try DropRules.place(.timeline(track: 0, at: .timeline(t)), duration: d, in: p, insertWindow: window).rule
    }
    #expect(DropRules.insertWindow(in: p) == f(30))
    #expect(try rule(f(30)) == .insertAtClipStart)        // 1 s: inclusive
    #expect(try rule(f(31)) == .newTopTrack)
    #expect(try rule(f(10), window: f(5)) == .newTopTrack) // zoom-dependent override
    #expect(try rule(f(5), window: f(5)) == .insertAtClipStart)
    // A 1 s clip: a drop in its second half does not insert before it.
    let q = try top([[photo(11, start: 0, dur: f(30))]])
    #expect(try DropRules.place(.timeline(track: 0, at: .timeline(f(20))), duration: d, in: q).rule == .newTopTrack)
    #expect(try DropRules.place(.timeline(track: 0, at: .timeline(f(14))), duration: d, in: q).rule == .insertAtClipStart)
}

@MainActor @Test func pushSplitsTransitionAcrossTheInsertPoint() throws {
    // Photo 0–5 s → video 5–15 s with a Fade between them; an insert at 5 s splits it into one-sided halves.
    let fade = { (l: String, r: String) in
        #"{"name" : "Fade", "duration" : \#(f(15))\#(l)\#(r)}"#
    }
    let two = fade(#", "leftMedia" : 12"#, #", "rightMedia" : 11"#)
    let medias = [photo(12, start: 0), video(11, start: f(150))]
    let text = """
    {"editRate" : 705600000, "videoFormatFrameRate" : 30, "width" : 1920.0, "height" : 1080.0, "sourceBin" : \(bin), \
    "timeline" : {"id" : 1, "sceneTrack" : {"scenes" : [{"csml" : {"tracks" : [\(track(0, medias, transitions: "[\(two)]"))]}}]}, \
    "trackAttributes" : [\(attrs)]}}
    """
    let p = try Project(data: Data(text.utf8))
    let halves = "[\(fade(#", "leftMedia" : 12"#, "")), \(fade("", #", "rightMedia" : 11"#))]"
    try check(DropClip(sourceID: 2, .timeline(track: 0, at: .timeline(f(150)))), on: p, .insertAtClipStart,
              "[\(track(0, [photo(12, start: 0), dropped(13, start: f(150)), video(11, start: f(300))], transitions: halves))]")
}

@MainActor @Test func searchesSkipLockedTracks() throws {
    let locked = #"{"ident" : "", "audioMuted" : false, "videoHidden" : false, "magnetic" : false, "matte" : 0, "solo" : false, "metadata" : {"IsLocked" : "True", "trackHeight" : "56"}}"#
    let p = try top([[video(11, start: 0)], [], [photo(12, start: 0)]], attr: [1: locked])
    let d = f(150)
    // Canvas at 7 s: track 1 is free but locked → track 2 (free from 5 s).
    let c = try DropRules.place(.canvas(playhead: f(210)), duration: d, in: p)
    #expect(c == DropPlacement(rule: .lowestTrackWithRoom, track: 2, start: f(210)))
    // Busy timeline drop at 7 s on track 0: the locked track 1 is skipped too.
    let t = try DropRules.place(.timeline(track: 0, at: .timeline(f(210))), duration: d, in: p)
    #expect(t == DropPlacement(rule: .lowestTrackWithRoom, track: 2, start: f(210)))
}

@MainActor @Test func magneticTargetTakesTheClipAndOffGridInsertSnapsUp() throws {
    let magnetic = #"{"ident" : "", "audioMuted" : false, "videoHidden" : false, "magnetic" : true, "matte" : 0, "solo" : false}"#
    let p = try top([[video(11, start: 0)]], attr: [0: magnetic])
    let m = try DropRules.place(.timeline(track: 0, at: .timeline(f(90))), duration: f(150), in: p)
    #expect(m.rule == .target && m.track == 0)
    // A clip starting 5 ticks after a frame: the insert starts on the next frame and pushes the clip past it.
    let q = try top([[photo(12, start: 0, dur: f(100) + 5), video(11, start: f(100) + 5)]])
    let i = try DropRules.place(.timeline(track: 0, at: .timeline(f(110))), duration: f(150), in: q)
    #expect(i == DropPlacement(rule: .insertAtClipStart, track: 0, start: f(101), push: f(101) + f(150) - f(100) - 5))
}

@MainActor @Test func placeToleratesOddInputAndRejectsMissingIDs() throws {
    let p = try top(base)
    // Negative top-level time clamps to 0; a negative track reads as 0; a huge index is above the top.
    #expect(try DropRules.place(.timeline(track: 1, at: .timeline(-f(9))), duration: f(150), in: p).start == 0)
    #expect(try DropRules.place(.timeline(track: -3, at: .timeline(f(150))), duration: f(150), in: p).track == 1)
    #expect(try DropRules.place(.timeline(track: 9, at: .timeline(0)), duration: f(150), in: p)
            == DropPlacement(rule: .newTopTrack, track: 2, start: 0))
    #expect(throws: EditError.self) { try DropRules.place(.canvas(playhead: 0), group: 99, duration: 1, in: p) }
    #expect(throws: EditError.self) { try DropRules.clipDuration(source: 99, in: p) }
    expectRejected(DropClip(sourceID: 99, .canvas(playhead: 0)), on: p)
    expectRejected(DropClip(sourceID: 2, group: 11, .canvas(playhead: 0)), on: p)
}

@MainActor @Test func undoStackRestoresBytesAfterDrops() throws {
    let p = try top(base)
    let original = p.serialized()
    let undo = UndoStack(project: p)
    try undo.perform(DropClip(sourceID: 2, .canvas(playhead: 0)))
    try undo.perform(DropClip(sourceID: 2, .timeline(track: 0, at: .timeline(f(30)))))
    try undo.perform(DropClip(sourceID: 1, .timeline(track: 0, at: .timeline(f(200)))))
    let after = p.serialized()
    try undo.undo(); try undo.undo(); try undo.undo()
    #expect(p.serialized() == original)
    try undo.redo(); try undo.redo(); try undo.redo()
    #expect(p.serialized() == after)
    #expect(try Project(data: after).serialized() == after)
}
