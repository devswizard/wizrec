import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

// `SetSourceEffectParameters` and `SetShaderVidSource` (`docs/specs/shader-backgrounds.md`
// §1, §6): background parameters edited as one undo step, keyframe-safe; library origin
// metadata written like Camtasia's demo save.

private let bgSource = """
{"id" : 2, "src" : "./media/1/bg.tscshadervid", "rect" : [0, 0, 1920, 1080], "sourceTracks" : [
 {"range" : [0, 9223372036854775807], "type" : 0, "editRate" : 30, "trackRect" : [0, 0, 1920, 1080], "numChannels" : 0}],
 "effectDef" : [
  {"name" : "Color0", "type" : "Color", "defaultValue" : [0.25, 0.5, 0.75, 1.0], "scalingType" : 3, "unitType" : 0, "userInterfaceType" : 6},
  {"name" : "Speed", "type" : "double", "defaultValue" : 2.0, "maxValue" : 10.0, "minValue" : 0.0, "scalingType" : 0, "unitType" : 0, "userInterfaceType" : 0},
  {"name" : "Pos", "type" : "Position", "defaultValue" : [960.0, 540.0, 0.0], "scalingType" : 1, "unitType" : 0, "userInterfaceType" : 5},
  {"name" : "sourceFileType", "type" : "string", "defaultValue" : "tscshadervid", "maxValue" : "", "minValue" : "", "scalingType" : 0, "unitType" : 0, "userInterfaceType" : 0}],
 "metadata" : {"timeAdded" : "kept"}}
"""

private let movieSource = """
{"id" : 3, "src" : "./media/1/clip.mp4", "rect" : [0, 0, 1920, 1080], "sourceTracks" : [
 {"range" : [0, 300], "type" : 0, "editRate" : 30, "trackRect" : [0, 0, 1920, 1080], "numChannels" : 0}]}
"""

private func p(_ v: String, interp: String = "linr", hints: String? = nil) -> String {
    let h = hints.map { #", "uiHints" : \#($0)"# } ?? ""
    return #"{"type" : "double", "defaultValue" : \#(v), "interp" : "\#(interp)"\#(h)}"#
}

private let speedHints = #"{"userInterfaceType" : 0, "unitType" : 0}"#

/// The `sourceEffect` InsertClip writes for `bgSource`, with `overrides` replacing parameter text.
private func sourceEffect(_ overrides: [String: String] = [:]) -> String {
    let base: [(String, String)] = [
        ("Color0-red", p("0.25")), ("Color0-green", p("0.5")), ("Color0-blue", p("0.75")), ("Color0-alpha", p("1.0")),
        ("Speed", p("2.0", hints: speedHints)), ("Pos.x", p("960.0")), ("Pos.y", p("540.0")),
        ("sourceFileType", #""tscshadervid""#),
    ]
    let body = base.map { k, v in #""\#(k)" : \#(overrides[k] ?? v)"# }.joined(separator: ", ")
    return #"{"effectName" : "SourceEffect", "bypassed" : false, "category" : "", "parameters" : {\#(body)}}"#
}

/// A project with the background clip (id 10, frames 0–60, `mediaStart` `ms`) on track 0.
@MainActor private func bgProject(sourceEffect se: String? = sourceEffect(), ms: String = "0") throws -> Project {
    var clip = leaf(10, start: 0, dur: 60, ms: ms, src: 2)
    if let se { clip = clip.replacingOccurrences(of: #""parameters" : {}"#, with: #""parameters" : {}, "sourceEffect" : \#(se)"#) }
    return try makeProject(tracks: tracks(track(0, [clip, leaf(11, start: 60, dur: 30, src: 3)])),
                           sourceBin: "[\(bgSource), \(movieSource)]")
}

@MainActor private func params(_ p: Project, _ id: Int64 = 10) throws -> JSON {
    var found: JSON?
    for t in p.tracks { for c in t.clips { c.walk { inner, _ in if inner.id == id { found = inner.object["sourceEffect"]?.object?["parameters"] } } } }
    return try #require(found)
}

// MARK: SetSourceEffectParameters

@MainActor @Test func backgroundParametersSetAsConstantsInOneStep() throws {
    let proj = try bgProject()
    let c = SetSourceEffectParameters(clipID: 10, changes: [
        .init("Color0-red", 1), .init("Color0-green", 0), .init("Color0-blue", 0.5), .init("Speed", 3.5),
    ])
    try expectReversible(c, on: proj)
    try c.apply(to: proj)
    let want = try JSON.parse(sourceEffect([
        "Color0-red": p("1.0"), "Color0-green": p("0.0"), "Color0-blue": p("0.5"), "Speed": p("3.5", hints: speedHints),
    ]))
    #expect(try params(proj) == want.object?["parameters"])
    #expect(c.name == "Change Background")
}

@MainActor @Test func backgroundParameterKeyframeIsLinearAndKeepsOthers() throws {
    let proj = try bgProject(ms: "30")
    // Media time 45 = 15 frames into the clip; the first keyframe eases from the visible start (30).
    let c = SetSourceEffectParameters(clipID: 10, changes: [.init("Speed", 4, keyframeAt: 45)])
    try expectReversible(c, on: proj)
    try c.apply(to: proj)
    let speed = #"""
    {"type" : "double", "defaultValue" : 2.0, "interp" : "linr", "uiHints" : {"userInterfaceType" : 0, "unitType" : 0},
     "keyframes" : [{"endTime" : 45, "time" : 30, "value" : 4.0, "interp" : "linr", "duration" : 15}]}
    """#
    #expect(try params(proj) == (try JSON.parse(sourceEffect(["Speed": speed]))).object?["parameters"])
    // The keyframe window is listed in animationTracks.visual as {endTime, duration} (§11.1 Q3).
    let anim = try JSON.parse(#"{"visual" : [{"endTime" : 45, "duration" : 15}]}"#)
    #expect(proj.tracks[0].clips[0].object["animationTracks"] == anim)
    // The same keyframe again only updates its value and reuses the entry.
    try SetSourceEffectParameters(clipID: 10, changes: [.init("Speed", 4, keyframeAt: 45)]).apply(to: proj)
    #expect(try params(proj).object?["Speed"]?.object?["keyframes"]?.array?.count == 1)
    #expect(proj.tracks[0].clips[0].object["animationTracks"] == anim)
}

@MainActor @Test func backgroundKeyframesAddOrReuseAnimationEntries() throws {
    // An existing transform animation 30–40 (range form) and a menu animation ending at 60
    // ({endTime, duration}) stay. A Speed keyframe at 40 (window 30–40) reuses the first;
    // Pos.x at 60 (30–60) and a second Speed keyframe at 50 (40–50) add entries in time order.
    let existing = #"{"visual" : [{"endTime" : 40, "duration" : 10, "range" : [30, 10], "interp" : "eioe"}, {"endTime" : 60, "duration" : 20}]}"#
    let proj = try makeProject(
        tracks: tracks(track(0, [leaf(10, start: 0, dur: 60, ms: "30", src: 2, anim: existing)
            .replacingOccurrences(of: #""parameters" : {}"#, with: #""parameters" : {}, "sourceEffect" : \#(sourceEffect())"#)])),
        sourceBin: "[\(bgSource), \(movieSource)]")
    let reuse = SetSourceEffectParameters(clipID: 10, changes: [.init("Speed", 3, keyframeAt: 40), .init("Pos.x", 100, keyframeAt: 60)])
    try expectReversible(reuse, on: proj)
    try reuse.apply(to: proj)
    let clip = proj.tracks[0].clips[0].object
    // Speed 30–40 and Pos.x 30–60 (first keyframe from the visible start): 30–60 is new.
    #expect(clip["animationTracks"] == (try JSON.parse(#"{"visual" : [{"endTime" : 40, "duration" : 10, "range" : [30, 10], "interp" : "eioe"}, {"endTime" : 60, "duration" : 30}, {"endTime" : 60, "duration" : 20}]}"#)))
    let split = SetSourceEffectParameters(clipID: 10, changes: [.init("Speed", 5, keyframeAt: 50)])
    try expectReversible(split, on: proj)
    try split.apply(to: proj)
    #expect(proj.tracks[0].clips[0].object["animationTracks"] == (try JSON.parse(#"{"visual" : [{"endTime" : 40, "duration" : 10, "range" : [30, 10], "interp" : "eioe"}, {"endTime" : 60, "duration" : 30}, {"endTime" : 50, "duration" : 10}, {"endTime" : 60, "duration" : 20}]}"#)))
    // Constants never touch animationTracks.
    let before = proj.tracks[0].clips[0].object["animationTracks"]
    try SetSourceEffectParameters(clipID: 10, changes: [.init("Color0-red", 0.1)]).apply(to: proj)
    #expect(proj.tracks[0].clips[0].object["animationTracks"] == before)
    #expect(try Project(data: proj.serialized()).serialized() == proj.serialized())
    // A later transform edit re-syncs animationTracks: the shader windows stay (with their
    // {endTime, duration} shape); only the unused 40–60 entry goes.
    try SetParameter(clipID: 10, parameter: "scale0", value: 0.5).apply(to: proj)
    #expect(proj.tracks[0].clips[0].object["animationTracks"] == (try JSON.parse(#"{"visual" : [{"endTime" : 40, "duration" : 10, "range" : [30, 10], "interp" : "eioe"}, {"endTime" : 60, "duration" : 30}, {"endTime" : 50, "duration" : 10}]}"#)))
}

@MainActor @Test func missingBackgroundParameterUsesEffectDefDefault() throws {
    // Camtasia-saved clips may lack a parameter; it is added at its effectDef default first.
    let trimmed = sourceEffect().replacingOccurrences(of: #""Color0-alpha" : \#(p("1.0")), "#, with: "")
    let proj = try bgProject(sourceEffect: trimmed)
    let c = SetSourceEffectParameters(clipID: 10, changes: [.init("Color0-alpha", 0.5, keyframeAt: 30)])
    try expectReversible(c, on: proj)
    try c.apply(to: proj)
    let alpha = try #require(try params(proj).object?["Color0-alpha"]?.object)
    #expect(alpha["defaultValue"] == J.dbl(1) && alpha["interp"]?.string == "linr")
    #expect(alpha["keyframes"]?.array?[0].object?["value"] == J.dbl(0.5))
    #expect(try params(proj).object?.keys.last == "Color0-alpha")
}

@MainActor @Test func missingSourceEffectIsCreatedFromEffectDef() throws {
    let proj = try bgProject(sourceEffect: nil)
    let c = SetSourceEffectParameters(clipID: 10, changes: [.init("Pos.x", 100)])
    try expectReversible(c, on: proj)
    try c.apply(to: proj)
    let clip = proj.tracks[0].clips[0].object
    #expect(Array(clip.keys.prefix(6)) == ["id", "_type", "src", "trackNumber", "start", "duration"])
    #expect(clip.keys.firstIndex(of: "sourceEffect") == (clip.keys.firstIndex(of: "parameters") ?? -9) + 1)
    #expect(try params(proj) == (try JSON.parse(sourceEffect(["Pos.x": p("100.0")]))).object?["parameters"])
}

@MainActor @Test func backgroundParameterEditsRejectBadTargets() throws {
    let proj = try bgProject()
    expectRejected(SetSourceEffectParameters(clipID: 10, changes: [.init("sourceFileType", 1)]), on: proj, .invalid(""))
    expectRejected(SetSourceEffectParameters(clipID: 11, changes: [.init("Speed", 1)]), on: proj, .invalid(""))
    expectRejected(SetSourceEffectParameters(clipID: 99, changes: [.init("Speed", 1)]), on: proj, .clipNotFound(99))
    expectRejected(SetSourceEffectParameters(clipID: 10, changes: []), on: proj, .invalid(""))
    expectRejected(SetSourceEffectParameters(clipID: 10, changes: [.init("Speed", .nan)]), on: proj, .invalid(""))
    expectRejected(SetSourceEffectParameters(clipID: 10, changes: [.init("Speed", 1, keyframeAt: -100)]), on: proj, .invalid(""))
}

@MainActor @Test func nestedBackgroundInDemoGroupIsEditable() throws {
    let demo = try demoProject()
    let before = try #require(try params(demo, 5).object?["Speed"]?.object?["defaultValue"])
    let c = SetSourceEffectParameters(clipID: 5, changes: [.init("Speed", 0.25)])
    try expectReversible(c, on: demo)
    try c.apply(to: demo)
    #expect(try params(demo, 5).object?["Speed"]?.object?["defaultValue"] == J.dbl(0.25))
    #expect(before != J.dbl(0.25))
}

// MARK: SetShaderVidSource

private let library = "/Users/me/Library/Application Support/WizRec/Backgrounds/wizrec-aurora.tscshadervid"

@MainActor @Test func shaderVidSourceIsInsertedInSortedOrder() throws {
    let proj = try bgProject()
    let md = proj.tracks[0].clips[0].object["metadata"]?.object
    md?["audiateLinkedSession"] = .string("")
    md?["note"] = nil
    md?["effectApplied"] = .string("none")
    let c = SetShaderVidSource(clipID: 10, path: library, revBackground: "backgrounds/wizrec-aurora.tscshadervid")
    try expectReversible(c, on: proj)
    try c.apply(to: proj)
    let got = proj.tracks[0].clips[0].object["metadata"]
    #expect(got == (try JSON.parse(#"{"ShaderVidSource" : "\#(library)", "audiateLinkedSession" : "", "effectApplied" : "none"}"#)))
    // Top-level clip: no group, so no RevBackground anywhere.
    #expect(!String(decoding: proj.serialized(), as: UTF8.self).contains("RevBackground"))
    // Setting it again replaces the value in place.
    try SetShaderVidSource(clipID: 10, path: "/other.tscshadervid").apply(to: proj)
    #expect(proj.tracks[0].clips[0].metadata?.keys.first == "ShaderVidSource")
    #expect(proj.tracks[0].clips[0].metadata?["ShaderVidSource"]?.string == "/other.tscshadervid")
}

@MainActor @Test func shaderVidSourceRejectsOrdinaryClips() throws {
    let proj = try bgProject()
    expectRejected(SetShaderVidSource(clipID: 11, path: library), on: proj, .invalid(""))
    expectRejected(SetShaderVidSource(clipID: 10, path: ""), on: proj, .invalid(""))
    expectRejected(SetShaderVidSource(clipID: 98, path: library), on: proj, .clipNotFound(98))
}

/// A group (id 20) holding the background on inner track `inner`, with `groupMD` metadata.
@MainActor private func groupedProject(groupMD: String, inner: Int = 0) throws -> Project {
    let bg = leaf(10, start: 0, dur: 60, src: 2)
    let other = leaf(12, start: 0, dur: 60, src: 3)
    let innerTracks = inner == 0 ? tracks(track(0, [bg]), track(1, [other])) : tracks(track(0, [other]), track(1, [bg]))
    let group = """
    {"id" : 20, "_type" : "Group", "tracks" : \(innerTracks), "attributes" : {"ident" : "g"}, "parameters" : {},
     "start" : 0, "duration" : 60, "mediaStart" : 0, "mediaDuration" : 60, "scalar" : 1,
     "metadata" : \(groupMD), "animationTracks" : {}}
    """
    return try makeProject(tracks: tracks(track(0, [group])), sourceBin: "[\(bgSource), \(movieSource)]")
}

private let revMD = #"{"RevBackground" : "backgrounds/old.tscshadervid", "RevLayoutID" : "L", "RevLook" : "K", "audiateLinkedSession" : "", "groupType" : "revMedia"}"#

@MainActor @Test func revGroupGetsRevBackgroundInPlace() throws {
    let proj = try groupedProject(groupMD: revMD)
    let c = SetShaderVidSource(clipID: 10, path: library, revBackground: "backgrounds/wizrec-aurora.tscshadervid")
    try expectReversible(c, on: proj)
    try c.apply(to: proj)
    let g = proj.tracks[0].clips[0]
    #expect(g.metadata?.keys == ["RevBackground", "RevLayoutID", "RevLook", "audiateLinkedSession", "groupType"])
    #expect(g.metadata?["RevBackground"]?.string == "backgrounds/wizrec-aurora.tscshadervid")
    #expect(g.tracks[0].clips[0].metadata?.keys == ["ShaderVidSource", "note"])
}

@MainActor @Test func revBackgroundIsAddedSortedWhenMissing() throws {
    let proj = try groupedProject(groupMD: #"{"RevLayoutID" : "L", "audiateLinkedSession" : "", "groupType" : "revMedia"}"#)
    try SetShaderVidSource(clipID: 10, path: library, revBackground: "backgrounds/x.tscshadervid").apply(to: proj)
    #expect(proj.tracks[0].clips[0].metadata?.keys == ["RevBackground", "RevLayoutID", "audiateLinkedSession", "groupType"])
}

@MainActor @Test func plainGroupsAndUpperTracksGetNoRevBackground() throws {
    let plain = try groupedProject(groupMD: #"{"audiateLinkedSession" : ""}"#)
    try SetShaderVidSource(clipID: 10, path: library, revBackground: "backgrounds/x.tscshadervid").apply(to: plain)
    #expect(plain.tracks[0].clips[0].metadata?["RevBackground"] == nil)
    #expect(plain.tracks[0].clips[0].tracks[0].clips[0].metadata?["ShaderVidSource"]?.string == library)

    let upper = try groupedProject(groupMD: revMD, inner: 1)
    try SetShaderVidSource(clipID: 10, path: library, revBackground: "backgrounds/x.tscshadervid").apply(to: upper)
    #expect(upper.tracks[0].clips[0].metadata?["RevBackground"]?.string == "backgrounds/old.tscshadervid")
}

// MARK: Timeline rules [WizRec]

@MainActor @Test func shaderVidSourceTravelsWithTheClip() throws {
    let proj = try bgProject()
    try SetShaderVidSource(clipID: 10, path: library).apply(to: proj)
    try SplitClip(clipID: 10, at: 30).apply(to: proj)
    let halves = proj.tracks[0].clips.filter { $0.sourceID == 2 }
    #expect(halves.count == 2)
    #expect(halves.allSatisfy { $0.metadata?["ShaderVidSource"]?.string == library })
    try MoveClip(clipID: halves[1].id, toTrack: 0, start: 200).apply(to: proj)
    #expect(proj.tracks[0].clips.first { $0.id == halves[1].id }?.metadata?["ShaderVidSource"]?.string == library)
}

@MainActor @Test func revBackgroundStaysWithItsGroup() throws {
    // Deleting the background leaves the group's RevBackground; ungrouping drops it with the
    // group while the clip keeps ShaderVidSource.
    let deleted = try groupedProject(groupMD: revMD)
    try SetShaderVidSource(clipID: 10, path: library, revBackground: "backgrounds/new.tscshadervid").apply(to: deleted)
    try DeleteClips(clipIDs: [10]).apply(to: deleted)
    #expect(deleted.tracks[0].clips[0].metadata?["RevBackground"]?.string == "backgrounds/new.tscshadervid")

    let ungrouped = try groupedProject(groupMD: revMD)
    try SetShaderVidSource(clipID: 10, path: library, revBackground: "backgrounds/new.tscshadervid").apply(to: ungrouped)
    try UngroupClip(clipID: 20).apply(to: ungrouped)
    let text = String(decoding: ungrouped.serialized(), as: UTF8.self)
    #expect(!text.contains("RevBackground"))
    let bg = ungrouped.tracks.flatMap(\.clips).first { $0.id == 10 }
    #expect(bg?.metadata?["ShaderVidSource"]?.string == library)
}

// MARK: Against Camtasia's save

/// Removing the demo's `ShaderVidSource` and `RevBackground` and writing them back with the
/// demo's own values reproduces Camtasia's bytes (key order, positions).
@MainActor private func expectRewritesDemo(_ demo: Project) throws {
    let original = demo.serialized()
    var group: Clip?
    var bg: Clip?
    for t in demo.tracks {
        for c in t.clips {
            c.walk { inner, _ in
                if inner.kind.typeName == "Group", inner.metadata?["RevBackground"] != nil { group = inner }
                if inner.metadata?["ShaderVidSource"] != nil { bg = inner }
            }
        }
    }
    let g = try #require(group), b = try #require(bg)
    let path = try #require(b.metadata?["ShaderVidSource"]?.string)
    let rev = try #require(g.metadata?["RevBackground"]?.string)
    b.metadata?["ShaderVidSource"] = nil
    g.metadata?["RevBackground"] = nil
    #expect(demo.serialized() != original)
    try SetShaderVidSource(clipID: b.id, path: path, revBackground: rev).apply(to: demo)
    #expect(demo.serialized() == original)
    #expect(rev == "backgrounds/" + (path as NSString).lastPathComponent)
}

@MainActor @Test func rewritesDemoFixtureMetadata() throws {
    try expectRewritesDemo(try demoProject())
}

private let userDemo = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Documents/demo project.cmproj")

/// The same on the user's own demo: its `project.tscproj` copied to a temp folder (the
/// original is only read).
@MainActor @Test(.enabled(if: FileManager.default.fileExists(atPath: userDemo.path), "~/Documents/demo project.cmproj not present"))
func rewritesUserDemoMetadataOnACopy() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-demo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let copy = dir.appendingPathComponent("project.tscproj")
    try FileManager.default.copyItem(at: userDemo.appendingPathComponent("project.tscproj"), to: copy)
    try expectRewritesDemo(try Project(contentsOf: copy))
}
