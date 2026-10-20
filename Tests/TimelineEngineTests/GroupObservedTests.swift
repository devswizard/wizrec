import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

// Observed Camtasia group behaviour (docs/specs/group-edits.md), replayed on
// the spec's test material: two 1600×900 stills scaled to 50 %, one centred,
// one 300 px to the left, both 0–5 s. editRate 30 → 1 s = 30 ticks.

private let stillBin = """
[{"id" : 1, "src" : "./media/1/still.png", "rect" : [0, 0, 1600, 900], \
"sourceTracks" : [{"range" : [0, 1], "type" : 1, "editRate" : 30, "trackRect" : [0, 0, 1600, 900]}]}, \
{"id" : 2, "src" : "./media/2/clip.mp4", "rect" : [0, 0, 1600, 900], \
"sourceTracks" : [{"range" : [0, 300], "type" : 0, "editRate" : 30, "trackRect" : [0, 0, 1600, 900]}]}]
"""

private func long(_ v: String) -> String { #"{"type" : "double", "defaultValue" : \#(v), "interp" : "eioe"}"# }

private func still(_ id: Int64, start: Int64, dur: Int64, tss: Int64 = 0, params: String) -> String {
    """
    {"id" : \(id), "_type" : "IMFile", "src" : 1, "trackNumber" : 0, "trimStartSum" : \(tss), \
    "parameters" : \(params), "effects" : [], "start" : \(start), "duration" : \(dur), \
    "mediaStart" : 0, "mediaDuration" : 1, "scalar" : 1, "metadata" : {}, "animationTracks" : {}}
    """
}

private let half = #""scale0" : \#(long("0.5")), "scale1" : \#(long("0.5"))"#

@MainActor
private func x3Project() throws -> Project {
    let p = try projectWithAttributes([
        track(0, [still(10, start: 0, dur: 150, params: "{\(half)}")]),
        track(1, [still(11, start: 0, dur: 150, params: #"{"translation0" : \#(long("-300.0")), \#(half)}"#)]),
    ])
    p.root["sourceBin"] = try JSON.parse(stillBin)
    return p
}

@MainActor
private func expectLossless(_ p: Project, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let text = p.serialized()
    #expect(try Project(data: text).serialized() == text, sourceLocation: sourceLocation)
}

@MainActor @Test func groupCreateUsesBoundingBoxAndRecentres() throws {
    let p = try x3Project()
    let group = GroupClips(clipIDs: [10, 11])
    try expectReversible(group, on: p)
    try group.apply(to: p)
    let g = try #require(p.tracks[0].clips.first)
    #expect(g.object["parameters"] == (try JSON.parse(#"{"translation0" : -150.0, "geometryCrop0" : 0.0, "geometryCrop1" : 0.0, "geometryCrop2" : 0.0, "geometryCrop3" : 0.0, "volume" : 1.0}"#)))
    #expect(g.object["attributes"] == (try JSON.parse("""
        {"ident" : "Group 1", "widthAttr" : 1100.0, "heightAttr" : 450.0, "maxDurationAttr" : 0, \
        "gain" : 1.0, "mixToMono" : false, "assetProperties" : []}
        """)))
    #expect(g.object["mediaStart"]?.number?.lexeme == "0.0" && g.object["mediaDuration"]?.number?.lexeme == "150.0")
    // Members shift the opposite way; scale untouched.
    #expect(g.tracks[0].clips[0].parameters.object.entries.map(\.key) == ["translation0", "scale0", "scale1"])
    #expect(g.tracks[0].clips[0].parameters.object["translation0"]?.number?.lexeme == "150.0")  // bare, first
    #expect(g.tracks[0].clips[0].parameters.translation().x == 150)
    #expect(g.tracks[1].clips[0].object["parameters"] == (try JSON.parse(#"{"translation0" : \#(long("-150.0")), \#(half)}"#)))
    #expect(g.tracks[0].clips[0].parameters.scale().x == 0.5)
    #expect(p.tracks.count == 2 && p.tracks[1].clips.isEmpty)  // emptied track stays
    try expectLossless(p)
}

@MainActor @Test func groupCreateShiftsKeyframedPositionsAndUnifiedVideo() throws {
    let kf = #"{"type" : "double", "defaultValue" : 100.0, "keyframes" : [{"endTime" : 30, "time" : 0, "value" : 300.0, "interp" : "eioe", "duration" : 30}]}"#
    let p = try projectWithAttributes([
        track(0, [still(10, start: 0, dur: 150, params: #"{"translation1" : \#(kf), \#(half)}"#)]),
        track(1, [still(11, start: 0, dur: 150, params: #"{"translation1" : -100.0, "scale0" : 0.5, "scale1" : 0.5}"#)]),
    ])
    p.root["sourceBin"] = try JSON.parse(stillBin)
    let group = GroupClips(clipIDs: [10, 11])
    try expectReversible(group, on: p)
    try group.apply(to: p)
    let g = try #require(p.tracks[0].clips.first)
    // Boxes: y 100±225 and −100±225 → [−325, 325]: centre 0, height 650.
    #expect(g.attributes?["heightAttr"]?.double == 650 && g.attributes?["widthAttr"]?.double == 800)
    #expect(g.object["parameters"] == (try JSON.parse(#"{"geometryCrop0" : 0.0, "geometryCrop1" : 0.0, "geometryCrop2" : 0.0, "geometryCrop3" : 0.0, "volume" : 1.0}"#)))
    #expect(g.tracks[0].clips[0].object["parameters"] == (try JSON.parse(#"{"translation1" : \#(kf), \#(half)}"#)))
}

@MainActor @Test func groupTrimStartTrimsInnerClips() throws {
    // Group at 10–15 s holding the two stills (inner 0–5 s), trimmed at 11 s.
    let p = try x3Project()
    try GroupClips(clipIDs: [10, 11]).apply(to: p)
    try MoveClip(clipID: 12, toTrack: 0, start: 300).apply(to: p)
    let trim = TrimClip(clipID: 12, edge: .start, to: 330)
    try expectReversible(trim, on: p)
    try trim.apply(to: p)
    let g = try #require(p.tracks[0].clips.first)
    #expect([g.start, g.duration] == [330, 120])
    #expect(g.object["mediaStart"]?.number?.lexeme == "30.0" && g.object["mediaDuration"]?.number?.lexeme == "120.0")
    for t in g.tracks {
        let c = t.clips[0]
        #expect([c.start, c.duration] == [30, 120])
        #expect(c.object["trimStartSum"]?.int == 30 && c.object["mediaStart"]?.int == 0)
    }
    try expectLossless(p)
}

@MainActor @Test func groupTrimStartTrimsInnerVideoAndDropsClipsBeforeTheWindow() throws {
    let group = """
    {"id" : 30, "_type" : "Group", "parameters" : {"volume" : 1.0}, "tracks" : [\
    \(track(0, [leaf(31, start: 0, dur: 20, src: 2), leaf(32, start: 20, dur: 100, ms: "10", src: 2)], transitions: #"[{"name" : "Cube", "duration" : 4, "leftMedia" : 31, "rightMedia" : 32}]"#))], \
    "start" : 0, "duration" : 120, "mediaStart" : 0.0, "mediaDuration" : 120.0, "scalar" : 1}
    """
    let p = try projectWithAttributes([track(0, [group])])
    p.root["sourceBin"] = try JSON.parse(stillBin)
    let trim = TrimClip(clipID: 30, edge: .start, to: 40)
    try expectReversible(trim, on: p)
    try trim.apply(to: p)
    let g = try #require(p.tracks[0].clips.first)
    #expect(g.tracks[0].clips.map { [$0.id, $0.start, $0.duration] } == [[32, 40, 80]])
    #expect(g.tracks[0].clips[0].object["mediaStart"]?.int == 30)
    #expect(g.tracks[0].transitions.isEmpty)
    // The end edge leaves inner clips alone.
    let end = TrimClip(clipID: 30, edge: .end, to: 100)
    try end.apply(to: p)
    #expect(p.tracks[0].clips[0].tracks[0].clips.map(\.duration) == [80])
}

@MainActor @Test func groupSplitCopiesInnerContentWhole() throws {
    let p = try x3Project()
    try GroupClips(clipIDs: [10, 11]).apply(to: p)
    try MoveClip(clipID: 12, toTrack: 0, start: 300).apply(to: p)
    try TrimClip(clipID: 12, edge: .start, to: 330).apply(to: p)
    let split = SplitClip(clipID: 12, at: 390)
    try expectReversible(split, on: p)
    try split.apply(to: p)
    let (l, r) = (p.tracks[0].clips[0], p.tracks[0].clips[1])
    #expect([l.id, l.start, l.duration] == [12, 330, 60] && l.mediaStart == Rational(30))
    #expect([r.start, r.duration] == [390, 60] && r.mediaStart == Rational(90) && r.id > 12)
    #expect(r.attributes?["ident"]?.string == "Group 1" && r.object["parameters"] == l.object["parameters"])
    for (a, b) in zip(l.tracks, r.tracks) {
        #expect(a.clips.map { [$0.start, $0.duration] } == b.clips.map { [$0.start, $0.duration] })
        #expect(Set(a.clips.map(\.id)).isDisjoint(with: b.clips.map(\.id)))
    }
    try expectLossless(p)
}

@MainActor @Test func ungroupCutsToWindowAndComposesTransform() throws {
    // Spec §6: right half (13–15 s, inner window 3–5 s), group x 200, scale 0.5.
    let gParams = #"{"translation0" : \#(long("200.0")), "scale0" : \#(long("0.5")), "scale1" : \#(long("0.5")), "volume" : 1.0}"#
    let group = """
    {"id" : 30, "_type" : "Group", "parameters" : \(gParams), "tracks" : [\
    \(track(0, [still(31, start: 30, dur: 120, tss: 30, params: #"{"translation0" : \#(long("150.0")), \#(half)}"#)])), \
    \(track(1, [still(32, start: 30, dur: 120, tss: 30, params: #"{"translation0" : \#(long("-150.0")), \#(half)}"#)]))], \
    "attributes" : {"ident" : "Group 1", "widthAttr" : 1100.0, "heightAttr" : 450.0}, \
    "start" : 390, "duration" : 60, "mediaStart" : 90.0, "mediaDuration" : 60.0, "scalar" : 1}
    """
    let p = try projectWithAttributes([track(0, [group])])
    p.root["sourceBin"] = try JSON.parse(stillBin)
    let u = UngroupClip(clipID: 30)
    try expectReversible(u, on: p)
    try u.apply(to: p)
    let quarter = #""scale0" : \#(long("0.25")), "scale1" : \#(long("0.25"))"#
    try expectTracks(p, tracks(
        track(0, [still(31, start: 390, dur: 60, tss: 90, params: #"{"translation0" : \#(long("275.0")), \#(quarter)}"#)]),
        track(1, [still(32, start: 390, dur: 60, tss: 90, params: #"{"translation0" : \#(long("125.0")), \#(quarter)}"#)])))
    try expectLossless(p)
}

@MainActor @Test func groupThenUngroupRestoresPositions() throws {
    let p = try x3Project()
    let before = p.tracks.map { $0.clips.map { $0.parameters.translation().x } }
    try GroupClips(clipIDs: [10, 11]).apply(to: p)
    try UngroupClip(clipID: 12).apply(to: p)
    #expect(p.tracks.map { $0.clips.map { $0.parameters.translation().x } } == before)
    // A position that comes out as 0 is removed.
    #expect(p.tracks[0].clips[0].parameters.object.keys == ["scale0", "scale1"])
}

@MainActor @Test func ungroupRejectsRotationAndAnimatedGroupGeometry() throws {
    func group(_ params: String) -> String {
        """
        {"id" : 30, "_type" : "Group", "parameters" : \(params), "tracks" : [\(track(0, [leaf(31, start: 0, dur: 50)]))], \
        "start" : 0, "duration" : 50, "mediaStart" : 0.0, "mediaDuration" : 50.0, "scalar" : 1}
        """
    }
    for params in [#"{"rotation2" : 0.5}"#, #"{"opacity" : \#(long("0.5"))}"#,
                   #"{"translation0" : {"type" : "double", "defaultValue" : 0.0, "keyframes" : [{"endTime" : 10, "time" : 0, "value" : 5.0, "duration" : 10}]}}"#] {
        let p = try projectWithAttributes([track(0, [group(params)])])
        expectRejected(UngroupClip(clipID: 30), on: p, .invalid(""))
    }
    // Long-form constants equal to the identity are accepted (Camtasia's paste writes them).
    let ok = try projectWithAttributes([track(0, [group(#"{"translation0" : \#(long("0.0")), "scale0" : \#(long("1.0")), "volume" : \#(long("1.0"))}"#)])])
    try expectReversible(UngroupClip(clipID: 30), on: ok)
}
