import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

// Observed Camtasia split/trim/move behaviour (docs/specs/edit-semantics.md
// "X7 results"), replayed on the X7 image track: an image at 2–10 s with a
// fade at each end and a behaviour 0–5 s. editRate 30 → 1 s = 30 ticks.

private let behaviour = #"[{"effectName" : "GenericBehaviorEffect", "bypassed" : false, "start" : 0, "duration" : 150, "parameters" : {}}]"#

private func image(_ id: Int64, start: Int64, dur: Int64, tss: Int64) -> String {
    """
    {"id" : \(id), "_type" : "IMFile", "src" : 1, "trackNumber" : 0, "trimStartSum" : \(tss), \
    "parameters" : {}, "effects" : \(behaviour), "start" : \(start), "duration" : \(dur), \
    "mediaStart" : 0, "mediaDuration" : 1, "scalar" : 1}
    """
}

private func fades(start: Int64, end: Int64) -> String {
    let attrs = #"{"bypass" : false, "reverse" : false, "trivial" : false, "useAudioPreRoll" : true, "useVisualPreRoll" : true}"#
    return """
    [{"name" : "LuminanceFadeIn", "duration" : 30, "rightMedia" : \(start), "attributes" : \(attrs)}, \
    {"name" : "LuminanceFadeIn", "duration" : 30, "leftMedia" : \(end), "attributes" : \(attrs)}]
    """
}

@MainActor @Test func x7ImageSplitTrimAndMoveKeepBehaviourAndFades() throws {
    let p = try makeProject(tracks: tracks(track(0, [image(20, start: 60, dur: 240, tss: 0)],
                                                 transitions: fades(start: 20, end: 20))))
    // Split at 6 s, 4 s into the image: the right half's trimStartSum is the
    // offset, the end fade follows it, the behaviour window is kept on both
    // halves although the right half (media 4–8 s) never reaches it [obs #3–5].
    let split = SplitClip(clipID: 20, at: 180)
    try expectReversible(split, on: p)
    try split.apply(to: p)
    try expectTracks(p, tracks(track(0, [image(20, start: 60, dur: 120, tss: 0), image(21, start: 180, dur: 120, tss: 120)],
                                     transitions: fades(start: 20, end: 21))))

    // Trim the right half's start by 1 s: trimStartSum grows by 1 s; the
    // behaviour window is still not pruned [obs #4, #5].
    let trim = TrimClip(clipID: 21, edge: .start, to: 210)
    try expectReversible(trim, on: p)
    try trim.apply(to: p)
    try expectTracks(p, tracks(track(0, [image(20, start: 60, dur: 120, tss: 0), image(21, start: 210, dur: 90, tss: 150)],
                                     transitions: fades(start: 20, end: 21))))

    // Move the right half later: its one-sided end fade travels with it [obs #8].
    let move = MoveClip(clipID: 21, toTrack: 0, start: 300)
    try expectReversible(move, on: p)
    try move.apply(to: p)
    try expectTracks(p, tracks(track(0, [image(20, start: 60, dur: 120, tss: 0), image(21, start: 300, dur: 90, tss: 150)],
                                     transitions: fades(start: 20, end: 21))))
}

@MainActor @Test func x7StitchedSplitKeepsKeyframesTheRightHalfNeverReaches() throws {
    // Scale keyframes at media 1–2 s on a stitched clip of segments 0–4 s and
    // 4–6 s (source 0–4 s and 8–10 s), split at 5 s [obs #1, #4].
    let params = #"{"scale0" : {"type" : "double", "defaultValue" : 1.0, "keyframes" : [{"endTime" : 60, "time" : 30, "value" : 2.0, "interp" : "eioe", "duration" : 30}]}}"#
    func stitched(_ id: Int64, start: Int64, dur: Int64, ms: Int64, segIDs: (Int64, Int64)) -> String {
        """
        {"id" : \(id), "_type" : "StitchedMedia", "minMediaStart" : 0.0, "parameters" : \(params), "medias" : [\
        {"id" : \(segIDs.0), "_type" : "VMFile", "src" : 1, "start" : 0, "duration" : 120, "mediaStart" : 0, "mediaDuration" : 120, "scalar" : 1}, \
        {"id" : \(segIDs.1), "_type" : "VMFile", "src" : 1, "start" : 120, "duration" : 60, "mediaStart" : 240, "mediaDuration" : 60, "scalar" : 1}], \
        "effects" : [], "start" : \(start), "duration" : \(dur), "mediaStart" : \(ms), "mediaDuration" : \(dur), "scalar" : 1}
        """
    }
    let p = try makeProject(tracks: tracks(track(0, [stitched(40, start: 0, dur: 180, ms: 0, segIDs: (41, 42))])))
    let split = SplitClip(clipID: 40, at: 150)
    try expectReversible(split, on: p)
    try split.apply(to: p)
    try expectTracks(p, tracks(track(0, [
        stitched(40, start: 0, dur: 150, ms: 0, segIDs: (41, 42)),
        stitched(43, start: 150, dur: 30, ms: 150, segIDs: (44, 45)),
    ])))
}
