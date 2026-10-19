import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

private func unified(_ id: Int64, start: Int64, dur: Int64, ms: String = "0", src: Int = 1,
                     metadata: String = #"{"default-scale" : "0.5", "effectApplied" : "none"}"#,
                     videoParams: String = "{}", effects: String = "[]") -> String {
    let v = leaf(id + 1, start: start, dur: dur, ms: ms, src: src, parameters: videoParams)
        .replacingOccurrences(of: #""metadata" : {"note" : "kept"}, "#, with: "")
    let a = leaf(id + 2, type: "AMFile", start: start, dur: dur, ms: ms, src: src, trackNumber: 1)
        .replacingOccurrences(of: #""metadata" : {"note" : "kept"}, "#, with: "")
        .replacingOccurrences(of: #""parameters" : {}"#, with: #""attributes" : {"ident" : "", "gain" : 1.0}, "parameters" : {}"#)
    return """
    {"id" : \(id), "_type" : "UnifiedMedia", "video" : \(v), "audio" : \(a), "effects" : \(effects), \
    "start" : \(start), "duration" : \(dur), "mediaStart" : \(ms), "mediaDuration" : \(dur), "scalar" : 1, "metadata" : \(metadata)}
    """
}

private let bin = #"[{"id" : 1, "src" : "./media/1/a.mp4", "sourceTracks" : []}, {"id" : 2, "src" : "./media/2/b.mp4", "sourceTracks" : []}]"#

// MARK: - Copy / paste

@MainActor @Test func copyPasteRemapsIdsAndKeepsLayout() throws {
    let p = try projectWithAttributes([
        track(0, [leaf(10, start: 100, dur: 50), leaf(11, start: 150, dur: 50)],
              transitions: #"[{"name" : "Cube", "duration" : 5, "leftMedia" : 10, "rightMedia" : 11}, {"name" : "Fade", "duration" : 5, "rightMedia" : 12}]"#),
        track(1, [leaf(12, start: 120, dur: 10)], transitions: #"[{"name" : "Fade", "duration" : 5, "rightMedia" : 12}]"#),
        track(2, []),
    ])
    p.root["sourceBin"] = try JSON.parse(bin)
    let payload = try ClipboardPayload.copy(clipIDs: [11, 10, 12], from: p)
    #expect(payload.clipCount == 3)
    #expect(try ClipboardPayload(data: payload.data) == payload)
    #expect(throws: EditError.self) { try ClipboardPayload(data: Data("{}".utf8)) }

    let paste = PasteClips(payload, track: 1, at: 400)
    try expectReversible(paste, on: p)
    try paste.apply(to: p)
    #expect(paste.pastedIDs == [13, 14, 15])  // above maxID 12, in payload order (track, start)
    #expect(p.tracks[1].clips.map { [$0.id, $0.start] } == [[12, 120], [13, 400], [14, 450]])
    #expect(p.tracks[2].clips.map { [$0.id, $0.start] } == [[15, 420]])
    // The Fade on track 0 points at a clip on another track, so it is not copied.
    #expect(p.tracks[1].transitions.map { [$0.leftMediaID, $0.rightMediaID] } == [[nil, 12], [13, 14]])
    #expect(p.tracks[2].transitions.map(\.rightMediaID) == [15])
    #expect(p.sourceBin.count == 2)  // same project: sources matched by src
    expectRejected(PasteClips(payload, track: 1, at: 410), on: p, .invalid(""))   // overlaps the pasted ones
    expectRejected(PasteClips(payload, track: 2, at: 0), on: p, .trackNotFound(3))
}

@MainActor @Test func pasteIntoAnotherProjectCopiesSources() throws {
    let a = try projectWithAttributes([track(0, [leaf(10, start: 0, dur: 50, src: 2)])])
    a.root["sourceBin"] = try JSON.parse(bin)
    let payload = try ClipboardPayload.copy(clipIDs: [10], from: a)
    let b = try projectWithAttributes([track(0, [leaf(5, start: 0, dur: 10)])])
    b.root["sourceBin"] = try JSON.parse(#"[{"id" : 1, "src" : "./media/9/other.mp4", "sourceTracks" : []}]"#)
    let paste = PasteClips(payload, track: 0, at: 20)
    try expectReversible(paste, on: b)
    try paste.apply(to: b)
    #expect(b.sourceBin.map(\.src) == ["./media/9/other.mp4", "./media/2/b.mp4"])
    let newSource = b.sourceBin[1].id
    #expect(newSource == 6 && b.tracks[0].clips[1].sourceID == newSource && b.tracks[0].clips[1].id == 7)
    let modern = ProjectTemplate.newProject(width: 1920, height: 1080, fps: 30)
    expectRejected(PasteClips(payload, track: 0, at: 0), on: modern, .invalid(""))  // editRate differs
}

// MARK: - Group / ungroup

@MainActor @Test func groupAndUngroupRoundTrip() throws {
    let p = try projectWithAttributes([
        track(0, [leaf(9, start: 0, dur: 50), leaf(10, start: 100, dur: 50)]),
        track(1, [leaf(11, start: 120, dur: 80), leaf(12, start: 300, dur: 10)]),
    ])
    let original = p.serialized()
    let group = GroupClips(clipIDs: [10, 11])
    try expectReversible(group, on: p)
    try group.apply(to: p)
    #expect(group.groupID == 13)
    let g = try #require(p.tracks[0].clips.last)
    #expect(g.kind == .group && g.start == 100 && g.duration == 100)
    #expect(g.tracks.map { $0.clips.map { [$0.id, $0.start] } } == [[[10, 0]], [[11, 20]]])
    #expect(g.attributes?["ident"]?.string == "Group 1" && g.attributes?["widthAttr"]?.double == 1920)
    #expect(g.object["mediaDuration"]?.number?.lexeme == "100.0")
    #expect(g.object.keys == ["id", "_type", "parameters", "tracks", "attributes", "effects", "start", "duration",
                              "mediaStart", "mediaDuration", "scalar", "metadata", "animationTracks"])
    #expect(g.tracks[0].object.keys == ["trackIndex", "medias", "parameters", "ident", "audioMuted", "videoHidden",
                                        "magnetic", "matte", "solo"])
    #expect(p.tracks[1].clips.map(\.id) == [12])

    let ungroup = UngroupClip(clipID: 13)
    try expectReversible(ungroup, on: p)
    try ungroup.apply(to: p)
    #expect(ungroup.releasedIDs == [10, 11])
    // Back where they were (the clips' JSON is unchanged).
    #expect(try JSON.parse(p.serialized()) == (try JSON.parse(original)))
    expectRejected(GroupClips(clipIDs: [9, 12]), on: p, .invalid(""))  // span 0…310 hits clip 10 on track 0
}

@MainActor @Test func ungroupCutsToWindowAndAddsTracks() throws {
    let group = """
    {"id" : 30, "_type" : "Group", "parameters" : {"volume" : 1.0}, "tracks" : [\(track(0, [leaf(31, start: 0, dur: 50)])), \
    \(track(1, [leaf(32, start: 30, dur: 50)]))], "start" : 200, "duration" : 40, "mediaStart" : 20.0, \
    "mediaDuration" : 40.0, "scalar" : 1}
    """
    let p = try projectWithAttributes([track(0, [group])])
    let u = UngroupClip(clipID: 30)
    try expectReversible(u, on: p)
    try u.apply(to: p)
    try expectTracks(p, tracks(track(0, [leaf(31, start: 200, dur: 30, ms: "20", md: "30")]),
                               track(1, [leaf(32, start: 210, dur: 30, md: "30")])))
    #expect(p.timeline?.trackAttributes.count == 2)
    let moved = try projectWithAttributes([track(0, [group.replacingOccurrences(of: #""volume" : 1.0"#, with: #""scale0" : 0.5"#)])])
    expectRejected(UngroupClip(clipID: 30), on: moved, .invalid(""))
}

// MARK: - Stitch / unstitch

@MainActor @Test func stitchAndUnstitch() throws {
    let scale = #"{"scale0" : {"type" : "double", "defaultValue" : 0.5, "interp" : "eioe"}, "geometryCrop0" : 0.0}"#
    let p = try projectWithAttributes([track(0, [
        unified(10, start: 0, dur: 100, ms: "0", videoParams: scale),
        unified(20, start: 100, dur: 50, ms: "300", videoParams: scale),
        unified(30, start: 300, dur: 10),
    ], transitions: #"[{"name" : "Fade", "duration" : 5, "rightMedia" : 10}, {"name" : "Cube", "duration" : 5, "leftMedia" : 10, "rightMedia" : 20}]"#)])
    let stitch = StitchClips(clipIDs: [20, 10])
    try expectReversible(stitch, on: p)
    try stitch.apply(to: p)
    #expect(stitch.stitchedID == 33)
    let s = try #require(p.tracks[0].clips.first)
    #expect(s.kind == .stitched && s.start == 0 && s.duration == 150 && s.mediaDuration == Rational(150))
    #expect(s.segments.map { [$0.id, $0.start, Int64($0.mediaStart.num)] } == [[10, 0, 0], [20, 100, 300]])
    #expect(s.parameters.object["scale0"] == .number(JSONNumber(lexeme: "0.5")))  // bare on the parent
    #expect(s.segments.allSatisfy { $0.video?.parameters["scale0"] == nil && $0.video?.parameters["geometryCrop0"] != nil })
    #expect(s.object.keys == ["id", "_type", "minMediaStart", "attributes", "parameters", "medias", "effects", "start",
                              "duration", "mediaStart", "mediaDuration", "scalar", "metadata", "animationTracks"])
    #expect(p.tracks[0].transitions.map { [$0.leftMediaID, $0.rightMediaID] } == [[nil, 33]])
    expectRejected(StitchClips(clipIDs: [33, 30]), on: p, .invalid(""))  // different types / gap

    let unstitch = UnstitchClip(clipID: 33)
    try expectReversible(unstitch, on: p)
    try unstitch.apply(to: p)
    #expect(unstitch.pieceIDs == [10, 20])
    let pieces = p.tracks[0].clips
    #expect(pieces.map { [$0.id, $0.start, $0.duration] } == [[10, 0, 100], [20, 100, 50], [30, 300, 10]])
    #expect(pieces[0].video?.parameters.object["scale0"] == .number(JSONNumber(lexeme: "0.5")))
    #expect(p.tracks[0].transitions.map(\.rightMediaID) == [10])
}

@MainActor @Test func stitchRejectsMixedSources() throws {
    let p = try projectWithAttributes([track(0, [unified(10, start: 0, dur: 10), unified(20, start: 10, dur: 10, src: 2)])])
    expectRejected(StitchClips(clipIDs: [10, 20]), on: p, .invalid(""))
    expectRejected(StitchClips(clipIDs: [10]), on: p, .invalid(""))
}

// MARK: - Real data

@MainActor @Test func m3CommandsOnTheDemoProjectRevertExactly() throws {
    let p = try demoProject()
    let payload = try ClipboardPayload.copy(clipIDs: [4], from: p)
    try expectReversible(PasteClips(payload, track: 1, at: 0), on: p)
    let ungroup = UngroupClip(clipID: 4)
    try expectReversible(ungroup, on: p)
    try ungroup.apply(to: p)
    #expect(ungroup.releasedIDs == [5, 6, 7])
    #expect(p.tracks.count == 3)
    try expectReversible(DetachAudio(clipID: 7), on: p)
    try expectReversible(GroupClips(clipIDs: [5, 6, 7]), on: p)
    try expectReversible(SetClipSpeed(clipID: 6, speed: Rational(2), ripple: true), on: p)
    try expectReversible(ExtendFrame(clipID: 6, duration: 23_520_000 * 30), on: p)
    try expectReversible(AddEffect(clipID: 6, name: "RoundCorners", parameters: [("radius", 20)]), on: p)
    try expectReversible(RippleTrim(clipID: 6, edge: .start, to: 23_520_000 * 10), on: p)
    try expectReversible(AddTransition(name: "Fade", leftClipID: 6, rightClipID: nil, duration: 23_520_000 * 15), on: p)
}

// MARK: - Detach audio

@MainActor @Test func detachAudioPutsAudioAbove() throws {
    let noise = #"[{"effectName" : "Noise", "category" : "categoryAudioEffects"}]"#
    let p = try projectWithAttributes([
        track(0, [unified(10, start: 0, dur: 100, effects: noise)], transitions: #"[{"name" : "Fade", "duration" : 5, "rightMedia" : 10}]"#),
        track(1, [leaf(20, start: 50, dur: 10)]),
    ])
    let d = DetachAudio(clipID: 10)
    try expectReversible(d, on: p)
    try d.apply(to: p)
    #expect(d.videoID == 11 && d.audioID == 12)
    #expect(p.tracks.count == 3)  // track 1 was busy at 50…60, so a track was inserted
    let v = try #require(p.tracks[0].clips.first), a = try #require(p.tracks[1].clips.first)
    #expect(v.kind == .video && v.metadata?["default-scale"]?.string == "0.5")
    #expect(a.kind == .audio && a.metadata?["default-scale"] == nil && a.effects.map(\.name) == ["Noise"])
    #expect(a.object.keys.last == "animationTracks" && a.object.keys.contains("metadata"))
    #expect(p.tracks[0].transitions.first?.rightMediaID == 11)
    #expect(p.tracks[2].clips.map(\.id) == [20])
    #expect(p.timeline?.trackAttributes.count == 3)

    let q = try projectWithAttributes([track(0, [unified(10, start: 0, dur: 100)]), track(1, [leaf(20, start: 200, dur: 10)])])
    let free = DetachAudio(clipID: 10)
    try free.apply(to: q)
    #expect(q.tracks.count == 2 && q.tracks[1].clips.map(\.id) == [12, 20])
    expectRejected(DetachAudio(clipID: 20), on: q, .invalid(""))
}
