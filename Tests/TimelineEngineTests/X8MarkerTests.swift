import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

// Observed marker behaviour (docs/specs/markers.md "X8 results"). editRate 30
// → 1 s = 30 ticks. Clips 0–4 s, 4–6 s, 6–10 s on one track; marker at 8 s.

private let toc = #"{"toc" : {"type" : "string", "keyframes" : [{"endTime" : 240, "time" : 240, "value" : "Marker", "duration" : 0}]}}"#

@MainActor
private func x8Project() throws -> Project {
    let p = try projectWithAttributes([track(0, [
        leaf(10, start: 0, dur: 120), leaf(11, start: 120, dur: 60, ms: "120"), leaf(12, start: 180, dur: 120, ms: "180"),
    ])])
    try AddMarker(at: 240).apply(to: p)
    #expect(p.timeline?.object["parameters"] == (try JSON.parse(toc)))
    return p
}

@MainActor @Test func x8NewMarkerIsNamedMarkerAndPlacedBeforeCaptionAttributes() throws {
    let p = try x8Project()
    #expect(Markers.timeline(p) == [Marker(time: 240, name: "Marker")])
    #expect(p.timeline?.object.keys == ["id", "sceneTrack", "trackAttributes", "parameters", "captionAttributes"])
}

@MainActor @Test func x8RippleDeleteLeavesTimelineMarkers() throws {
    let p = try x8Project()
    let del = DeleteClips(clipIDs: [11], ripple: true)
    try expectReversible(del, on: p)
    try del.apply(to: p)
    try expectTracks(p, tracks(track(0, [leaf(10, start: 0, dur: 120), leaf(12, start: 120, dur: 120, ms: "180")])))
    #expect(p.timeline?.object["parameters"] == (try JSON.parse(toc)))  // marker stays at 8 s
}

@MainActor @Test func x8RippleTrimAndMoveLeaveTimelineMarkers() throws {
    let p = try x8Project()
    let trim = RippleTrim(clipID: 11, edge: .end, to: 150)
    try expectReversible(trim, on: p)
    try trim.apply(to: p)
    #expect(p.tracks[0].clips.map(\.start) == [0, 120, 150])
    #expect(p.timeline?.object["parameters"] == (try JSON.parse(toc)))
    let move = RippleMove(clipID: 10, toTrack: 0, start: 270)
    try expectReversible(move, on: p)
    try move.apply(to: p)
    #expect(p.timeline?.object["parameters"] == (try JSON.parse(toc)))
}
