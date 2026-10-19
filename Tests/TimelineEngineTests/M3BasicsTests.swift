import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

/// A project whose top-level tracks have `trackAttributes` (with `magnetic` per track).
@MainActor
func projectWithAttributes(_ trackJSON: [String], magnetic: Set<Int> = [], timelineExtra: String = "") throws -> Project {
    let attrs = trackJSON.indices.map { i in
        #"{"ident" : "", "audioMuted" : false, "videoHidden" : false, "magnetic" : \#(magnetic.contains(i)), "matte" : 0, "solo" : false}"#
    }
    let text = """
    {"editRate" : 30, "sourceBin" : [], "timeline" : {"id" : 1, \
    "sceneTrack" : {"scenes" : [{"csml" : {"tracks" : [\(trackJSON.joined(separator: ", "))]}}]}, \
    "trackAttributes" : [\(attrs.joined(separator: ", "))]\(timelineExtra), "captionAttributes" : {}}}
    """
    return try Project(data: Data(text.utf8))
}

// MARK: - Magnetic

@MainActor @Test func magneticTrackPacksAfterDeleteMoveAndFlag() throws {
    let p = try projectWithAttributes([
        track(0, [leaf(10, start: 0, dur: 100), leaf(11, start: 100, dur: 50), leaf(12, start: 150, dur: 20)]),
        track(1, [leaf(20, start: 300, dur: 10)]),
    ], magnetic: [0])
    let del = DeleteClips(clipIDs: [11])
    try expectReversible(del, on: p)
    try del.apply(to: p)
    try expectTracks(p, tracks(track(0, [leaf(10, start: 0, dur: 100), leaf(12, start: 100, dur: 20)]),
                               track(1, [leaf(20, start: 300, dur: 10)])))
    try del.revert(on: p)
    // Moving onto a magnetic track inserts at the nearest boundary instead of failing for overlap.
    let move = MoveClip(clipID: 20, toTrack: 0, start: 90)
    try expectReversible(move, on: p)
    try move.apply(to: p)
    try expectTracks(p, tracks(track(0, [leaf(10, start: 0, dur: 100), leaf(20, start: 100, dur: 10),
                                         leaf(11, start: 110, dur: 50), leaf(12, start: 160, dur: 20)]),
                               track(1, [])))
    try move.revert(on: p)
    // Turning magnetic on packs at once.
    let q = try projectWithAttributes([track(0, [leaf(10, start: 30, dur: 10), leaf(11, start: 70, dur: 10)])])
    let flag = SetTrackFlag(track: 0, .magnetic, true)
    try expectReversible(flag, on: q)
    try flag.apply(to: q)
    try expectTracks(q, tracks(track(0, [leaf(10, start: 0, dur: 10), leaf(11, start: 10, dur: 10)])))
}

// MARK: - Snapping

@MainActor @Test func snappingPicksNearestTargetElseFrame() throws {
    let p = try projectWithAttributes([
        track(0, [leaf(10, start: 0, dur: 100), leaf(11, start: 200, dur: 50)]),
        track(1, [leaf(20, start: 120, dur: 30)]),
    ], timelineExtra: #", "parameters" : {"toc" : {"type" : "string", "keyframes" : [{"endTime" : 400, "time" : 400, "value" : "m", "duration" : 0}]}}"#)
    let s = Snapping(project: p, playhead: 180, excluding: [20])
    #expect(s.snap(103, tolerance: 5) == SnapResult(tick: 100, guide: SnapGuide(tick: 100, kind: .clipEnd(10))))
    #expect(s.snap(178, tolerance: 5).guide?.kind == .playhead)
    #expect(s.snap(397, tolerance: 5).guide == SnapGuide(tick: 400, kind: .marker))
    #expect(s.snap(150, tolerance: 5) == SnapResult(tick: 150, guide: nil))  // 20 excluded
    #expect(s.snap(2, tolerance: 1).guide == nil)
    // A moving 30-tick clip: its end 197 is 3 from 200, its start 167 is 13 from 180.
    #expect(s.snap(start: 167, duration: 30, tolerance: 5) == SnapResult(tick: 170, guide: SnapGuide(tick: 200, kind: .clipStart(11))))
    let multi = try #require(s.snap(edges: [50, 98, 300], tolerance: 5))
    #expect(multi.delta == 2 && multi.guide.kind == .clipEnd(10))
    #expect(s.snap(edges: [50], tolerance: 5) == nil)
    // Tie at equal distance: playhead beats a clip edge.
    let t = Snapping(project: p, playhead: 200)
    #expect(t.snap(200, tolerance: 0).guide?.kind == .playhead)
    // Frame grid on a modern timebase.
    let q = ProjectTemplate.newProject(width: 1920, height: 1080, fps: 30)
    #expect(Snapping(project: q).snap(23_520_000 + 11_000_000, tolerance: 0).tick == 23_520_000)
}

// MARK: - Markers

@MainActor @Test func timelineMarkersFollowTheSpec() throws {
    let p = try projectWithAttributes([track(0, [leaf(10, start: 0, dur: 100)])])
    let a = AddMarker(at: 40, name: "Intro")
    try expectReversible(a, on: p)
    try a.apply(to: p)
    try AddMarker(at: 10, name: "First").apply(to: p)
    let timeline = try #require(p.timeline?.object)
    #expect(timeline.keys == ["id", "sceneTrack", "trackAttributes", "parameters", "captionAttributes"])
    let want = """
    {"toc" : {"type" : "string", "keyframes" : [
      {"endTime" : 10, "time" : 10, "value" : "First", "duration" : 0},
      {"endTime" : 40, "time" : 40, "value" : "Intro", "duration" : 0}]}}
    """
    #expect(timeline["parameters"] == (try JSON.parse(want)))
    #expect(Markers.timeline(p) == [Marker(time: 10, name: "First"), Marker(time: 40, name: "Intro")])

    try expectReversible(MoveMarker(from: 40, to: 5), on: p)
    try expectReversible(RenameMarker(at: 10, to: "One"), on: p)
    try expectReversible(RemoveMarker(at: 10), on: p)
    expectRejected(RemoveMarker(at: 11), on: p, .invalid(""))
    expectRejected(MoveMarker(from: 40, to: 10), on: p, .invalid(""))
    let rm1 = RemoveMarker(at: 10), rm2 = RemoveMarker(at: 40)
    try rm1.apply(to: p); try rm2.apply(to: p)
    #expect(p.timeline?.object["parameters"] == .object(JSONObject()))  // toc removed with its last marker
}

@MainActor @Test func clipMarkersUseTheClipsParameters() throws {
    let p = try projectWithAttributes([track(0, [leaf(10, start: 0, dur: 100, ms: "20")])])
    let a = AddMarker(at: 30, name: "cut", clipID: 10)
    try expectReversible(a, on: p)
    try a.apply(to: p)
    #expect(Markers.clip(p, id: 10) == [Marker(time: 30, name: "cut")])
    #expect(Markers.timeline(p).isEmpty)
}

// MARK: - Effects

@MainActor @Test func addRemoveMoveAndEditEffects() throws {
    let unified = """
    {"id" : 13, "_type" : "UnifiedMedia", "video" : \(leaf(14, start: 0, dur: 50, ms: "10")), \
    "audio" : \(leaf(15, type: "AMFile", start: 0, dur: 50)), "effects" : [], "start" : 0, "duration" : 50, \
    "mediaStart" : 0, "mediaDuration" : 50, "scalar" : 1, "metadata" : {"effectApplied" : "none"}}
    """
    let p = try projectWithAttributes([track(0, [unified])])
    let shadow = AddEffect(clipID: 13, name: "DropShadow", parameters: [("angle", 4.71238898038469), ("offset", 15)])
    try expectReversible(shadow, on: p)
    try shadow.apply(to: p)
    let noise = AddEffect(clipID: 13, effectJSON: #"{"effectName" : "VSTEffect-DFN3NoiseRemoval", "bypassed" : false, "category" : "categoryAudioEffects", "parameters" : {"Amount" : 0.8}}"#)
    try noise.apply(to: p)
    let corners = AddEffect(clipID: 13, name: "RoundCorners", parameters: [("radius", 20)], at: 0)
    try corners.apply(to: p)
    #expect(try Effects.list(p, clipID: 13).map(\.name) == ["RoundCorners", "DropShadow", "VSTEffect-DFN3NoiseRemoval"])
    let clip = try #require(p.tracks[0].clips.first)
    #expect(clip.video?.effects.map(\.name) == ["RoundCorners", "DropShadow"])
    #expect(clip.effects.map(\.name) == ["VSTEffect-DFN3NoiseRemoval"])
    #expect(clip.metadata?["effectApplied"]?.string == "RoundCorners")
    let shape = """
    {"effectName" : "DropShadow", "bypassed" : false, "category" : "categoryVisualEffects", "parameters" : {
      "angle" : {"type" : "double", "defaultValue" : 4.71238898038469, "interp" : "linr", "uiHints" : {"userInterfaceType" : 0, "unitType" : 0}},
      "offset" : {"type" : "double", "defaultValue" : 15.0, "interp" : "linr", "uiHints" : {"userInterfaceType" : 0, "unitType" : 0}}}}
    """
    #expect(clip.video?.object["effects"]?.array?[1] == (try JSON.parse(shape)))

    try expectReversible(MoveEffect(clipID: 13, from: 0, to: 1), on: p)
    expectRejected(MoveEffect(clipID: 13, from: 0, to: 2), on: p, .invalid(""))  // video vs parent
    try expectReversible(SetEffectBypassed(clipID: 13, effectIndex: 2, bypassed: true), on: p)
    let kf = SetEffectParameter(clipID: 13, effectIndex: 1, parameter: "offset", value: 30, keyframeAt: 40)
    try expectReversible(kf, on: p)
    try kf.apply(to: p)
    let video = try #require(p.tracks[0].clips.first?.video)
    let offset = try #require(video.effects[1].parameters?["offset"])
    #expect(offset.keyframes.map { [$0.time, $0.endTime] } == [[10, 40]])  // from the visible media start (10)
    #expect(video.visualAnimations.count == 1)
    let rm = RemoveEffect(clipID: 13, index: 0)
    try expectReversible(rm, on: p)
    try rm.apply(to: p)
    #expect(p.tracks[0].clips.first?.metadata?["effectApplied"]?.string == "VSTEffect-DFN3NoiseRemoval")
    expectRejected(RemoveEffect(clipID: 13, index: 5), on: p, .invalid(""))
    expectRejected(AddEffect(clipID: 13, effectJSON: "[]"), on: p, .invalid(""))
}

// MARK: - Transitions

@MainActor @Test func addReplaceAndRemoveTransitions() throws {
    let p = try projectWithAttributes([track(0, [leaf(10, start: 0, dur: 100), leaf(11, start: 100, dur: 100),
                                                 leaf(12, start: 300, dur: 50)])])
    let fade = AddTransition(name: "Fade", leftClipID: nil, rightClipID: 10, duration: 10)
    try expectReversible(fade, on: p)
    try fade.apply(to: p)
    let t = try #require(p.tracks[0].object)
    #expect(t.keys == ["trackIndex", "medias", "transitions", "parameters"])
    let want = #"[{"name" : "Fade", "duration" : 10, "trivial" : false, "reverse" : false, "bypass" : false, "useAudioPreRoll" : true, "useVisualPreRoll" : true, "rightMedia" : 10}]"#
    #expect(t["transitions"] == (try JSON.parse(want)))

    let cube = AddTransition(name: "CubeRotate", leftClipID: 10, rightClipID: 11, duration: 20)
    try expectReversible(cube, on: p)
    try cube.apply(to: p)
    let fadeIn11 = AddTransition(name: "Fade", leftClipID: nil, rightClipID: 11, duration: 5)
    try fadeIn11.apply(to: p)  // replaces the cube on 11's start edge
    #expect(p.tracks[0].transitions.map(\.name) == ["Fade", "Fade"])
    try expectReversible(SetTransitionDuration(leftClipID: nil, rightClipID: 11, duration: 8), on: p)
    try expectReversible(RemoveTransition(leftClipID: nil, rightClipID: 10), on: p)
    expectRejected(AddTransition(name: "Cube", leftClipID: 11, rightClipID: 12, duration: 5), on: p, .invalid(""))  // gap
    expectRejected(AddTransition(name: "Fade", leftClipID: 12, rightClipID: nil, duration: 60), on: p, .invalid(""))
    expectRejected(RemoveTransition(leftClipID: 12, rightClipID: nil), on: p, .invalid(""))
}
