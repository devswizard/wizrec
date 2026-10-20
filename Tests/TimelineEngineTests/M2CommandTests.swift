import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

// Projects here use editRate 30 (one tick per frame) on a 1920×1080 canvas.

private let added = Date(timeIntervalSince1970: 1_792_376_869.292854)
private let modified = Date(timeIntervalSince1970: 1_790_000_000)

private func movie(_ src: String = "./media/1792376869.292854/clip.mp4") -> SourceDescriptor {
    SourceDescriptor(src: src, lastModified: modified, tracks: [
        .init(type: 0, editRate: 600, rangeEnd: 6000, width: 2688, height: 1512,
              sampleRate: Rational(30000, 1001), bitDepth: 24, channelCount: 0),
        .init(type: 2, editRate: 48000, rangeEnd: 479_000, width: 0, height: 0,
              sampleRate: Rational(48000), bitDepth: 16, channelCount: 2),
    ])
}

private let movieSource = """
{"id" : 2, "src" : "./media/1792376869.292854/clip.mp4", "rect" : [0, 0, 2688, 1512],
 "lastMod" : "20260921T141320", "loudnessNormalization" : true, "sourceTracks" : [
  {"range" : [0, 6000], "type" : 0, "editRate" : 600, "trackRect" : [0, 0, 2688, 1512],
   "sampleRate" : "30000/1001", "bitDepth" : 24, "numChannels" : 0, "integratedLUFS" : 100.0,
   "peakLevel" : -1.0, "tag" : 0, "metaData" : "clip.mp4;", "parameters" : {}},
  {"range" : [0, 479000], "type" : 2, "editRate" : 48000, "trackRect" : [0, 0, 0, 0],
   "sampleRate" : 48000, "bitDepth" : 16, "numChannels" : 2, "integratedLUFS" : 100.0,
   "peakLevel" : -1.0, "tag" : 0, "metaData" : "clip.mp4;", "parameters" : {}}],
 "metadata" : {"timeAdded" : "20261019T022749.292854"}}
"""

private func source(id: Int, src: String, rect: (Int, Int), tracks: [(type: Int, rate: Int, end: Int, w: Int, h: Int, ch: Int)]) -> String {
    let ts = tracks.map { t in
        """
        {"range" : [0, \(t.end)], "type" : \(t.type), "editRate" : \(t.rate), "trackRect" : [0, 0, \(t.w), \(t.h)], \
        "numChannels" : \(t.ch)}
        """
    }
    return #"{"id" : \#(id), "src" : "\#(src)", "rect" : [0, 0, \#(rect.0), \#(rect.1)], "sourceTracks" : [\#(ts.joined(separator: ", "))]}"#
}

private let geometryCrops = """
"geometryCrop0" : {"type" : "double", "defaultValue" : 0.0, "interp" : "eioe"},
"geometryCrop1" : {"type" : "double", "defaultValue" : 0.0, "interp" : "eioe"},
"geometryCrop2" : {"type" : "double", "defaultValue" : 0.0, "interp" : "eioe"},
"geometryCrop3" : {"type" : "double", "defaultValue" : 0.0, "interp" : "eioe"}
"""

private func clipMetadata(_ scale: String?, visual: Bool = true) -> String {
    let s = scale.map { #""default-scale" : "\#($0)", "# } ?? ""
    let lock = visual ? #", "lockAspectRatio" : {"type" : "bool", "value" : true}"# : ""
    return """
    {"audiateLinkedSession" : "", "clipSpeedAttribute" : {"type" : "bool", "value" : false}, \
    "colorAttribute" : {"type" : "color", "value" : [0, 0, 0, 0]}, \(s)"effectApplied" : "none"\(lock)}
    """
}

// MARK: - AddSource / RelinkSource

@MainActor @Test func addSourceWritesCamtasiaEntry() throws {
    let p = try makeProject(tracks: tracks(track(0, [])))
    let add = AddSource(movie())
    add.addedAt = added
    try expectReversible(add, on: p)
    try add.apply(to: p)
    #expect(add.sourceID == 2)  // above maxID (timeline id 1)
    #expect(p.root["sourceBin"] == (try JSON.parse("[\(movieSource)]")))
    expectRejected(AddSource(SourceDescriptor(src: "", lastModified: modified, tracks: [])), on: p, .invalid(""))
}

@MainActor @Test func addSourceCreatesMissingSourceBin() throws {
    let p = try Project(data: Data(#"{"editRate" : 30, "timeline" : {"id" : 1}}"#.utf8))
    let add = AddSource(movie())
    try expectReversible(add, on: p)
}

@MainActor @Test func relinkRewritesPathAndStreamsOnly() throws {
    let old = """
    {"id" : 2, "src" : "/Volumes/Other/clip.mp4", "rect" : [0, 0, 10, 10], "lastMod" : "20200101T000000", \
    "loudnessNormalization" : true, "sourceTracks" : [], "effectDef" : [], "metadata" : {"timeAdded" : "kept"}}
    """
    let p = try makeProject(tracks: tracks(track(0, [])), sourceBin: "[\(old)]")
    let relink = RelinkSource(sourceID: 2, to: movie())
    try expectReversible(relink, on: p)
    try relink.apply(to: p)
    let want = try JSON.parse(movieSource)
    want.object?["effectDef"] = .array(JSONArray())
    want.object?["metadata"] = try JSON.parse(#"{"timeAdded" : "kept"}"#)
    // Same key order as the old entry: effectDef stays before metadata.
    let w = try #require(want.object)
    let reordered = JSONObject(["id", "src", "rect", "lastMod", "loudnessNormalization", "sourceTracks", "effectDef", "metadata"]
        .map { ($0, w[$0] ?? .null) })
    #expect(p.root["sourceBin"]?.array?[0] == .object(reordered))
    expectRejected(RelinkSource(sourceID: 9, to: movie()), on: p, .invalid(""))
}

// MARK: - InsertClip

@MainActor @Test func insertVideoWithAudioMakesUnifiedMedia() throws {
    let p = try makeProject(tracks: tracks(track(0, [leaf(10, start: 0, dur: 50)])), sourceBin: "[\(movieSource)]")
    let insert = InsertClip(sourceID: 2, track: 0, start: 100)
    try expectReversible(insert, on: p)
    try insert.apply(to: p)
    #expect(insert.clipID == 11)
    // Video 10 s = 300 frames; audio 479000/48000 s = 299.375 frames → the shorter, floored: 299.
    let timing = #""start" : 100, "duration" : 299, "mediaStart" : 0, "mediaDuration" : 299, "scalar" : 1"#
    let unified = """
    {"id" : 11, "_type" : "UnifiedMedia",
     "video" : {"id" : 12, "_type" : "VMFile", "src" : 2, "trackNumber" : 0, "attributes" : {"ident" : "clip"},
       "parameters" : {"scale0" : {"type" : "double", "defaultValue" : 0.714285714285714, "interp" : "eioe"},
                       "scale1" : {"type" : "double", "defaultValue" : 0.714285714285714, "interp" : "eioe"},
                       \(geometryCrops)},
       "effects" : [], \(timing), "animationTracks" : {}},
     "audio" : {"id" : 13, "_type" : "AMFile", "src" : 2, "trackNumber" : 1,
       "attributes" : {"ident" : "", "gain" : 1.0, "mixToMono" : false, "loudnessNormalization" : true, "sourceFileOffset" : 0},
       "channelNumber" : "0,1", "parameters" : {}, "effects" : [], \(timing), "animationTracks" : {}},
     "effects" : [], \(timing), "metadata" : \(clipMetadata("0.714286"))}
    """
    try expectTracks(p, tracks(track(0, [leaf(10, start: 0, dur: 50), unified])))
}

@MainActor @Test func insertPicksClipTypeFromStreams() throws {
    let bin = "[" + [
        source(id: 2, src: "./media/1/v.mov", rect: (1280, 720), tracks: [(0, 30, 90, 1280, 720, 0)]),
        source(id: 3, src: "./media/2/a.m4a", rect: (0, 0), tracks: [(2, 44100, 88200, 0, 0, 1)]),
        source(id: 4, src: "./media/3/p.png", rect: (3840, 2160), tracks: [(1, 600, 1, 3840, 2160, 0)]),
        source(id: 5, src: "./recordings/4/r.trec", rect: (3024, 1964),
               tracks: [(0, 1000, 2000, 3024, 1964, 0), (0, 1000, 2000, 1920, 1080, 0), (2, 48000, 96000, 0, 0, 2)]),
    ].joined(separator: ", ") + "]"
    let p = try makeProject(tracks: tracks(track(0, []), track(1, []), track(2, []), track(3, [])), sourceBin: bin)
    for (src, t) in [(2, 0), (3, 1), (4, 2), (5, 3)] {
        let c = InsertClip(sourceID: Int64(src), track: t, start: 0)
        try expectReversible(c, on: p)
        try c.apply(to: p)
    }
    let ts = p.tracks
    let video = try #require(ts[0].clips.first)
    #expect(video.kind == .video && video.duration == 90 && video.parameters["scale0"] == nil)
    #expect(video.metadata?["default-scale"]?.string == "1")
    #expect(video.object["parameters"] == (try JSON.parse("{\(geometryCrops)}")))

    let audio = try #require(ts[1].clips.first)
    #expect(audio.kind == .audio && audio.duration == 60)
    #expect(audio.object["channelNumber"]?.string == "0")
    #expect(audio.name == "a" && audio.metadata?["default-scale"] == nil)

    let image = try #require(ts[2].clips.first)
    #expect(image.kind == .image && image.duration == 150)  // 5 s
    #expect(image.object["trimStartSum"]?.int == 0)
    #expect(image.mediaDuration == Rational(1))
    #expect(image.parameters["scale0"]?.defaultValue?.double == 0.5)
    #expect(image.parameters.names == ["scale0", "scale1", "sourceCrop0", "sourceCrop1", "sourceCrop2", "sourceCrop3",
                                       "geometryCrop0", "geometryCrop1", "geometryCrop2", "geometryCrop3"])
    #expect(JSON.object(try #require(image.metadata)) == (try JSON.parse(clipMetadata("0.5"))))

    let rec = try #require(ts[3].clips.first)
    #expect(rec.kind == .unified && rec.video?.kind == .screenVideo && rec.audio?.sourceTrackNumber == 2)
    #expect(rec.video?.sourceTrackNumber == 0 && rec.duration == 60)
}

@MainActor @Test func insertRejectsOverlapAndBadInput() throws {
    let p = try makeProject(tracks: tracks(track(0, [leaf(10, start: 100, dur: 50)])), sourceBin: "[\(movieSource)]")
    expectRejected(InsertClip(sourceID: 2, track: 0, start: 0), on: p, .invalid(""))      // 0…299 overlaps 100…150
    expectRejected(InsertClip(sourceID: 2, track: 0, start: 149), on: p, .invalid(""))
    expectRejected(InsertClip(sourceID: 9, track: 0, start: 500), on: p, .invalid(""))
    expectRejected(InsertClip(sourceID: 2, track: 3, start: 500), on: p, .trackNotFound(3))
    expectRejected(InsertClip(sourceID: 2, track: 0, start: -5), on: p, .invalid(""))
    try expectReversible(InsertClip(sourceID: 2, track: 0, start: 150), on: p)  // touching is fine
}

@MainActor @Test func insertSnapsToFramesOnModernTimebase() throws {
    let p = ProjectTemplate.newProject(width: 1920, height: 1080, fps: 30)
    let add = AddSource(movie())
    try add.apply(to: p)
    let insert = InsertClip(sourceID: try #require(add.sourceID), track: 0, start: 23_520_000 + 5)
    try insert.apply(to: p)
    let clip = try #require(p.tracks[0].clips.first)
    #expect(clip.start == 23_520_000)
    #expect(clip.duration == 299 * 23_520_000)
    #expect(clip.video?.duration == clip.duration && clip.audio?.mediaDuration == Rational(clip.duration))
}

// MARK: - DeleteClips

@MainActor @Test func deleteRemovesClipsAndTheirTransitions() throws {
    let transitions = """
    [{"name" : "Fade", "duration" : 10, "rightMedia" : 10},
     {"name" : "Cube", "duration" : 10, "leftMedia" : 10, "rightMedia" : 11},
     {"name" : "Fade", "duration" : 10, "leftMedia" : 11}]
    """
    let p = try makeProject(tracks: tracks(
        track(0, [leaf(10, start: 0, dur: 100), leaf(11, start: 100, dur: 100), leaf(12, start: 300, dur: 50)],
              transitions: transitions)))
    let del = DeleteClips(clipIDs: [10])
    try expectReversible(del, on: p)
    try del.apply(to: p)
    try expectTracks(p, tracks(track(0, [leaf(11, start: 100, dur: 100), leaf(12, start: 300, dur: 50)],
                                     transitions: #"[{"name" : "Fade", "duration" : 10, "leftMedia" : 11}]"#)))
    expectRejected(DeleteClips(clipIDs: [99]), on: p, .clipNotFound(99))
    expectRejected(DeleteClips(clipIDs: []), on: p, .invalid(""))
}

@MainActor @Test func rippleDeleteClosesGapsOnThatTrackOnly() throws {
    let unified = """
    {"id" : 13, "_type" : "UnifiedMedia", "video" : \(leaf(14, start: 400, dur: 50)), \
    "audio" : \(leaf(15, type: "AMFile", start: 400, dur: 50)), "start" : 400, "duration" : 50, \
    "mediaStart" : 0, "mediaDuration" : 50, "scalar" : 1}
    """
    let p = try makeProject(tracks: tracks(
        track(0, [leaf(10, start: 0, dur: 100), leaf(11, start: 150, dur: 100), leaf(12, start: 300, dur: 50), unified]),
        track(1, [leaf(20, start: 500, dur: 10)])))
    let del = DeleteClips(clipIDs: [10, 12], ripple: true)
    #expect(del.name == "Ripple Delete")
    try expectReversible(del, on: p)
    try del.apply(to: p)
    let movedUnified = """
    {"id" : 13, "_type" : "UnifiedMedia", "video" : \(leaf(14, start: 250, dur: 50)), \
    "audio" : \(leaf(15, type: "AMFile", start: 250, dur: 50)), "start" : 250, "duration" : 50, \
    "mediaStart" : 0, "mediaDuration" : 50, "scalar" : 1}
    """
    try expectTracks(p, tracks(
        track(0, [leaf(11, start: 50, dur: 100), movedUnified]),
        track(1, [leaf(20, start: 500, dur: 10)])))
}

@MainActor @Test func deleteInsideGroupAndGroupWithChild() throws {
    func group(_ inner: [String]) -> String {
        """
        {"id" : 30, "_type" : "Group", "start" : 500, "duration" : 100, "mediaStart" : 0.0, "mediaDuration" : 100.0, \
        "scalar" : 1, "tracks" : [\(track(0, inner))]}
        """
    }
    let p = try makeProject(tracks: tracks(track(0, [leaf(10, start: 0, dur: 100),
                                                     group([leaf(31, start: 0, dur: 50), leaf(32, start: 50, dur: 50)])])))
    // A clip inside a group plus a clip on the group's own track, rippled.
    let both = DeleteClips(clipIDs: [31, 10], ripple: true)
    try expectReversible(both, on: p)
    try both.apply(to: p)
    try expectTracks(p, tracks(track(0, [group([leaf(32, start: 0, dur: 50)]).replacingOccurrences(
        of: #""start" : 500"#, with: #""start" : 400"#)])))
    try both.revert(on: p)
    // Deleting a group together with one of its children deletes the group.
    let g = DeleteClips(clipIDs: [32, 30])
    try expectReversible(g, on: p)
    try g.apply(to: p)
    try expectTracks(p, tracks(track(0, [leaf(10, start: 0, dur: 100)])))
}

// MARK: - Tracks

private let attr = #"{"ident" : "", "audioMuted" : false, "videoHidden" : false, "magnetic" : false, "matte" : 0, "solo" : false, "metadata" : {"IsLocked" : "False", "trackHeight" : "56"}}"#

@MainActor
private func trackProject(_ n: Int) throws -> Project {
    let ts = (0..<n).map { track($0, [leaf(Int64(10 + $0), start: 0, dur: 10)]) }
    let text = """
    {"editRate" : 30, "timeline" : {"id" : 1, "sceneTrack" : {"scenes" : [{"csml" : {"tracks" : [\(ts.joined(separator: ", "))]}}]},
     "trackAttributes" : [\((0..<n).map { _ in attr.replacingOccurrences(of: #""ident" : """#, with: #""ident" : "x""#) }.joined(separator: ", "))]}}
    """
    return try Project(data: Data(text.utf8))
}

@MainActor @Test func addTrackRenumbersAndInsertsAttributes() throws {
    let p = try trackProject(2)
    let add = AddTrack(at: 1)
    try expectReversible(add, on: p)
    try add.apply(to: p)
    try expectTracks(p, tracks(track(0, [leaf(10, start: 0, dur: 10)]), track(1, []),
                               track(2, [leaf(11, start: 0, dur: 10)])))
    let attrs = try #require(p.timeline?.trackAttributes)
    #expect(attrs.map { $0["ident"]?.string } == ["x", "", "x"])
    #expect(JSON.object(attrs[1]) == (try JSON.parse(attr)))
    try add.revert(on: p)
    try expectReversible(AddTrack(at: 2), on: p)
    expectRejected(AddTrack(at: 3), on: p, .trackNotFound(3))
}

@MainActor @Test func removeTrackRenumbersAndKeepsOne() throws {
    let p = try trackProject(3)
    let rm = RemoveTrack(at: 0)
    try expectReversible(rm, on: p)
    try rm.apply(to: p)
    try expectTracks(p, tracks(track(0, [leaf(11, start: 0, dur: 10)]), track(1, [leaf(12, start: 0, dur: 10)])))
    #expect(p.timeline?.trackAttributes.count == 2)
    expectRejected(RemoveTrack(at: 2), on: p, .trackNotFound(2))
    let one = try trackProject(1)
    expectRejected(RemoveTrack(at: 0), on: one, .invalid(""))
}

@MainActor @Test func setTrackFlags() throws {
    let p = try trackProject(2)
    for flag in TrackFlag.allCases {
        let c = SetTrackFlag(track: 1, flag, true)
        try expectReversible(c, on: p)
        try c.apply(to: p)
    }
    let a = try #require(p.timeline?.trackAttributes[1])
    #expect(a["audioMuted"]?.bool == true && a["videoHidden"]?.bool == true && a["magnetic"]?.bool == true)
    #expect(a["solo"]?.bool == true && a["metadata"]?.object?["IsLocked"]?.string == "True")
    #expect(a.keys == (try JSON.parse(attr)).object?.keys)
    #expect(p.timeline?.trackAttributes[0]["solo"]?.bool == false)
    expectRejected(SetTrackFlag(track: 2, .solo, true), on: p, .trackNotFound(2))
}

// MARK: - SetParameter

@MainActor @Test func setConstantKeepsShapeAndPosition() throws {
    let params = #"{"translation0" : 5.0, "scale0" : {"type" : "double", "defaultValue" : 0.5, "interp" : "eioe", "keyframes" : [{"endTime" : 10, "time" : 0, "value" : 1.0, "interp" : "eioe", "duration" : 10}]}}"#
    let anim = #"{"visual" : [{"endTime" : 10, "duration" : 10, "range" : [0, 10], "interp" : "eioe"}]}"#
    let p = try makeProject(tracks: tracks(track(0, [leaf(10, start: 0, dur: 100, parameters: params, anim: anim)])))
    let a = SetParameter(clipID: 10, parameter: "scale0", value: 0.25)
    try expectReversible(a, on: p)
    try a.apply(to: p)
    let b = SetParameter(clipID: 10, parameter: "translation0", value: -3)
    try b.apply(to: p)
    let c = SetParameter(clipID: 10, parameter: "opacity", value: 0.5)
    try c.apply(to: p)
    let want = #"{"translation0" : -3.0, "scale0" : {"type" : "double", "defaultValue" : 0.25, "interp" : "eioe"}, "opacity" : {"type" : "double", "defaultValue" : 0.5, "interp" : "eioe"}}"#
    // The keyframe window is gone, so its animationTracks entry is too.
    try expectTracks(p, tracks(track(0, [leaf(10, start: 0, dur: 100, parameters: want, anim: "{}")])))
    expectRejected(SetParameter(clipID: 10, parameter: "opacity", value: .nan), on: p, .invalid(""))
    expectRejected(SetParameter(clipID: 99, parameter: "opacity", value: 1), on: p, .clipNotFound(99))
}

@MainActor @Test func missingParameterFollowsTheClipsStyle() throws {
    let p = try makeProject(tracks: tracks(track(0, [
        leaf(10, type: "StitchedMedia", start: 0, dur: 100, parameters: #"{"scale0" : 0.7}"#),
    ])))
    let c = SetParameter(clipID: 10, parameter: "translation1", value: 12)
    try c.apply(to: p)
    #expect(p.tracks[0].clips[0].parameters.object["translation1"] == .number(JSONNumber(lexeme: "12.0")))
}

@MainActor @Test func keyframesOnMediaTimeAxisWithAnimationTracks() throws {
    // Left-trimmed clip: media time 40 is shown at its start.
    let p = try makeProject(tracks: tracks(track(0, [leaf(10, start: 0, dur: 100, ms: "40", md: "100")])))
    let k1 = SetParameter(clipID: 10, parameter: "opacity", value: 0, keyframeAt: 60)
    try expectReversible(k1, on: p)
    try k1.apply(to: p)
    let k2 = SetParameter(clipID: 10, parameter: "opacity", value: 1, keyframeAt: 90)
    try expectReversible(k2, on: p)
    try k2.apply(to: p)
    let k3 = SetParameter(clipID: 10, parameter: "opacity", value: 0.5, keyframeAt: 70)  // splits 60→90
    try k3.apply(to: p)
    let k4 = SetParameter(clipID: 10, parameter: "opacity", value: 0.25, keyframeAt: 90)  // updates
    try k4.apply(to: p)
    func kf(_ t: Int, _ e: Int, _ v: String) -> String {
        #"{"endTime" : \#(e), "time" : \#(t), "value" : \#(v), "interp" : "eioe", "duration" : \#(e - t)}"#
    }
    func win(_ t: Int, _ e: Int) -> String {
        #"{"endTime" : \#(e), "duration" : \#(e - t), "range" : [\#(t), \#(e - t)], "interp" : "eioe"}"#
    }
    let params = """
    {"opacity" : {"type" : "double", "defaultValue" : 1.0, "interp" : "eioe", "keyframes" : [\(kf(40, 60, "0.0")), \
    \(kf(60, 70, "0.5")), \(kf(70, 90, "0.25"))]}}
    """
    let anim = #"{"visual" : [\#(win(40, 60)), \#(win(60, 70)), \#(win(70, 90))]}"#
    try expectTracks(p, tracks(track(0, [leaf(10, start: 0, dur: 100, ms: "40", md: "100", parameters: params, anim: anim)])))
}

@MainActor @Test func unifiedParametersGoToTheirPart() throws {
    let unified = """
    {"id" : 13, "_type" : "UnifiedMedia", "video" : \(leaf(14, start: 0, dur: 50)), \
    "audio" : \(leaf(15, type: "AMFile", start: 0, dur: 50)), "start" : 0, "duration" : 50, \
    "mediaStart" : 0, "mediaDuration" : 50, "scalar" : 1}
    """
    let p = try makeProject(tracks: tracks(track(0, [unified])))
    let s = SetParameter(clipID: 13, parameter: "scale0", value: 2)
    let v = SetParameter(clipID: 13, parameter: "volume", value: 0.5)
    try expectReversible(s, on: p)
    try s.apply(to: p)
    try v.apply(to: p)
    let clip = try #require(p.tracks[0].clips.first)
    #expect(clip.video?.parameters["scale0"]?.defaultValue?.double == 2)
    #expect(clip.audio?.parameters["volume"]?.defaultValue?.double == 0.5)
    #expect(clip.object["parameters"] == nil)
    expectRejected(SetParameter(clipID: 14, parameter: "scale0", value: 1), on: p, .invalid(""))
}

@MainActor @Test func imageKeyframesUseTrimStartSum() throws {
    let image = """
    {"id" : 10, "_type" : "IMFile", "src" : 1, "trackNumber" : 0, "trimStartSum" : 20, "start" : 0, "duration" : 100, \
    "mediaStart" : 0, "mediaDuration" : 1, "scalar" : 1, "parameters" : {}, "animationTracks" : {}}
    """
    let p = try makeProject(tracks: tracks(track(0, [image])))
    let k = SetParameter(clipID: 10, parameter: "opacity", value: 0, keyframeAt: 50)
    try k.apply(to: p)
    let kf = try #require(p.tracks[0].clips[0].parameters["opacity"]?.keyframes.first)
    #expect(kf.time == 20 && kf.endTime == 50)
}

// MARK: - Real data

@MainActor @Test func m2CommandsOnTheDemoProjectRevertExactly() throws {
    let p = try demoProject()
    let add = AddSource(movie())
    try expectReversible(add, on: p)
    try add.apply(to: p)
    let id = try #require(add.sourceID)
    #expect(id == 10)  // demo maxID is 9
    try expectReversible(AddTrack(at: 2), on: p)
    try AddTrack(at: 2).apply(to: p)
    try expectReversible(InsertClip(sourceID: id, track: 2, start: 0), on: p)
    try expectReversible(SetParameter(clipID: 7, parameter: "translation0", value: 10, keyframeAt: 23_520_000 * 10), on: p)
    try expectReversible(SetParameter(clipID: 6, parameter: "scale0", value: 0.5), on: p)
    try expectReversible(DeleteClips(clipIDs: [8 - 1], ripple: true), on: p)
    try expectReversible(SetTrackFlag(track: 0, .locked, true), on: p)
    try expectReversible(RemoveTrack(at: 1), on: p)
    try expectReversible(RelinkSource(sourceID: 2, to: movie("./media/x/y.trec")), on: p)
}
