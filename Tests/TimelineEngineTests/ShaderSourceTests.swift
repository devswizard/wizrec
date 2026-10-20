import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

// Shader background sources: `SetSourceEffectDef` and the clip `sourceEffect` InsertClip derives
// from it (`docs/specs/shader-backgrounds.md` §6, SH2 table).

private let shaderSource = """
{"id" : 2, "src" : "./media/1/bg.tscshadervid", "rect" : [0, 0, 1920, 1080], "sourceTracks" : [
 {"range" : [0, 9223372036854775807], "type" : 0, "editRate" : 30, "trackRect" : [0, 0, 1920, 1080], "numChannels" : 0}],
 "metadata" : {"timeAdded" : "kept"}}
"""

private let entries: [ShaderEffectDefEntry] = [
    .init(name: "Color0", type: "Color", scalingType: 3, unitType: 0, userInterfaceType: 6,
          defaultValue: .color([0.368627450980392, 0.0470588235294118, 0.733333333333333, 1])),
    .init(name: "Speed", type: "double", scalingType: 0, unitType: 0, userInterfaceType: 0,
          defaultValue: .double(2), minValue: .double(0), maxValue: .double(10)),
    .init(name: "Angle", type: "double", scalingType: 0, unitType: 3, userInterfaceType: 2,
          defaultValue: .double(0.7), minValue: .double(0), maxValue: .double(0)),
    .init(name: "Pos", type: "Position", scalingType: 1, unitType: 0, userInterfaceType: 5,
          defaultValue: .position([-5000, 5000, 0])),
    .init(name: "sourceFileType", type: "string", scalingType: 0, unitType: 0, userInterfaceType: 0,
          defaultValue: .string("tscshadervid"), minValue: .string(""), maxValue: .string("")),
]

private let effectDefJSON = """
[{"name" : "Color0", "type" : "Color", "defaultValue" : [0.368627450980392, 0.0470588235294118, 0.733333333333333, 1.0],
  "scalingType" : 3, "unitType" : 0, "userInterfaceType" : 6},
 {"name" : "Speed", "type" : "double", "defaultValue" : 2.0, "maxValue" : 10.0, "minValue" : 0.0,
  "scalingType" : 0, "unitType" : 0, "userInterfaceType" : 0},
 {"name" : "Angle", "type" : "double", "defaultValue" : 0.7, "maxValue" : 0.0, "minValue" : 0.0,
  "scalingType" : 0, "unitType" : 3, "userInterfaceType" : 2},
 {"name" : "Pos", "type" : "Position", "defaultValue" : [-5000.0, 5000.0, 0.0],
  "scalingType" : 1, "unitType" : 0, "userInterfaceType" : 5},
 {"name" : "sourceFileType", "type" : "string", "defaultValue" : "tscshadervid", "maxValue" : "", "minValue" : "",
  "scalingType" : 0, "unitType" : 0, "userInterfaceType" : 0}]
"""

private func linr(_ v: String, hints: String? = nil) -> String {
    let h = hints.map { #", "uiHints" : \#($0)"# } ?? ""
    return #"{"type" : "double", "defaultValue" : \#(v), "interp" : "linr"\#(h)}"#
}

@MainActor @Test func setSourceEffectDefWritesSH2Layout() throws {
    let p = try makeProject(tracks: tracks(track(0, [])), sourceBin: "[\(shaderSource)]")
    let set = SetSourceEffectDef(sourceID: 2, entries: entries)
    try expectReversible(set, on: p)
    try set.apply(to: p)
    let s = try #require(p.root["sourceBin"]?.array?[0].object)
    #expect(s.keys == ["id", "src", "rect", "sourceTracks", "effectDef", "metadata"])
    #expect(s["effectDef"] == (try JSON.parse(effectDefJSON)))
    #expect(s["metadata"] == (try JSON.parse(#"{"timeAdded" : "kept"}"#)))
    expectRejected(SetSourceEffectDef(sourceID: 9, entries: entries), on: p, .invalid(""))

    // Setting it again replaces in place (same key position).
    let again = SetSourceEffectDef(sourceID: 2, entries: Array(entries.suffix(1)))
    try expectReversible(again, on: p)
    try again.apply(to: p)
    #expect(p.root["sourceBin"]?.array?[0].object?.keys == ["id", "src", "rect", "sourceTracks", "effectDef", "metadata"])
    #expect(p.root["sourceBin"]?.array?[0].object?["effectDef"]?.array?.count == 1)
}

@MainActor @Test func insertFromShaderSourceWritesSourceEffect() throws {
    let p = try makeProject(tracks: tracks(track(0, [])), sourceBin: "[\(shaderSource)]")
    try SetSourceEffectDef(sourceID: 2, entries: entries).apply(to: p)
    let insert = InsertClip(sourceID: 2, track: 0, start: 0)
    try expectReversible(insert, on: p)
    try insert.apply(to: p)
    let c = try #require(p.tracks[0].clips.first)
    #expect(c.object.keys.prefix(7) == ["id", "_type", "src", "trackNumber", "attributes", "parameters", "sourceEffect"])
    let want = """
    {"effectName" : "SourceEffect", "bypassed" : false, "category" : "", "parameters" : {
      "Color0-red" : \(linr("0.368627450980392")), "Color0-green" : \(linr("0.0470588235294118")),
      "Color0-blue" : \(linr("0.733333333333333")), "Color0-alpha" : \(linr("1.0")),
      "Speed" : \(linr("2.0", hints: #"{"userInterfaceType" : 0, "unitType" : 0}"#)),
      "Angle" : \(linr("0.7", hints: #"{"userInterfaceType" : 2, "unitType" : 3}"#)),
      "Pos.x" : \(linr("-5000.0")), "Pos.y" : \(linr("5000.0")),
      "sourceFileType" : "tscshadervid"}}
    """
    #expect(c.object["sourceEffect"] == (try JSON.parse(want)))
    #expect(c.duration == 1800 && c.metadata?["default-scale"]?.string == "1")
    #expect(c.metadata?["lockAspectRatio"] == (try JSON.parse(#"{"type" : "bool", "value" : true}"#)))
}

@MainActor @Test func insertWithoutEffectDefWritesNoSourceEffect() throws {
    let p = try makeProject(tracks: tracks(track(0, [])), sourceBin: "[\(shaderSource)]")
    let insert = InsertClip(sourceID: 2, track: 0, start: 0)
    try insert.apply(to: p)
    #expect(p.tracks[0].clips.first?.object["sourceEffect"] == nil)
}

/// Against Camtasia's own save (the demo project's background): the same entries reproduce its
/// `effectDef` exactly, and a clip inserted from it gets the demo clip's `sourceEffect` values.
@MainActor @Test func matchesDemoProjectBackground() throws {
    let url = try #require(Bundle.module.url(forResource: "demo", withExtension: "tscproj", subdirectory: "Fixtures"))
    let demo = try Project(data: Data(contentsOf: url))
    let src = try #require(demo.source(id: 1)?.object)
    let demoDef = try #require(src["effectDef"])
    @Sendable func n(_ v: JSON?) -> Double { v?.double ?? .nan }
    let typed: [ShaderEffectDefEntry] = (demoDef.array?.items ?? []).compactMap(\.object).map { e in
        let v = e["defaultValue"]
        let value: ShaderEffectDefEntry.Value = switch e["type"]?.string {
        case "Color": .color((v?.array?.items ?? []).map { $0.double ?? .nan })
        case "string": .string(v?.string ?? "")
        default: .double(n(v))
        }
        func bound(_ b: JSON?) -> ShaderEffectDefEntry.Bound? {
            guard let b else { return nil }
            return b.string.map { .string($0) } ?? .double(n(b))
        }
        return ShaderEffectDefEntry(name: e["name"]?.string ?? "", type: e["type"]?.string ?? "",
                                    scalingType: Int(e["scalingType"]?.int ?? -1), unitType: Int(e["unitType"]?.int ?? -1),
                                    userInterfaceType: Int(e["userInterfaceType"]?.int ?? -1), defaultValue: value,
                                    minValue: bound(e["minValue"]), maxValue: bound(e["maxValue"]))
    }
    let stripped = src.copy()
    stripped["effectDef"] = nil
    let p = try makeProject(tracks: tracks(track(0, [])), sourceBin: "[\(String(decoding: JSON.object(stripped).serialized(), as: UTF8.self))]")
    try SetSourceEffectDef(sourceID: 1, entries: typed).apply(to: p)
    let written = try #require(p.root["sourceBin"]?.array?[0].object)
    #expect(written["effectDef"] == demoDef)
    #expect(written.keys == src.keys)

    let insert = InsertClip(sourceID: 1, track: 0, start: 0)
    try insert.apply(to: p)
    let mine = try #require(p.tracks[0].clips.first?.object["sourceEffect"]?.object?["parameters"]?.object)
    var theirs: JSONObject?
    func find(_ v: JSON) {
        if let o = v.object {
            if o["src"]?.int == 1, let se = o["sourceEffect"]?.object?["parameters"]?.object { theirs = se }
            o.entries.forEach { find($0.value) }
        } else { v.array?.items.forEach(find) }
    }
    find(.object(demo.root))
    let t = try #require(theirs)
    // Camtasia's re-save sorts these keys; a fresh drop lists them in file order [obs, SH2].
    #expect(Set(mine.keys) == Set(t.keys))
    for k in t.keys { #expect(mine[k] == t[k], "\(k)") }
}
