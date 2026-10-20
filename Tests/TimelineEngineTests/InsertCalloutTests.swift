import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

// InsertCallout (callouts.md §3.1, CO3): 5 s at the playhead, scaled to a display width.
// editRate 30 → 1 s = 30 ticks.

private let blurDef = #"{"kind" : "TypeWinBlur", "shape" : "", "style" : "", "width" : 400.0, "height" : 200.0, "intensity" : 0.8125, "blur-invert" : 0.0, "corner-radius" : 6.0}"#

private func callout(_ id: Int64, start: Int64, dur: Int64, def: String, params: String) -> String {
    """
    {"id" : \(id), "_type" : "Callout", "def" : \(def), \
    "attributes" : {"ident" : "", "autoRotateText" : true}, "parameters" : \(params), "effects" : [], \
    "start" : \(start), "duration" : \(dur), "mediaStart" : 0, "mediaDuration" : \(dur), "scalar" : 1, \
    "metadata" : {"audiateLinkedSession" : "", "clipSpeedAttribute" : {"type" : "bool", "value" : false}, \
    "colorAttribute" : {"type" : "color", "value" : [0, 0, 0, 0]}, "effectApplied" : "none"}, "animationTracks" : {}}
    """
}

private let crops = #""geometryCrop0" : 0.0, "geometryCrop1" : 0.0, "geometryCrop2" : 0.0, "geometryCrop3" : 0.0"#

@MainActor @Test func insertCalloutOnAFreeTrackAtThePlayheadScaledTo640() throws {
    let p = try makeProject(tracks: tracks(track(0, [leaf(10, start: 0, dur: 60)]), track(1, [])))
    let c = InsertCallout(def: blurDef, start: 31, track: 1, displayWidth: 640)
    try expectReversible(c, on: p)
    try c.apply(to: p)
    #expect(c.clipID == 11)
    #expect(c.trackIndex == 1)
    // Start snapped to the frame grid (1 tick per frame here), 5 s long, scale 640 / 400.
    try expectTracks(p, tracks(track(0, [leaf(10, start: 0, dur: 60)]),
                               track(1, [callout(11, start: 31, dur: 150, def: blurDef,
                                                 params: #"{"scale0" : 1.6, "scale1" : 1.6, "# + crops + "}")])))
}

@MainActor @Test func insertCalloutWithoutDisplayWidthWritesNoScale() throws {
    let key = #"{"kind" : "MacKey", "shape" : "", "style" : "", "width" : 128.0, "height" : 64.0, "keys" : "A"}"#
    let p = try makeProject(tracks: tracks(track(0, [])))
    let c = InsertCallout(def: key, start: 0, track: 0, duration: 60)
    try c.apply(to: p)
    try expectTracks(p, tracks(track(0, [callout(2, start: 0, dur: 60, def: key, params: "{" + crops + "}")])))
}

@MainActor @Test func insertCalloutAddsATopTrackWhenNoneIsGiven() throws {
    let p = try makeProject(tracks: tracks(track(0, [leaf(10, start: 0, dur: 300)])))
    let c = InsertCallout(def: blurDef, start: 60, displayWidth: 640)
    try expectReversible(c, on: p)
    try c.apply(to: p)
    #expect(c.trackIndex == 1)
    let medias = sceneTracks(p).array?.items.last?.object?["medias"]?.array?.items ?? []
    #expect(medias.count == 1)
    #expect(medias.first?.object?["_type"]?.string == "Callout")
    #expect(medias.first?.object?["start"]?.int == 60)
    try c.revert(on: p)
    #expect(sceneTracks(p).array?.count == 1)
}

@MainActor @Test func insertCalloutRejectsABusyTrackAndBadDefs() throws {
    let p = try makeProject(tracks: tracks(track(0, [leaf(10, start: 0, dur: 300)])))
    try expectRejected(InsertCallout(def: blurDef, start: 60, track: 0), on: p)
    try expectRejected(InsertCallout(def: "[1]", start: 0, track: 0), on: p)
    try expectRejected(InsertCallout(def: blurDef, start: 0, track: 5), on: p)
    try expectRejected(InsertCallout(def: blurDef, start: 400, track: 0, duration: 0), on: p)
}
