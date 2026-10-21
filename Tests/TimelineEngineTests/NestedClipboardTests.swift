import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

// Copying clips selected inside an open group, pasting at top level and into
// another open group (TL10-1).

private func innerTrack(_ i: Int, _ medias: [String], transitions: String? = nil, magnetic: Bool = false) -> String {
    let t = transitions.map { #", "transitions" : \#($0)"# } ?? ""
    return #"{"trackIndex" : \#(i), "medias" : [\#(medias.joined(separator: ", "))]\#(t), "parameters" : {}, "ident" : "", "audioMuted" : false, "videoHidden" : false, "magnetic" : \#(magnetic), "matte" : 0, "solo" : false}"#
}

private func group(_ id: Int64, start: Int64, dur: Int64, ms: String = "0.0", md: String, scalar: String = "1",
                   metadata: String = "{}", _ tracks: [String]) -> String {
    """
    {"id" : \(id), "_type" : "Group", "tracks" : [\(tracks.joined(separator: ", "))], "start" : \(start), \
    "duration" : \(dur), "mediaStart" : \(ms), "mediaDuration" : \(md), "scalar" : \(scalar), "metadata" : \(metadata)}
    """
}

private let kf = #"{"translation0" : {"type" : "double", "defaultValue" : 0.0, "keyframes" : [{"endTime" : 10, "time" : 0, "value" : 5.0, "interp" : "eioe", "duration" : 10}]}}"#
private let fx = #"[{"effectName" : "DropShadow", "parameters" : {"opacity" : 0.5}}]"#
private let bin = #"[{"id" : 1, "src" : "./media/1/a.mp4", "sourceTracks" : []}]"#

/// 31 (keyframes, effect) and 33 with a Fade, and 32 above, inside group 30
/// (timeline 500–700, inner window 10–210, Rev metadata).
private func groupA(_ c31: String = leaf(31, start: 20, dur: 50, parameters: kf, effects: fx),
                    c33: String = leaf(33, start: 70, dur: 30), c32: String = leaf(32, start: 40, dur: 30)) -> String {
    group(30, start: 500, dur: 200, ms: "10.0", md: "200.0", metadata: #"{"RevBackground" : "backgrounds/x.tscshadervid"}"#, [
        innerTrack(0, [c31, c33], transitions: #"[{"name" : "Fade", "duration" : 5, "leftMedia" : 31, "rightMedia" : 33}]"#),
        innerTrack(1, [c32]),
    ])
}

@MainActor private func projectA(extra: [String] = [track(1, []), track(2, [])]) throws -> Project {
    let p = try projectWithAttributes([track(0, [leaf(10, start: 0, dur: 100), groupA()])] + extra)
    p.root["sourceBin"] = try JSON.parse(bin)
    return p
}

@MainActor @Test func copyInsideGroupUsesTimelineOffsetsAndKeepsClipKeys() throws {
    let p = try projectA()
    let payload = try ClipboardPayload.copy(clipIDs: [32, 31, 33], from: p)
    let doc = try #require(try JSON.parse(payload.data).object)
    // Timeline starts 510, 560 (track 0) and 530 (track 1): offsets from 510.
    let items = doc["items"]?.array?.items.compactMap(\.object) ?? []
    let layout: [[Int64]] = items.map { (o: JSONObject) -> [Int64] in
        [o["track"]?.int ?? -1, o["start"]?.int ?? -1, o["clip"]?.object?.clipID ?? -1]
    }
    let want: [[Int64]] = [[0, 0, 31], [0, 50, 33], [1, 20, 32]]
    #expect(layout == want)
    #expect(items.first?["clip"] == (try JSON.parse(leaf(31, start: 20, dur: 50, parameters: kf, effects: fx))))
    #expect(doc["transitions"] == (try JSON.parse(#"[{"track" : 0, "transition" : {"name" : "Fade", "duration" : 5, "leftMedia" : 31, "rightMedia" : 33}}]"#)))
    #expect(doc["sources"] == (try JSON.parse(bin)))
    // Group-level keys stay with the group.
    #expect(!String(decoding: payload.data, as: UTF8.self).contains("RevBackground"))
    // A selection spanning containers is refused.
    #expect(throws: EditError.self) { try ClipboardPayload.copy(clipIDs: [10, 31], from: p) }
    #expect(throws: EditError.self) { try ClipboardPayload.copy(clipIDs: [30, 31], from: p) }
}

@MainActor @Test func pasteNestedCopyAtTopLevel() throws {
    let p = try projectA()
    let payload = try ClipboardPayload.copy(clipIDs: [31, 33, 32], from: p)
    let paste = PasteClips(payload, track: 1, at: 1000)
    try expectReversible(paste, on: p)
    try paste.apply(to: p)
    #expect(paste.pastedIDs == [34, 35, 36])
    try expectTracks(p, tracks(
        track(0, [leaf(10, start: 0, dur: 100), groupA()]),
        track(1, [leaf(34, start: 1000, dur: 50, parameters: kf, effects: fx), leaf(35, start: 1050, dur: 30)],
              transitions: #"[{"name" : "Fade", "duration" : 5, "leftMedia" : 34, "rightMedia" : 35}]"#),
        track(2, [leaf(36, start: 1020, dur: 30)])
    ))
    #expect(p.sourceBin.count == 1)
    // Round trip stays lossless.
    #expect(try Project(data: p.serialized()).serialized() == p.serialized())
}

@MainActor @Test func pasteNestedCopyIntoAnotherOpenGroup() throws {
    // Group 40 on track 1 (timeline 200–260, inner window 0–60). The paste never grows it
    // (group-edits.md §8.3): 42 runs past the window and is hidden.
    let g40 = { (t0: [String], t1: [String], dur: Int64, md: String, tr: String?) -> String in
        group(40, start: 200, dur: dur, md: md, [innerTrack(0, t0, transitions: tr), innerTrack(1, t1)])
    }
    let p = try projectA(extra: [track(1, [g40([], [], 60, "60.0", nil)])])
    let payload = try ClipboardPayload.copy(clipIDs: [31, 33, 32], from: p)
    let paste = PasteClips(payload, group: 40, track: 0, at: .timeline(210))
    try expectReversible(paste, on: p)
    try paste.apply(to: p)
    #expect(paste.pastedIDs == [41, 42, 43] && paste.groupID == 40 && paste.start == 210)
    let fade = #"[{"name" : "Fade", "duration" : 5, "leftMedia" : 41, "rightMedia" : 42}]"#
    try expectTracks(p, tracks(
        track(0, [leaf(10, start: 0, dur: 100), groupA()]),
        track(1, [g40([leaf(41, start: 10, dur: 50, parameters: kf, effects: fx), leaf(42, start: 60, dur: 30)],
                      [leaf(43, start: 30, dur: 30)], 60, "60.0", fade)])
    ))
    // The same paste addressed in inner time gives the same JSON.
    let after = p.serialized()
    try paste.revert(on: p)
    let inner = PasteClips(payload, group: 40, track: 0, at: .inner(10))
    try inner.apply(to: p)
    #expect(p.serialized() == after)
    try inner.revert(on: p)

    // Into the source group itself, after its content: inner track 0 at inner 110.
    let back = PasteClips(payload, group: 30, track: 0, at: .inner(110))
    try expectReversible(back, on: p)
    try back.apply(to: p)
    let g = try #require(p.tracks[0].clips.last)
    #expect(g.tracks.map { $0.clips.map { [$0.id, $0.start] } } == [[[31, 20], [33, 70], [41, 110], [42, 160]], [[32, 40], [43, 130]]])
    #expect(g.duration == 200 && g.object["mediaDuration"]?.number?.lexeme == "200.0")  // ends at 190 ≤ 210
    #expect(g.object["metadata"] == (try JSON.parse(#"{"RevBackground" : "backgrounds/x.tscshadervid"}"#)))
}

@MainActor @Test func groupPasteMapsOffsetsThroughGroupSpeed() throws {
    // Group 40 at half speed (scalar 2): timeline 200 + 2 × inner.
    let g40 = group(40, start: 200, dur: 200, md: "100.0", scalar: "2", [innerTrack(0, []), innerTrack(1, [])])
    let p = try projectA(extra: [track(1, [g40])])
    let payload = try ClipboardPayload.copy(clipIDs: [31, 32], from: p)  // offsets 0 and 20 (track 1)
    let paste = PasteClips(payload, group: 40, track: 0, at: .timeline(260))
    try expectReversible(paste, on: p)
    try paste.apply(to: p)
    let g = try #require(p.tracks[1].clips.first)
    // Anchor inner 30; 32 at timeline 280 → inner 40. Clips keep their own duration and scalar.
    #expect(g.tracks.map { $0.clips.map { [$0.id, $0.start, $0.duration] } } == [[[41, 30, 50]], [[42, 40, 30]]])
}

@MainActor @Test func groupPasteMagneticInnerTrackAndRejections() throws {
    let g40 = group(40, start: 200, dur: 100, md: "100.0", [
        innerTrack(0, [leaf(41, start: 0, dur: 20), leaf(42, start: 20, dur: 20)], magnetic: true),
        innerTrack(1, [leaf(43, start: 0, dur: 100)]),
    ])
    let p = try projectA(extra: [track(1, [g40]), track(2, [leaf(50, start: 400, dur: 10)])])
    let one = try ClipboardPayload.copy(clipIDs: [33], from: p)
    let mag = PasteClips(one, group: 40, track: 0, at: .inner(15))  // before 42's midpoint
    try expectReversible(mag, on: p)
    try mag.apply(to: p)
    let g = try #require(p.tracks[1].clips.first)
    #expect(g.tracks[0].clips.map { [$0.id, $0.start] } == [[41, 0], [51, 20], [42, 50]])
    try mag.revert(on: p)

    expectRejected(PasteClips(one, group: 40, track: 1, at: .inner(50)), on: p, .invalid(""))   // overlaps 43
    expectRejected(PasteClips(one, group: 40, track: 2, at: .inner(0)), on: p, .trackNotFound(2))
    expectRejected(PasteClips(one, group: 10, track: 0, at: .inner(0)), on: p, .invalid(""))      // not a group
    // Two-track payload whose second track does not exist in the group.
    let two = try ClipboardPayload.copy(clipIDs: [31, 32], from: p)
    expectRejected(PasteClips(two, group: 40, track: 1, at: .inner(0)), on: p, .trackNotFound(2))
}

// MARK: - Demo project

/// The demo's Rev group is closed (TL11-5): its background can't be copied out and nothing
/// pastes into it. With `groupType` removed (a plain group), the background copies out with
/// `ShaderVidSource`, pastes at top level and back into the group without growing it,
/// checking keys, undo and round trip.
@MainActor private func expectNestedCopyOnDemo(_ demo: Project) throws {
    let original = demo.serialized()
    let g = try #require(demo.tracks.first?.clips.first { $0.kind == .group })
    let bg = try #require(g.tracks.first?.clips.first)
    #expect(g.object["metadata"]?.object?["groupType"]?.string == "revMedia")
    #expect(throws: EditError.self) { try ClipboardPayload.copy(clipIDs: [bg.id], from: demo) }
    let whole = try ClipboardPayload.copy(clipIDs: [g.id], from: demo)
    expectRejected(PasteClips(whole, group: g.id, at: .inner(bg.start)), on: demo, .invalid(""))
    #expect(demo.serialized() == original)

    // As a plain group.
    g.object["metadata"]?.object?["groupType"] = nil
    let plain = demo.serialized()
    let payload = try ClipboardPayload.copy(clipIDs: [bg.id], from: demo)
    let text = String(decoding: payload.data, as: UTF8.self)
    #expect(text.contains("ShaderVidSource") && !text.contains("RevBackground") && !text.contains("RevLook"))

    // Top level: on an empty track after the end.
    let top = try #require(demo.tracks.indices.last { demo.tracks[$0].clips.isEmpty })
    let maxBefore = demo.maxID
    let paste = PasteClips(payload, track: top, at: demo.duration)
    try expectReversible(paste, on: demo)
    try paste.apply(to: demo)
    let pasted = try #require(demo.tracks[top].clips.first)
    #expect(pasted.id > maxBefore && pasted.start == demo.duration - bg.duration)
    let copy = bg.object.copy(), got = pasted.object.copy()
    for o in [copy, got] { o["id"] = nil; o["start"] = nil }
    #expect(JSON.object(copy) == JSON.object(got))  // keyframes, effects, sourceEffect, metadata kept
    #expect(try Project(data: demo.serialized()).serialized() == demo.serialized())
    try paste.revert(on: demo)

    // Into the group, right after the clip: inner track 0, the group doesn't grow.
    let end = bg.start + bg.duration
    let inner = PasteClips(payload, group: g.id, at: .inner(end))
    try expectReversible(inner, on: demo)
    try inner.apply(to: demo)
    let g2 = try #require(demo.tracks.first?.clips.first { $0.id == g.id })
    #expect(inner.pastedTracks == [0])
    #expect(g2.tracks[0].clips.map(\.start) == [bg.start, end])
    #expect(g2.duration == g.duration && g2.object["mediaDuration"] == g.object["mediaDuration"])
    #expect(g2.object["metadata"] == g.object["metadata"])
    #expect(try Project(data: demo.serialized()).serialized() == demo.serialized())
    try inner.revert(on: demo)
    #expect(demo.serialized() == plain)
}

@MainActor @Test func nestedCopyPasteOnDemoFixture() throws {
    try expectNestedCopyOnDemo(try demoProject())
}

private let userDemo = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Documents/demo project.cmproj")

/// The same on the user's own demo: its `project.tscproj` copied to a temp folder (the
/// original is only read).
@MainActor @Test(.enabled(if: FileManager.default.fileExists(atPath: userDemo.path), "~/Documents/demo project.cmproj not present"))
func nestedCopyPasteOnUserDemoCopy() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-demo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let copy = dir.appendingPathComponent("project.tscproj")
    try FileManager.default.copyItem(at: userDemo.appendingPathComponent("project.tscproj"), to: copy)
    try expectNestedCopyOnDemo(try Project(contentsOf: copy))
}
