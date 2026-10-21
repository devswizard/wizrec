import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

// TL15-2 AddAnimation: menu animations, animation.md §1–§2. Projects use
// editRate 30 (one tick per frame, 1 s = 30 ticks) on the default 1920×1080
// canvas.

/// Source 1: a 1920×1080 video. Source 2: a 400×400 still.
private let bin = """
[{"id" : 1, "src" : "./media/1/v.mp4", "rect" : [0, 0, 1920, 1080], "sourceTracks" : [\
{"range" : [0, 900], "type" : 0, "editRate" : 30, "trackRect" : [0, 0, 1920, 1080], "numChannels" : 0}]}, \
{"id" : 2, "src" : "./media/2/s.png", "rect" : [0, 0, 400, 400], "sourceTracks" : [\
{"range" : [0, 1], "type" : 1, "editRate" : 30, "trackRect" : [0, 0, 400, 400], "numChannels" : 0}]}]
"""

private func still(_ id: Int64, start: Int64, dur: Int64, trimStartSum: Int64 = 0, parameters: String = "{}",
                   anim: String = "{}") -> String {
    """
    {"id" : \(id), "_type" : "IMFile", "src" : 2, "trackNumber" : 0, "trimStartSum" : \(trimStartSum), \
    "start" : \(start), "duration" : \(dur), "mediaStart" : 0, "mediaDuration" : 1, "scalar" : 1, \
    "parameters" : \(parameters), "effects" : [], "animationTracks" : \(anim)}
    """
}

/// `{endTime, time, value, duration}` (no interp) for a 1 s segment ending at `e`.
private func kf(_ e: Int, _ value: String) -> String {
    #"{"endTime" : \#(e), "time" : \#(e - 30), "value" : \#(value), "duration" : 30}"#
}

private func param(_ base: String, _ e: Int, _ value: String) -> String {
    #"{"type" : "double", "defaultValue" : \#(base), "keyframes" : [\#(kf(e, value))]}"#
}

private func visual(_ ends: Int...) -> String {
    #"{"visual" : [\#(ends.map { #"{"endTime" : \#($0), "duration" : 30}"# }.joined(separator: ", "))]}"#
}

@MainActor private func project(_ medias: [String], extraTracks: [String] = []) throws -> Project {
    try makeProject(tracks: "[" + ([track(0, medias)] + extraTracks).joined(separator: ", ") + "]", sourceBin: bin)
}

@MainActor private func run(_ c: AddAnimation, on p: Project) throws {
    try expectReversible(c, on: p)
    try c.apply(to: p)
}

@MainActor @Test func noOpacityEndsAtThePlayheadAndMayStartBeforeTheClip() throws {
    let p = try project([leaf(10, start: 0, dur: 300)])
    // Playhead 0.5 s into the clip: the segment runs −0.5 s … +0.5 s [obs].
    try run(AddAnimation(clipID: 10, preset: .noOpacity, at: 15), on: p)
    try expectTracks(p, tracks(track(0, [leaf(10, start: 0, dur: 300,
        parameters: #"{"opacity" : \#(param("1.0", 15, "0.0"))}"#, anim: visual(15))])))
}

@MainActor @Test func fullOpacityStartsFromZero() throws {
    let p = try project([leaf(10, start: 60, dur: 300, ms: "90")])
    // Media time = mediaStart 90 + (120 − 60) = 150.
    try run(AddAnimation(clipID: 10, preset: .fullOpacity, at: 120), on: p)
    try expectTracks(p, tracks(track(0, [leaf(10, start: 60, dur: 300, ms: "90",
        parameters: #"{"opacity" : \#(param("0.0", 150, "1.0"))}"#, anim: visual(150))])))
}

@MainActor @Test func scalePresetsShareOneAnimationEntry() throws {
    let p = try project([leaf(10, start: 0, dur: 300)])
    try run(AddAnimation(clipID: 10, preset: .scaleUp, at: 30), on: p)
    try AddAnimation(clipID: 10, preset: .scaleDown, at: 90).apply(to: p)
    let s0 = #"{"type" : "double", "defaultValue" : 1.0, "keyframes" : [\#(kf(30, "1.25")), \#(kf(90, "0.75"))]}"#
    try expectTracks(p, tracks(track(0, [leaf(10, start: 0, dur: 300,
        parameters: #"{"scale0" : \#(s0), "scale1" : \#(s0)}"#, anim: visual(30, 90))])))
}

@MainActor @Test func stillsUseTrimStartSumAndScaleToFitTheHeight() throws {
    // Trimmed by 20: keyframe time = trimStartSum + time since the visible start (§3).
    let p = try project([still(10, start: 100, dur: 300, trimStartSum: 20)])
    try run(AddAnimation(clipID: 10, preset: .scaleToFit, at: 130), on: p)
    let s = param("1.0", 50, "2.7")      // 1080 / 400 [obs]
    try expectTracks(p, tracks(track(0, [still(10, start: 100, dur: 300, trimStartSum: 20,
        parameters: #"{"scale0" : \#(s), "scale1" : \#(s)}"#, anim: visual(50))])))
}

@MainActor @Test func tiltPresetsOnTheObservedStill() throws {
    let p = try project([still(10, start: 0, dur: 300)])
    try run(AddAnimation(clipID: 10, preset: .tiltLeft, at: 30), on: p)
    try AddAnimation(clipID: 10, preset: .tiltRight, at: 90).apply(to: p)
    let params = try #require(p.tracks[0].clips.first?.object["parameters"]?.object)
    #expect(params.keys == ["translation0", "rotation1", "scale0", "scale1"])
    func values(_ k: String) -> [Double] {
        params[k]?.object?["keyframes"]?.array?.items.compactMap { $0.object?["value"]?.double } ?? []
    }
    #expect(values("translation0") == [-480, 480])
    // Written with 15 significant digits, like every WizRec double.
    #expect(values("rotation1") == [0.523598775598299, -0.523598775598299])
    #expect(values("scale0") == [0.5, 2.4] && values("scale1") == [0.5, 2.4])   // 2.4 [obs]
    #expect(p.tracks[0].clips.first?.object["animationTracks"] == (try JSON.parse(visual(30, 90))))
}

@MainActor @Test func customAddsOnlyTheAnimationEntry() throws {
    let p = try project([leaf(10, start: 0, dur: 300)])
    try run(AddAnimation(clipID: 10, preset: .custom, at: 45), on: p)
    try expectTracks(p, tracks(track(0, [leaf(10, start: 0, dur: 300, anim: visual(45))])))
}

@MainActor @Test func unifiedMediaAnimatesItsVideoPart() throws {
    let unified = """
    {"id" : 13, "_type" : "UnifiedMedia", "video" : \(leaf(14, start: 0, dur: 300)), \
    "audio" : \(leaf(15, type: "AMFile", start: 0, dur: 300)), "start" : 0, "duration" : 300, \
    "mediaStart" : 0, "mediaDuration" : 300, "scalar" : 1}
    """
    let audioOnly = leaf(20, type: "AMFile", start: 400, dur: 100)
    let p = try project([unified, audioOnly])
    try run(AddAnimation(clipID: 13, preset: .noOpacity, at: 60), on: p)
    let clip = try #require(p.tracks[0].clips.first)
    #expect(clip.object["parameters"] == nil && clip.object["animationTracks"] == nil)
    #expect(clip.video?.object["parameters"] == (try JSON.parse(#"{"opacity" : \#(param("1.0", 60, "0.0"))}"#)))
    #expect(clip.video?.object["animationTracks"] == (try JSON.parse(visual(60))))
    #expect(clip.audio?.object["animationTracks"] == (try JSON.parse("{}")))

    expectRejected(AddAnimation(clipID: 20, preset: .noOpacity, at: 450), on: p, .invalid(""))
    expectRejected(AddAnimation(clipID: 99, preset: .noOpacity, at: 0), on: p, .clipNotFound(99))
    #expect(AddAnimation.canApply(.noOpacity, clipID: 13, in: p))
    #expect(!AddAnimation.canApply(.custom, clipID: 20, in: p))
    #expect(!AddAnimation.canApply(.custom, clipID: 99, in: p))
}

@MainActor @Test func existingKeyframesAndBareNumbersAreKept() throws {
    // A long-form parameter with an interp and a keyframe; a bare number.
    let opacity = """
    {"type" : "double", "defaultValue" : 0.8, "interp" : "linr", "keyframes" : [\
    {"endTime" : 200, "time" : 180, "value" : 0.2, "interp" : "linr", "duration" : 20}]}
    """
    let p = try project([leaf(10, start: 0, dur: 300, parameters: #"{"opacity" : \#(opacity), "scale0" : 0.5}"#)])
    try run(AddAnimation(clipID: 10, preset: .fullOpacity, at: 60), on: p)
    try AddAnimation(clipID: 10, preset: .scaleUp, at: 60).apply(to: p)
    // Same end time again: the value is replaced, not duplicated.
    try AddAnimation(clipID: 10, preset: .noOpacity, at: 200).apply(to: p)
    let wantOpacity = """
    {"type" : "double", "defaultValue" : 0.8, "interp" : "linr", "keyframes" : [\(kf(60, "1.0")), \
    {"endTime" : 200, "time" : 180, "value" : 0.0, "interp" : "linr", "duration" : 20}]}
    """
    let params = #"{"opacity" : \#(wantOpacity), "scale0" : \#(param("0.5", 60, "1.25")), "scale1" : \#(param("1.0", 60, "1.25"))}"#
    // The replaced keyframe keeps its own 180…200 window, which gets its entry.
    let anim = #"{"visual" : [{"endTime" : 60, "duration" : 30}, {"endTime" : 200, "duration" : 20}]}"#
    try expectTracks(p, tracks(track(0, [leaf(10, start: 0, dur: 300, parameters: params, anim: anim)])))
}

@MainActor @Test func nestedAndSpedUpClipsUseTheirMediaAxis() throws {
    // A group at 100 (mediaStart 30) holding a clip at inner 50; a 2× clip (scalar 1/2) on track 1.
    let inner = #"{"trackIndex" : 0, "medias" : [\#(leaf(21, start: 50, dur: 100))], "parameters" : {}}"#
    let group = """
    {"id" : 20, "_type" : "Group", "tracks" : [\(inner)], "attributes" : {"ident" : "G"}, "parameters" : {}, \
    "effects" : [], "start" : 100, "duration" : 200, "mediaStart" : 30, "mediaDuration" : 200, "scalar" : 1, \
    "metadata" : {}, "animationTracks" : {}}
    """
    let fast = leaf(30, start: 0, dur: 150, md: "300", scalar: #""1/2""#)
    let p = try project([group], extraTracks: [track(1, [fast])])
    // Playhead 150: group inner time 30 + 50 = 80; clip media time 0 + (80 − 50) = 30.
    try run(AddAnimation(clipID: 21, preset: .noOpacity, at: 150), on: p)
    let g = try #require(p.tracks[0].clips.first)
    let c = try #require(g.tracks.first?.clips.first)
    #expect(c.object["parameters"] == (try JSON.parse(#"{"opacity" : \#(param("1.0", 30, "0.0"))}"#)))
    #expect(c.object["animationTracks"] == (try JSON.parse(visual(30))))
    #expect(g.object["animationTracks"] == (try JSON.parse("{}")))
    // Playhead 15 on the 2× clip: media time 15 / (1/2) = 30; 1 s on the media axis [WizRec].
    try run(AddAnimation(clipID: 30, preset: .custom, at: 15), on: p)
    try AddAnimation(clipID: 30, preset: .custom, at: 15).apply(to: p)
    #expect(p.tracks[1].clips.first?.object["animationTracks"] == (try JSON.parse(visual(30))))
}

@MainActor @Test func groupsWithBareParametersGetTheLongForm() throws {
    let group = """
    {"id" : 20, "_type" : "Group", "tracks" : [], "attributes" : {"ident" : "G", "widthAttr" : 1920.0, \
    "heightAttr" : 540.0}, "parameters" : {"translation0" : 12.0, "scale0" : 0.5, "scale1" : 0.5}, \
    "effects" : [], "start" : 0, "duration" : 300, "mediaStart" : 0, "mediaDuration" : 300, "scalar" : 1, \
    "metadata" : {}, "animationTracks" : {}}
    """
    let p = try project([group])
    try run(AddAnimation(clipID: 20, preset: .scaleToFit, at: 30), on: p)   // 1080 / 540 = 2
    let params = try #require(p.tracks[0].clips.first?.object["parameters"])
    let want = #"{"translation0" : 12.0, "scale0" : \#(param("0.5", 30, "2.0")), "scale1" : \#(param("0.5", 30, "2.0"))}"#
    #expect(params == (try JSON.parse(want)))
}

@MainActor @Test func presetsHaveNamesAndUndoRestoresBytes() throws {
    #expect(AnimationPreset.allCases.count == 8)
    #expect(Set(AnimationPreset.allCases.map(\.displayName)).count == 8)
    let p = try project([leaf(10, start: 0, dur: 300)])
    let original = p.serialized()
    let undo = UndoStack(project: p)
    for (i, preset) in AnimationPreset.allCases.enumerated() {
        try undo.perform(AddAnimation(clipID: 10, preset: preset, at: Int64(30 + 30 * i)))
    }
    #expect(undo.undoName == "Add Animation")
    let after = p.serialized()
    for _ in AnimationPreset.allCases { try undo.undo() }
    #expect(p.serialized() == original)
    for _ in AnimationPreset.allCases { try undo.redo() }
    #expect(p.serialized() == after)
    #expect(try Project(data: after).serialized() == after)
}
