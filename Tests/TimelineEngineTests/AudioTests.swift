import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

// Audio panel items, fades and audio points as Camtasia 2026.2.3 saves them (audio.md §3–§4, AU1).
// editRate 30 here, so 1 s = 30 ticks.

/// An AU1-like audio clip: 10 s, no effects, metadata as Camtasia writes it.
private func amClip(_ id: Int64 = 3, start: Int64 = 0, dur: Int64 = 300, ms: Int64 = 0, parameters: String = "{}") -> String {
    """
    {"id" : \(id), "_type" : "AMFile", "src" : 1, "trackNumber" : 0, "start" : \(start), "duration" : \(dur), \
    "mediaStart" : \(ms), "mediaDuration" : \(dur), "scalar" : 1, "effects" : [], \
    "metadata" : {"audiateLinkedSession" : "", "clipSpeedAttribute" : {"type" : "bool", "value" : false}, \
    "colorAttribute" : {"type" : "color", "value" : [0, 0, 0, 0]}, "effectApplied" : "none"}, \
    "parameters" : \(parameters), \
    "attributes" : {"ident" : "synth-speech", "gain" : 1.0, "mixToMono" : false, "loudnessNormalization" : true}}
    """
}

private func withClip(_ clip: String, effects: String = "[]", effectApplied: String = "none",
                      clipSpeed: Bool = false) -> String {
    var s = clip.replacingOccurrences(of: #""effects" : []"#, with: #""effects" : \#(effects)"#)
    s = s.replacingOccurrences(of: #""effectApplied" : "none""#, with: #""effectApplied" : "\#(effectApplied)""#)
    if clipSpeed { s = s.replacingOccurrences(of: #""value" : false}"#, with: #""value" : true}"#) }
    return s
}

private func points(_ p: [(Int64, String)]) -> String {
    #"{"volume" : {"type" : "double", "keyframes" : ["# + p.map {
        #"{"endTime" : \#($0.0), "time" : \#($0.0), "value" : \#($0.1), "duration" : 0}"#
    }.joined(separator: ", ") + "]}}"
}

@MainActor @Test func panelHasTheEightItemsOf2026() {
    #expect(AudioPanelItem.allCases.map(\.displayName) == [
        "AI Noise Removal", "Audio Compression", "Captions", "Clip Speed", "Emphasize", "Fade In", "Fade Out", "Pitch",
    ])
    #expect(AudioPanelItem.allCases.compactMap(\.effectName) == [
        "VSTEffect-DFN3NoiseRemoval", "WinCompression", "Emphasize", "Pitch",
    ])
}

@MainActor @Test func effectItemsWriteAU1Defaults() throws {
    let cases: [(AudioPanelItem, String)] = [
        (.aiNoiseRemoval, #"{"effectName" : "VSTEffect-DFN3NoiseRemoval", "bypassed" : false, "category" : "categoryAudioEffects", "parameters" : {"Amount" : 0.8, "Bypass" : 0.0}}"#),
        (.audioCompression, #"{"effectName" : "WinCompression", "bypassed" : false, "category" : "categoryAudioEffects", "parameters" : {"ratio" : 10.0, "threshold" : -20.0, "gain" : 9.0, "attack" : 0.0, "release" : 3500.0, "preset" : 1}}"#),
        (.emphasize, #"{"effectName" : "Emphasize", "bypassed" : false, "category" : "categoryAudioEffects", "parameters" : {"emphasizeAmount" : 0.8, "emphasizeRampPosition" : 0, "emphasizeRampInTime" : 30, "emphasizeRampOutTime" : 30}}"#),
        (.pitch, #"{"effectName" : "Pitch", "bypassed" : false, "category" : "categoryAudioEffects", "parameters" : {"pitch" : -200.0, "effectBlend" : 100.0, "smoothness" : 50.0, "tightness" : 50.0}}"#),
    ]
    for (item, effect) in cases {
        let p = try makeProject(tracks: tracks(track(0, [amClip()])))
        let c = ApplyAudioItem(clipID: 3, item: item)
        try expectReversible(c, on: p)
        try c.apply(to: p)
        try expectTracks(p, tracks(track(0, [withClip(amClip(), effects: "[\(effect)]",
                                                       effectApplied: item.effectName ?? "")])))
    }
    // At the real edit rate the ramps are 705600000 (1 s), as in AU1.
    let e = try #require(AudioPanelItem.emphasize.effectJSON())
    #expect(e["parameters"]?.object?["emphasizeRampInTime"] == .number(JSONNumber(lexeme: "705600000")))
}

@MainActor @Test func clipSpeedItemOnlyMarksMetadata() throws {
    let p = try makeProject(tracks: tracks(track(0, [amClip()])))
    let c = ApplyAudioItem(clipID: 3, item: .clipSpeed)
    try expectReversible(c, on: p)
    try c.apply(to: p)
    try expectTracks(p, tracks(track(0, [withClip(amClip(), effectApplied: "Clip Speed", clipSpeed: true)])))
}

@MainActor @Test func captionsItemIsNotAClipEffect() throws {
    let p = try makeProject(tracks: tracks(track(0, [amClip()])))
    #expect(throws: EditError.self) { try ApplyAudioItem(clipID: 3, item: .captions).apply(to: p) }
}

@MainActor @Test func fadeInWritesTwoPoints() throws {
    let p = try makeProject(tracks: tracks(track(0, [amClip()])))
    let c = ApplyAudioItem(clipID: 3, item: .fadeIn)
    try expectReversible(c, on: p)
    try c.apply(to: p)
    try expectTracks(p, tracks(track(0, [amClip(parameters: points([(0, "0.0"), (30, "1.0")]))])))
}

@MainActor @Test func fadeOutWritesThreePoints() throws {
    let p = try makeProject(tracks: tracks(track(0, [amClip()])))
    let c = ApplyAudioItem(clipID: 3, item: .fadeOut)
    try expectReversible(c, on: p)
    try c.apply(to: p)
    try expectTracks(p, tracks(track(0, [amClip(parameters: points([(0, "1.0"), (270, "1.0"), (300, "0.0")]))])))
}

@MainActor @Test func fadeInThenOutCombine() throws {
    let p = try makeProject(tracks: tracks(track(0, [amClip()])))
    try AudioFade(clipID: 3, .fadeIn).apply(to: p)
    try AudioFade(clipID: 3, .fadeOut).apply(to: p)
    try expectTracks(p, tracks(track(0, [amClip(parameters: points([(0, "0.0"), (30, "1.0"), (270, "1.0"), (300, "0.0")]))])))
}

@MainActor @Test func fadesUseMediaTimeAndCurrentLevel() throws {
    // Trimmed clip (mediaStart 60) at volume 0.5: points on the media axis, level kept.
    let clip = amClip(start: 100, dur: 90, ms: 60, parameters: #"{"volume" : 0.5}"#)
    let p = try makeProject(tracks: tracks(track(0, [clip])))
    try AudioFade(clipID: 3, .fadeOut, length: 15).apply(to: p)
    try expectTracks(p, tracks(track(0, [amClip(start: 100, dur: 90, ms: 60,
                                                parameters: points([(60, "0.5"), (135, "0.5"), (150, "0.0")]))])))
    // Longer than the clip: shortened to it.
    let q = try makeProject(tracks: tracks(track(0, [amClip(dur: 20)])))
    try AudioFade(clipID: 3, .fadeIn).apply(to: q)
    try expectTracks(q, tracks(track(0, [amClip(dur: 20, parameters: points([(0, "0.0"), (20, "1.0")]))])))
}

@MainActor @Test func addAudioPointWritesStartAndPlayhead() throws {
    let p = try makeProject(tracks: tracks(track(0, [amClip()])))
    let c = AddAudioPoint(clipID: 3, at: 60)
    try expectReversible(c, on: p)
    try c.apply(to: p)
    try expectTracks(p, tracks(track(0, [amClip(parameters: points([(0, "1.0"), (60, "1.0")]))])))
    // A second use adds one point at the new playhead, at the envelope's level there.
    try AddAudioPoint(clipID: 3, at: 120).apply(to: p)
    try expectTracks(p, tracks(track(0, [amClip(parameters: points([(0, "1.0"), (60, "1.0"), (120, "1.0")]))])))
    #expect(throws: EditError.self) { try AddAudioPoint(clipID: 3, at: 120).apply(to: p) }
    #expect(throws: EditError.self) { try AddAudioPoint(clipID: 3, at: 400).apply(to: p) }
    // Between fade points the new point takes the interpolated level.
    let q = try makeProject(tracks: tracks(track(0, [amClip(parameters: points([(0, "0.0"), (30, "1.0")]))])))
    try AddAudioPoint(clipID: 3, at: 15).apply(to: q)
    try expectTracks(q, tracks(track(0, [amClip(parameters: points([(0, "0.0"), (15, "0.5"), (30, "1.0")]))])))
}

@MainActor @Test func unifiedMediaVolumeGoesToTheAudioChild() throws {
    let child = { (type: String, id: Int64, params: String) in
        #"{"id" : \#(id), "_type" : "\#(type)", "src" : 1, "trackNumber" : 0, "start" : 0, "duration" : 300, "mediaStart" : 0, "mediaDuration" : 300, "scalar" : 1, "parameters" : \#(params), "effects" : []}"#
    }
    let unified = { (params: String) in
        #"{"id" : 1, "_type" : "UnifiedMedia", "video" : \#(child("ScreenVMFile", 2, "{}")), "audio" : \#(child("AMFile", 3, params)), "start" : 0, "duration" : 300, "mediaStart" : 0, "mediaDuration" : 300, "scalar" : 1, "effects" : []}"#
    }
    let p = try makeProject(tracks: tracks(track(0, [unified("{}")])))
    try AudioFade(clipID: 1, .fadeIn).apply(to: p)
    try expectTracks(p, tracks(track(0, [unified(points([(0, "0.0"), (30, "1.0")]))])))
}

@MainActor @Test func setSourceLoudnessWritesMeasuredValues() throws {
    let src = #"[{"id" : 1, "src" : "a.wav", "sourceTracks" : [{"type" : 2, "integratedLUFS" : 100.0, "peakLevel" : -1.0, "tag" : 0}]}]"#
    let p = try makeProject(tracks: tracks(track(0, [amClip()])), sourceBin: src)
    let c = SetSourceLoudness(sourceID: 1, track: 0, integratedLUFS: -37.2512483366092, peakLevel: 0.0473308339715004)
    try expectReversible(c, on: p)
    try c.apply(to: p)
    let st = JSONPath(steps: [.key("sourceBin"), .index(0), .key("sourceTracks"), .index(0)]).resolve(in: p.root)
    #expect(st == (try JSON.parse(#"{"type" : 2, "integratedLUFS" : -37.2512483366092, "peakLevel" : 0.0473308339715004, "tag" : 0}"#)))
    try SetSourceLoudness(sourceID: 1, track: 0, integratedLUFS: -.infinity, peakLevel: 0).apply(to: p)
    #expect(String(decoding: p.serialized(), as: UTF8.self).contains("-Infinity"))
    #expect(throws: EditError.self) { try SetSourceLoudness(sourceID: 9, track: 0, integratedLUFS: -20, peakLevel: 1).apply(to: p) }
}
