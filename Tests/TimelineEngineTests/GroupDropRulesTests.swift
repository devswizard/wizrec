import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

// Media-bin drops into an open group as Camtasia does them (group-edits.md
// §8.6 [obs], TL12-2): no growth, no clamp, new top inner track above the
// inner tracks, canvas-default transform re-expressed through the groups.
// Projects use Camtasia's editRate 705600000 at 30 fps (one frame = 23520000
// ticks) on the default 1920×1080 canvas.

private let frame: Int64 = 23_520_000
private func f(_ n: Int64) -> Int64 { n * frame }

private func long(_ v: String) -> String { #"{"type" : "double", "defaultValue" : \#(v), "interp" : "eioe"}"# }

/// Source 1: the 10 s 1920×1080 video (300 frames). Source 2: the 1600×900 photo.
private let bin = """
[{"id" : 1, "src" : "./media/1/video.mp4", "rect" : [0, 0, 1920, 1080], "sourceTracks" : [\
{"range" : [0, 300], "type" : 0, "editRate" : 30, "trackRect" : [0, 0, 1920, 1080], "numChannels" : 0}]}, \
{"id" : 2, "src" : "./media/2/photo.png", "rect" : [0, 0, 1600, 900], "sourceTracks" : [\
{"range" : [0, 1], "type" : 1, "editRate" : 30, "trackRect" : [0, 0, 1600, 900], "numChannels" : 0}]}]
"""

private func innerTrack(_ i: Int, _ medias: [String]) -> String {
    #"{"trackIndex" : \#(i), "medias" : [\#(medias.joined(separator: ", "))], "parameters" : {}, "ident" : "", "audioMuted" : false, "videoHidden" : false, "magnetic" : false, "matte" : 0, "solo" : false}"#
}

private func video(_ id: Int64, start: Int64, dur: Int64) -> String {
    """
    {"id" : \(id), "_type" : "VMFile", "src" : 1, "trackNumber" : 0, "parameters" : {}, "effects" : [], \
    "start" : \(start), "duration" : \(dur), "mediaStart" : 0, "mediaDuration" : \(dur), "scalar" : 1, \
    "metadata" : {}, "animationTracks" : {}}
    """
}

private func photo(_ id: Int64, start: Int64, dur: Int64) -> String {
    """
    {"id" : \(id), "_type" : "IMFile", "src" : 2, "trackNumber" : 0, "trimStartSum" : 0, "parameters" : {}, \
    "effects" : [], "start" : \(start), "duration" : \(dur), "mediaStart" : 0, "mediaDuration" : 1, "scalar" : 1, \
    "metadata" : {}, "animationTracks" : {}}
    """
}

/// `g1-group`: the video (inner track 0) and the photo (inner track 1, 0–5 s), grouped,
/// scale 50 % and X 200, open. `start`/`ms`/`dur` in frames.
private func g1(start: Int64 = 0, ms: Int64 = 0, dur: Int64 = 300, _ tracks: [String]? = nil) -> String {
    let inner = tracks ?? [innerTrack(0, [video(11, start: 0, dur: f(300))]), innerTrack(1, [photo(12, start: 0, dur: f(150))])]
    return """
    {"id" : 10, "_type" : "Group", "parameters" : {"translation0" : 200.0, "scale0" : 0.5, "scale1" : 0.5}, \
    "tracks" : [\(inner.joined(separator: ", "))], "attributes" : {"ident" : "Group 1"}, "effects" : [], \
    "start" : \(f(start)), "duration" : \(f(dur)), "mediaStart" : \(f(ms)), "mediaDuration" : \(f(dur)), "scalar" : 1, \
    "metadata" : {"isOpen" : true}, "animationTracks" : {}}
    """
}

@MainActor private func project(_ group: String) throws -> Project {
    let text = """
    {"editRate" : 705600000, "videoFormatFrameRate" : 30, "width" : 1920.0, "height" : 1080.0, "sourceBin" : \(bin), \
    "timeline" : {"id" : 1, "sceneTrack" : {"scenes" : [{"csml" : {"tracks" : [\(track(0, [group]))]}}]}, \
    "trackAttributes" : [{"ident" : "", "audioMuted" : false, "videoHidden" : false, "magnetic" : false, "matte" : 0, "solo" : false}]}}
    """
    return try Project(data: Data(text.utf8))
}

/// Insert metadata of a new clip (ED0 / §8.6 clip keys).
private let insertMetadata = """
{"audiateLinkedSession" : "", "clipSpeedAttribute" : {"type" : "bool", "value" : false}, \
"colorAttribute" : {"type" : "color", "value" : [0, 0, 0, 0]}, "default-scale" : "1", "effectApplied" : "none", \
"lockAspectRatio" : {"type" : "bool", "value" : true}}
"""

/// The canvas-default transform inside the 50 %/X 200 group: X −400, scale 2, long form.
private let canvasDefault = #""translation0" : \#(long("-400.0")), "scale0" : \#(long("2.0")), "scale1" : \#(long("2.0"))"#

private func crops(_ name: String) -> String {
    (0..<4).map { #""\#(name)\#($0)" : \#(long("0.0"))"# }.joined(separator: ", ")
}

/// The photo a drop makes: 5 s, canvas-default transform, image crops then geometry crops.
private func droppedPhoto(_ id: Int64, start: Int64) -> String {
    """
    {"id" : \(id), "_type" : "IMFile", "src" : 2, "trackNumber" : 0, "trimStartSum" : 0, \
    "attributes" : {"ident" : "photo"}, "parameters" : {\(canvasDefault), \(crops("sourceCrop")), \(crops("geometryCrop"))}, \
    "effects" : [], "start" : \(start), "duration" : \(f(150)), "mediaStart" : 0, "mediaDuration" : 1, "scalar" : 1, \
    "metadata" : \(insertMetadata), "animationTracks" : {}}
    """
}

/// The video a drop makes: 10 s, canvas-default transform, geometry crops.
private func droppedVideo(_ id: Int64, start: Int64) -> String {
    """
    {"id" : \(id), "_type" : "VMFile", "src" : 1, "trackNumber" : 0, "attributes" : {"ident" : "video"}, \
    "parameters" : {\(canvasDefault), \(crops("geometryCrop"))}, "effects" : [], \
    "start" : \(start), "duration" : \(f(300)), "mediaStart" : 0, "mediaDuration" : \(f(300)), "scalar" : 1, \
    "metadata" : \(insertMetadata), "animationTracks" : {}}
    """
}

/// Applies `drop` (reversibly), checks the scene, the group's timing text and losslessness.
@MainActor private func check(_ drop: InsertClipInGroup, on p: Project, _ want: String,
                              sourceLocation: SourceLocation = #_sourceLocation) throws {
    let group = try Locator.locate(10, in: p).clip
    let timing: [JSON?] = ["start", "duration", "mediaStart", "mediaDuration", "scalar"].map { group[$0] }
    let length = p.duration
    try expectReversible(drop, on: p, sourceLocation: sourceLocation)
    try drop.apply(to: p)
    try expectTracks(p, want, sourceLocation: sourceLocation)
    let after = try Locator.locate(10, in: p).clip
    #expect(["start", "duration", "mediaStart", "mediaDuration", "scalar"].map { after[$0] } == timing,
            "group timing changed", sourceLocation: sourceLocation)
    #expect(p.duration == length, "project length changed", sourceLocation: sourceLocation)
    let saved = p.serialized()
    #expect(try Project(data: saved).serialized() == saved, sourceLocation: sourceLocation)
}

@MainActor @Test func mb1PhotoOnInnerTrackRunsPastWindowEnd() throws {
    // Inner 7.667 s (230 frames) on inner track 1, running to 12.667 s, past the 10 s window.
    let p = try project(g1())
    let drop = InsertClipInGroup(sourceID: 2, group: 10, track: 1, at: .inner(f(230)))
    try check(drop, on: p, tracks(track(0, [g1([
        innerTrack(0, [video(11, start: 0, dur: f(300))]),
        innerTrack(1, [photo(12, start: 0, dur: f(150)), droppedPhoto(13, start: f(230))]),
    ])])))
    #expect(drop.clipID == 13)
}

@MainActor @Test func mb2VideoAboveInnerTracksMakesNewTopTrack() throws {
    // Timeline 11.567 s (347 frames, group at 0): new inner track 2, wholly outside the window.
    let p = try project(g1())
    try check(InsertClipInGroup(sourceID: 1, group: 10, track: 2, at: .timeline(f(347))), on: p, tracks(track(0, [g1([
        innerTrack(0, [video(11, start: 0, dur: f(300))]),
        innerTrack(1, [photo(12, start: 0, dur: f(150))]),
        innerTrack(2, [droppedVideo(13, start: f(347))]),
    ])])))
}

@MainActor @Test func mb3PhotoOntoBusyInnerTrackAddsNothing() throws {
    let p = try project(g1())
    expectRejected(InsertClipInGroup(sourceID: 2, group: 10, track: 0, at: .inner(f(90))), on: p, .invalid(""))
}

@MainActor @Test func mb4OffsetGroupMapsTimelineThroughStartAndMediaStart() throws {
    // Group at 4.7 s, mediaStart 2 s, 8 s long. Timeline 7.7 s → inner 7.7 − 4.7 + 2 = 5.0 s.
    let inner = [innerTrack(0, [video(11, start: 0, dur: f(300))]), innerTrack(1, [photo(12, start: 0, dur: f(150))])]
    let p = try project(g1(start: 141, ms: 60, dur: 240, inner))
    try check(InsertClipInGroup(sourceID: 2, group: 10, track: 2, at: .timeline(f(231))), on: p,
              tracks(track(0, [g1(start: 141, ms: 60, dur: 240, inner + [innerTrack(2, [droppedPhoto(13, start: f(150))])])])))
}

@MainActor @Test func mb5DropBeforeWindowKeepsNegativeInnerStart() throws {
    // Timeline 1.7 s → inner 1.7 − 4.7 + 2 = −1.0 s = −705600000, not clamped.
    let inner = [innerTrack(0, [video(11, start: 0, dur: f(300))]), innerTrack(1, [photo(12, start: 0, dur: f(150))]),
                 innerTrack(2, [])]
    let p = try project(g1(start: 141, ms: 60, dur: 240, inner))
    let drop = InsertClipInGroup(sourceID: 2, group: 10, track: 2, at: .timeline(f(51)))
    try check(drop, on: p, tracks(track(0, [g1(start: 141, ms: 60, dur: 240, [
        inner[0], inner[1], innerTrack(2, [droppedPhoto(13, start: -705_600_000)]),
    ])])))
}

@MainActor @Test func nestedGroupsComposeIntoTheInverseTransform() throws {
    // Outer X 100 / 50 %, inner group X 200 / 50 % inside it: canvas = 100 + 0.5 × (200 + 0.5 × local).
    // The canvas default (0, scale 1) is local X (0 − 200) / 0.25 = −800, scale 4.
    let innerGroup = """
    {"id" : 20, "_type" : "Group", "parameters" : {"translation0" : 200.0, "scale0" : 0.5, "scale1" : 0.5}, \
    "tracks" : [\(innerTrack(0, []))], "attributes" : {"ident" : "Group 2"}, "effects" : [], \
    "start" : 0, "duration" : \(f(300)), "mediaStart" : 0, "mediaDuration" : \(f(300)), "scalar" : 1, \
    "metadata" : {}, "animationTracks" : {}}
    """
    let outer = """
    {"id" : 10, "_type" : "Group", "parameters" : {"translation0" : 100.0, "scale0" : 0.5, "scale1" : 0.5}, \
    "tracks" : [\(innerTrack(0, [innerGroup]))], "attributes" : {"ident" : "Group 1"}, "effects" : [], \
    "start" : 0, "duration" : \(f(300)), "mediaStart" : 0, "mediaDuration" : \(f(300)), "scalar" : 1, \
    "metadata" : {}, "animationTracks" : {}}
    """
    let p = try project(outer)
    let drop = InsertClipInGroup(sourceID: 2, group: 20, track: 0, at: .inner(0))
    try expectReversible(drop, on: p)
    try drop.apply(to: p)
    let id = try #require(drop.clipID)
    let params = try #require(Locator.locate(id, in: p).clip["parameters"]?.object)
    #expect(params["translation0"] == (try JSON.parse(long("-800.0"))))
    #expect(params["scale0"] == (try JSON.parse(long("4.0"))))
    #expect(params["scale1"] == (try JSON.parse(long("4.0"))))
    #expect(params["translation1"] == nil)
    // A zero-scale group can't take the canvas default.
    let flat = try project(g1().replacingOccurrences(of: #""scale0" : 0.5"#, with: #""scale0" : 0.0"#))
    expectRejected(InsertClipInGroup(sourceID: 2, group: 10, track: 2, at: .inner(0)), on: flat, .invalid(""))
}

@MainActor @Test func dropsThroughUndoStackRestoreBytes() throws {
    let p = try project(g1())
    let original = p.serialized()
    let stack = UndoStack(project: p)
    try stack.perform(InsertClipInGroup(sourceID: 2, group: 10, track: 1, at: .inner(f(230))))
    try stack.perform(InsertClipInGroup(sourceID: 1, group: 10, track: 2, at: .timeline(f(347))))
    try stack.perform(InsertClipInGroup(sourceID: 2, group: 10, track: 2, at: .inner(-f(30))))
    let done = p.serialized()
    #expect(try Project(data: done).serialized() == done)
    try stack.undo(); try stack.undo(); try stack.undo()
    #expect(p.serialized() == original)
    try stack.redo(); try stack.redo(); try stack.redo()
    #expect(p.serialized() == done)
}

@MainActor @Test func dropIntoDemoGroupOnTempCopyIsLossless() throws {
    // A temp copy of the demo fixture: drop before and after the group's window, save, reload.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-mb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("demo.tscproj")
    try demoProject().serialized().write(to: url)
    let p = try Project(contentsOf: url)
    let original = p.serialized()
    let g: Clip = try #require(p.tracks.flatMap(\.clips).first { (c: Clip) -> Bool in c.kind == .group })
    let groupBefore: Data = JSON.object(g.object).serialized()
    let srcID = try #require(p.root["sourceBin"]?.array?.items.first?.object?["id"]?.int)
    let n = g.tracks.count
    let stack = UndoStack(project: p)
    try stack.perform(InsertClipInGroup(sourceID: srcID, group: g.id, track: n, at: .timeline(g.start + g.duration + f(30))))
    try stack.perform(InsertClipInGroup(sourceID: srcID, group: g.id, track: n + 1, at: .inner(-f(600))))
    let after: Clip = try #require(p.tracks.flatMap(\.clips).first { (c: Clip) -> Bool in c.id == g.id })
    #expect(after.tracks.count == n + 2)
    for k in ["start", "duration", "mediaStart", "mediaDuration", "scalar"] {
        #expect(after.object[k] == g.object[k])
    }
    try p.serialized().write(to: url)
    #expect(try Project(contentsOf: url).serialized() == p.serialized())
    try stack.undo(); try stack.undo()
    #expect(p.serialized() == original)
    let restored: Clip = try #require(p.tracks.flatMap(\.clips).first { (c: Clip) -> Bool in c.id == g.id })
    #expect(JSON.object(restored.object).serialized() == groupBefore)
}
