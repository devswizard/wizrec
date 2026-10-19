import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

// MARK: - Building small projects

/// A minimal project with `editRate` 30 (one tick per frame, as in format
/// ≤ 3.0 projects) so expected values stay readable. `tracks` is the JSON
/// text of the scene's `tracks` array.
@MainActor
func makeProject(tracks: String, sourceBin: String = "[]") throws -> Project {
    let text = """
    {"title" : "t", "editRate" : 30, "sourceBin" : \(sourceBin),
     "timeline" : {"id" : 1, "sceneTrack" : {"scenes" : [{"csml" : {"tracks" : \(tracks)}}]},
                   "trackAttributes" : []}}
    """
    return try Project(data: Data(text.utf8))
}

/// JSON text of a leaf clip. Number arguments are raw lexemes, so pass
/// `"\"11425/76\""` for a rational string or `"0.0"` for a double.
func leaf(_ id: Int64, type: String = "VMFile", start: Int64, dur: Int64, ms: String = "0",
          md: String? = nil, scalar: String = "1", src: Int = 1, trackNumber: Int = 0,
          parameters: String = "{}", effects: String = "[]", anim: String = "{}") -> String {
    """
    {"id" : \(id), "_type" : "\(type)", "src" : \(src), "trackNumber" : \(trackNumber), \
    "start" : \(start), "duration" : \(dur), "mediaStart" : \(ms), "mediaDuration" : \(md ?? String(dur)), \
    "scalar" : \(scalar), "parameters" : \(parameters), "effects" : \(effects), \
    "metadata" : {"note" : "kept"}, "animationTracks" : \(anim)}
    """
}

func track(_ index: Int, _ medias: [String], transitions: String? = nil) -> String {
    let t = transitions.map { #", "transitions" : \#($0)"# } ?? ""
    return #"{"trackIndex" : \#(index), "medias" : [\#(medias.joined(separator: ", "))]\#(t), "parameters" : {}}"#
}

func tracks(_ ts: String...) -> String { "[" + ts.joined(separator: ", ") + "]" }

// MARK: - Reading results

func sceneTracks(_ p: Project) -> JSON {
    JSONPath.sceneTracks.resolve(in: p.root) ?? .null
}

/// Expects the scene's tracks to equal `expected` structurally (keys, key
/// order, number lexemes), printing both on mismatch.
func expectTracks(_ p: Project, _ expected: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let want = try JSON.parse(expected)
    let got = sceneTracks(p)
    #expect(got == want, """
        tracks differ.
        got:
        \(String(decoding: got.serialized(), as: UTF8.self))
        want:
        \(String(decoding: want.serialized(), as: UTF8.self))
        """, sourceLocation: sourceLocation)
}

/// Applies, reverts, re-applies and reverts `command`, expecting the revert
/// to reproduce the original serialisation byte for byte and the re-apply to
/// reproduce the first result. Leaves the project in its original state.
@MainActor
func expectReversible(_ command: any EditCommand, on p: Project,
                      sourceLocation: SourceLocation = #_sourceLocation) throws {
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

/// Expects `apply` to throw `error` and leave the project byte-identical.
@MainActor
func expectRejected(_ command: any EditCommand, on p: Project, _ error: EditError? = nil,
                    sourceLocation: SourceLocation = #_sourceLocation) {
    let before = p.serialized()
    do {
        try command.apply(to: p)
        Issue.record("expected \(command.name) to throw", sourceLocation: sourceLocation)
    } catch let e as EditError {
        if let error {
            if case .invalid = error, case .invalid = e {} else {
                #expect(e == error, sourceLocation: sourceLocation)
            }
        }
    } catch {
        Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
    }
    #expect(p.serialized() == before, "project changed after a failed apply", sourceLocation: sourceLocation)
}

/// Every `id` in the document, in tree order.
func allIDs(_ p: Project) -> [Int64] {
    var ids: [Int64] = []
    func walk(_ v: JSON) {
        if let o = v.object {
            if let id = o["id"]?.int { ids.append(id) }
            o.entries.forEach { walk($0.value) }
        } else if let a = v.array { a.items.forEach(walk) }
    }
    walk(.object(p.root))
    return ids
}

// MARK: - Fixture

func demoProject() throws -> Project {
    let url = try #require(Bundle.module.url(forResource: "demo.tscproj", withExtension: nil,
                                              subdirectory: "Fixtures"))
    return try Project(contentsOf: url)
}
