import Foundation
import Testing
import TSCProjKit
import TimelineEngine
@testable import Captions

/// Ticks per second and per 30-fps frame in the test projects.
let rate: Int64 = 705_600_000
let frame: Int64 = 23_520_000
func s(_ seconds: Double) -> Int64 { Int64((seconds * Double(rate)).rounded()) }

/// An audio source (id 1, one mono track) and a video+audio source (id 2), 10 s each.
let testSourceBin = """
[{"id" : 1, "src" : "./media/a.m4a", "rect" : [0, 0, 0, 0], "lastMod" : "x", \
"sourceTracks" : [{"range" : [0, 480000], "type" : 2, "editRate" : 48000, "trackRect" : [0, 0, 0, 0], \
"sampleRate" : 48000, "bitDepth" : 16, "numChannels" : 1, "metaData" : "", "parameters" : {}}]}, \
{"id" : 2, "src" : "./media/v.mp4", "rect" : [0, 0, 1920, 1080], "lastMod" : "x", \
"sourceTracks" : [{"range" : [0, 300], "type" : 0, "editRate" : 30, "trackRect" : [0, 0, 1920, 1080], "metaData" : ""}, \
{"range" : [0, 480000], "type" : 2, "editRate" : 48000, "trackRect" : [0, 0, 0, 0], "metaData" : ""}]}]
"""

/// JSON text of an `AMFile` of source 1.
func amFile(_ id: Int64, start: Int64, dur: Int64, mediaStart: Int64 = 0, parameters: String = "{}") -> String {
    """
    {"id" : \(id), "_type" : "AMFile", "src" : 1, "trackNumber" : 0, "attributes" : {"gain" : 1.0}, \
    "channelNumber" : "0", "parameters" : \(parameters), "effects" : [], "start" : \(start), "duration" : \(dur), \
    "mediaStart" : \(mediaStart), "mediaDuration" : \(dur), "scalar" : 1, "metadata" : {}, "animationTracks" : {}}
    """
}

/// JSON text of a `UnifiedMedia` of source 2 (video + audio halves).
func unified(_ id: Int64, start: Int64, dur: Int64) -> String {
    func half(_ hid: Int64, _ type: String, _ tn: Int) -> String {
        """
        {"id" : \(hid), "_type" : "\(type)", "src" : 2, "trackNumber" : \(tn), "attributes" : {}, "parameters" : {}, \
        "effects" : [], "start" : \(start), "duration" : \(dur), "mediaStart" : 0, "mediaDuration" : \(dur), "scalar" : 1, \
        "metadata" : {}, "animationTracks" : {}}
        """
    }
    return """
    {"id" : \(id), "_type" : "UnifiedMedia", "video" : \(half(id + 1, "VMFile", 0)), "audio" : \(half(id + 2, "AMFile", 1)), \
    "start" : \(start), "duration" : \(dur), "mediaStart" : 0, "mediaDuration" : \(dur), "scalar" : 1, "metadata" : {}}
    """
}

func trackJSON(_ index: Int, _ medias: [String]) -> String {
    #"{"trackIndex" : \#(index), "medias" : [\#(medias.joined(separator: ", "))], "parameters" : {}}"#
}

/// A 1920×1080, 30 fps project at Camtasia's edit rate.
@MainActor
func makeProject(tracks: [String], sourceBin: String = testSourceBin) throws -> Project {
    let text = """
    {"title" : "t", "editRate" : 705600000, "width" : 1920.0, "height" : 1080.0, "videoFormatFrameRate" : 30, \
    "sourceBin" : \(sourceBin), "timeline" : {"id" : 1, "sceneTrack" : {"scenes" : [{"csml" : {"tracks" : \
    [\(tracks.enumerated().map { trackJSON($0.offset, [$0.element].filter { !$0.isEmpty }) }.joined(separator: ", "))]}}]}, \
    "trackAttributes" : []}}
    """
    return try Project(data: Data(text.utf8))
}

/// The value at a slash path (`"sourceBin/0/sourceTracks/0"`; numeric steps index arrays).
func at(_ p: Project, _ path: String) -> JSON? {
    var cur = JSON.object(p.root)
    for step in path.split(separator: "/") {
        if let i = Int(step), let a = cur.array {
            guard a.items.indices.contains(i) else { return nil }
            cur = a[i]
        } else if let o = cur.object, let v = o[String(step)] {
            cur = v
        } else { return nil }
    }
    return cur
}

/// Expects the JSON at `path` to equal `expected` structurally (keys, key order, number lexemes).
func expectJSON(_ p: Project, _ path: String, _ expected: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let want = try JSON.parse(expected)
    let got = at(p, path) ?? .null
    #expect(got == want, """
        \(path) differs.
        got:
        \(String(decoding: got.serialized(), as: UTF8.self))
        want:
        \(String(decoding: want.serialized(), as: UTF8.self))
        """, sourceLocation: sourceLocation)
}

/// Apply → revert → re-apply → revert: reverts are byte-identical, re-apply reproduces the first result.
@MainActor
func expectReversible(_ command: any EditCommand, on p: Project, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let before = p.serialized()
    try command.apply(to: p)
    let after = p.serialized()
    #expect(after != before, "command changed nothing", sourceLocation: sourceLocation)
    try command.revert(on: p)
    #expect(p.serialized() == before, "revert is not byte-identical", sourceLocation: sourceLocation)
    try command.apply(to: p)
    #expect(p.serialized() == after, "re-apply differs", sourceLocation: sourceLocation)
    try command.revert(on: p)
    #expect(p.serialized() == before, sourceLocation: sourceLocation)
}

/// `apply` throws and leaves the project byte-identical.
@MainActor
func expectRejected(_ command: any EditCommand, on p: Project, sourceLocation: SourceLocation = #_sourceLocation) {
    let before = p.serialized()
    #expect(throws: (any Error).self, sourceLocation: sourceLocation) { try command.apply(to: p) }
    #expect(p.serialized() == before, "project changed after a failed apply", sourceLocation: sourceLocation)
}

/// Words with explicit times, seconds.
func w(_ text: String, _ start: Double, _ end: Double) -> TranscriptWord { TranscriptWord(text: text, start: start, end: end) }
