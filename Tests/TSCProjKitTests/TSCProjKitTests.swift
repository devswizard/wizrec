import Foundation
import Testing
@testable import TSCProjKit

private func fixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
}

private func demo() throws -> Project { try Project(contentsOf: fixture("demo.tscproj")) }

// MARK: - Lossless round-trip

@Test func demoRoundTripIsLossless() throws {
    let data = try Data(contentsOf: fixture("demo.tscproj"))
    let original = try JSON.parse(data)
    let project = try Project(data: data)
    #expect(try JSON.parse(project.serialized()) == original)
}

@Test func serializationIsIdempotent() throws {
    let once = try demo().serialized()
    let twice = try Project(data: once).serialized()
    #expect(once == twice)
}

/// Camtasia's own sample projects span format 2.0–10.0 and Mac/Windows
/// writers. They are TechSmith's files, so they are read from a local install
/// rather than vendored.
@Test(.enabled(if: FileManager.default.fileExists(atPath: "/Applications/Camtasia.app")))
func installedSampleProjectsRoundTrip() throws {
    let root = URL(fileURLWithPath: "/Applications/Camtasia.app/Contents/Resources")
    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "tscproj" }
    #expect(!files.isEmpty)
    for url in files {
        let data = try Data(contentsOf: url)
        let reparsed = try JSON.parse(Project(data: data).serialized())
        #expect(reparsed == (try JSON.parse(data)), "\(url.lastPathComponent)")
    }
}

// MARK: - Editing keeps everything else

@Test func editingOneFieldPreservesTheRest() throws {
    let project = try demo()
    let group = try #require(project.tracks.first?.clips.first)
    let before = JSON.object(project.root.copy())

    group.start = 705_600_000  // move 1 s right

    let after = try JSON.parse(project.serialized())
    let movedGroup = try #require(after.object?["timeline"]?.object?["sceneTrack"]?.object?["scenes"]?
        .array?[0].object?["csml"]?.object?["tracks"]?.array?[0].object?["medias"]?.array?[0].object)
    #expect(movedGroup["start"]?.int == 705_600_000)
    #expect(movedGroup.keys == group.object.keys)

    group.start = 0
    #expect(JSON.object(project.root) == before)
}

@Test func setParameterReplacesAnimationInPlace() throws {
    let params = Parameters(try #require(JSON.parse(#"""
        {"a": 1, "scale0": {"type": "double", "defaultValue": 0.5, "keyframes": [{"time": 0, "value": 1}]}, "z": 2}
        """#).object))
    params.set("scale0", 0.75)
    #expect(params.names == ["a", "scale0", "z"])
    #expect(params["scale0"]?.isAnimated == false)
    #expect(params["scale0"]?.value(at: 0) == 0.75)
}

// MARK: - Typed model

@Test func demoHeader() throws {
    let p = try demo()
    #expect(p.formatVersion == "10.0")
    #expect(p.timebase.editRate == 705_600_000)
    #expect(p.width == 1920 && p.height == 1080)
    #expect(p.frameRate == Rational(30))
    #expect(p.authoringClient.platform == "Mac")
    #expect(p.sourceBin.map(\.id) == [1, 2])
    #expect(p.sourceBin[1].src.hasSuffix(".trec"))
    #expect(p.sourceBin[1].tracks.map(\.type) == [0, 0, 2])
}

@Test func demoClipTree() throws {
    let p = try demo()
    #expect(p.tracks.count == 2)
    let group = try #require(p.tracks[0].clips.first)
    #expect(group.kind == .group)
    #expect(group.children.map(\.kind) == [.video, .screenVideo, .unified])

    let screen = group.children[1]
    #expect(screen.sourceID == 2)
    #expect(screen.effects.map(\.name).contains("CursorPhysics"))

    let unified = group.children[2]
    #expect(unified.video?.kind == .video)
    #expect(unified.audio?.kind == .audio)
    #expect(unified.audio?.effects.first?.name == "VSTEffect-DFN3NoiseRemoval")
    #expect(group.referencedSourceIDs == [1, 2])
    #expect(p.maxID >= 9)
}

// MARK: - Numbers and time

@Test func numberLexemesSurvive() throws {
    let text = #"{"a": 0.714285714285714, "b": -1.79769313486232e+308, "c": 1920.0, "d": 705600000}"#
    let out = String(decoding: try JSON.parse(text).serialized(), as: UTF8.self)
    for lexeme in ["0.714285714285714", "-1.79769313486232e+308", "1920.0", "705600000"] {
        #expect(out.contains(lexeme))
    }
}

@Test func doublesFormatLikeCamtasia() {
    #expect(JSONNumber(1920.0).lexeme == "1920.0")
    #expect(JSONNumber(0.714285714285714).lexeme == "0.714285714285714")
    #expect(JSONNumber(-18.0).lexeme == "-18.0")
}

@Test func rationalsParse() {
    #expect(Rational(.string("304/457")) == Rational(304, 457))
    #expect(Rational(.string("2997/50"))?.double == 59.94)
    #expect(Rational(.number(JSONNumber(lexeme: "1"))) == Rational(1))
    #expect(Rational(608, 914) == Rational(304, 457))
    #expect(Rational(304, 457).json == .string("304/457"))
}

@Test func timebaseConversions() {
    let tb = Timebase.camtasia
    #expect(tb.seconds(4_374_720_000) == 6.2)
    #expect(tb.frame(705_600_000, fps: Rational(60)) == 60)
    #expect(tb.ticks(frame: 1, fps: Rational(30_000, 1001)) == 23_543_520)
    #expect(tb.timecode(18_110_880_000) == "00:00:25.667")
    #expect(Timebase(editRate: 30).seconds(172) == 172.0 / 30)
}

/// Observed in the user's vlog: `mediaDuration × scalar == duration` (scalar = 1/speed).
@Test func clipSpeedMapsTimelineToMedia() throws {
    let clip = Clip(try #require(JSON.parse(
        #"{"_type": "VMFile", "start": 100, "duration": 304, "mediaStart": 10, "mediaDuration": 457, "scalar": "304/457"}"#).object))
    #expect(clip.mediaTime(atTimeline: 100) == Rational(10))
    #expect(clip.mediaTime(atTimeline: 404) == Rational(467))
    #expect(clip.mediaDuration * clip.scalar == Rational(clip.duration))
}

// MARK: - Keyframes

@Test func keyframesInterpolate() throws {
    let p = Parameter(try JSON.parse(#"""
        {"type": "double", "defaultValue": 0.0, "keyframes": [
          {"time": 10, "endTime": 20, "duration": 10, "value": 1.0, "interp": "linr"},
          {"time": 30, "endTime": 30, "duration": 0, "value": 5.0}
        ]}
        """#))
    #expect(p.isAnimated)
    #expect(p.value(at: 0) == 0)
    #expect(p.value(at: 15) == 0.5)
    #expect(p.value(at: 25) == 1)
    #expect(p.value(at: 30) == 5)
    #expect(p.value(at: 99) == 5)
}

@Test func bareScalarParameter() throws {
    let p = Parameter(.number(JSONNumber(lexeme: "172.7")))
    #expect(!p.isAnimated)
    #expect(p.value(at: 0) == 172.7)
}

// MARK: - Strings

@Test func stringEscapesAndUnicodeRoundTrip() throws {
    let text = #"{"rtf": "{\\rtf1\\ansi\n}", "q": "say \"hi\"", "zh": "快速的棕色狐狸", "e": "😀"}"#
    let v = try JSON.parse(text)
    #expect(v.object?["rtf"]?.string == "{\\rtf1\\ansi\n}")
    #expect(v.object?["e"]?.string == "😀")
    #expect(try JSON.parse(v.serialized()) == v)
}

@Test func malformedInputThrows() {
    #expect(throws: JSONParseError.self) { try JSON.parse("{\"a\": }") }
    #expect(throws: JSONParseError.self) { try JSON.parse("{\"a\": 1} x") }
}

@Test func readingParametersNeverMutatesTheClip() throws {
    let o = try #require(JSON.parse(#"{"_type": "AMFile", "start": 0}"#).object)
    let clip = Clip(o)
    #expect(clip.parameters.opacity() == 1)
    #expect(o["parameters"] == nil)
    clip.editableParameters.set("volume", 0.5)
    #expect(o["parameters"]?.object?["volume"]?.double == 0.5)
}
