import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

// Copy/paste with groups as Camtasia does it (docs/specs/group-edits.md §8,
// session 8): canvas-space transforms (TL11-1), the paste window clamp, track
// choice and no growth (TL11-2), Rev media closed (TL11-5). editRate 30, so
// 1 s = 30 ticks.

private func long(_ v: String) -> String { #"{"type" : "double", "defaultValue" : \#(v), "interp" : "eioe"}"# }

private func still(_ id: Int64, start: Int64, dur: Int64, params: String = "{}") -> String {
    """
    {"id" : \(id), "_type" : "IMFile", "src" : 1, "trackNumber" : 0, "trimStartSum" : 0, \
    "parameters" : \(params), "effects" : [], "start" : \(start), "duration" : \(dur), \
    "mediaStart" : 0, "mediaDuration" : 1, "scalar" : 1, "metadata" : {}, "animationTracks" : {}}
    """
}

private func innerTrack(_ i: Int, _ medias: [String]) -> String {
    #"{"trackIndex" : \#(i), "medias" : [\#(medias.joined(separator: ", "))], "parameters" : {}, "ident" : "", "audioMuted" : false, "videoHidden" : false, "magnetic" : false, "matte" : 0, "solo" : false}"#
}

private func group(_ id: Int64, start: Int64 = 0, dur: Int64 = 300, ms: String = "0.0", md: String = "300.0",
                   params: String = "{}", metadata: String = #"{"isOpen" : true}"#, _ tracks: [String]) -> String {
    """
    {"id" : \(id), "_type" : "Group", "parameters" : \(params), "tracks" : [\(tracks.joined(separator: ", "))], \
    "attributes" : {"ident" : "Group 1"}, "effects" : [], "start" : \(start), "duration" : \(dur), \
    "mediaStart" : \(ms), "mediaDuration" : \(md), "scalar" : 1, "metadata" : \(metadata), "animationTracks" : {}}
    """
}

private let bin = #"[{"id" : 1, "src" : "./media/1/still.png", "rect" : [0, 0, 1600, 900], "sourceTracks" : []}]"#

/// Track 0: group 20 (X 200, 50 %; photo 21 at identity, 22 at X 150). Track 1: identity
/// group 30 with 31 filling its window. Track 2: group 40 at X 1, empty. Track 3: still 50
/// (top level, identity). Track 4: empty.
@MainActor private func transformProject() throws -> Project {
    let g20 = group(20, params: #"{"translation0" : 200.0, "scale0" : 0.5, "scale1" : 0.5}"#, [
        innerTrack(0, [still(21, start: 0, dur: 150)]),
        innerTrack(1, [still(22, start: 0, dur: 150, params: #"{"translation0" : 150.0}"#)]),
    ])
    let g30 = group(30, [innerTrack(0, [still(31, start: 0, dur: 300)])])
    let g40 = group(40, params: #"{"translation0" : 1.0}"#, [innerTrack(0, [])])
    let p = try projectWithAttributes([track(0, [g20]), track(1, [g30]), track(2, [g40]),
                                       track(3, [still(50, start: 0, dur: 30)]), track(4, [])])
    p.root["sourceBin"] = try JSON.parse(bin)
    return p
}

@MainActor private func expectLossless(_ p: Project, sourceLocation: SourceLocation = #_sourceLocation) throws {
    #expect(try Project(data: p.serialized()).serialized() == p.serialized(), sourceLocation: sourceLocation)
}

@MainActor private func params(_ p: Project, _ id: Int64) throws -> JSON {
    let loc = try Locator.locate(id, in: p)
    return loc.clip["parameters"] ?? .null
}

@MainActor private func group(_ p: Project, _ id: Int64) throws -> JSONObject {
    try Locator.locate(id, in: p).clip
}

// MARK: - TL11-1 transforms in canvas space

@MainActor @Test func copyOutOfScaledGroupPastesAtCanvasTransform() throws {
    let p = try transformProject()
    let payload = try ClipboardPayload.copy(clipIDs: [21], from: p)
    let doc = try #require(try JSON.parse(payload.data).object)
    #expect(doc["wizrecClipboard"]?.int == 2)
    #expect(doc["space"] == (try JSON.parse("[200.0, 0.0, 0.5, 0.5]")))
    // The stored clip is the project's own (identity) copy.
    #expect(doc["items"]?.array?[0].object?["clip"]?.object?["parameters"] == (try JSON.parse("{}")))

    let paste = PasteClips(payload, track: 4, at: 400)
    try expectReversible(paste, on: p)
    try paste.apply(to: p)
    let id = try #require(paste.pastedIDs.first)
    // g5-paste-top: scale 0.5 and X 200, long form, canonical order.
    #expect(try params(p, id) == (try JSON.parse(
        #"{"translation0" : \#(long("200.0")), "scale0" : \#(long("0.5")), "scale1" : \#(long("0.5"))}"#)))
    try expectLossless(p)
}

@MainActor @Test func copyOutOfGroupComposesChildPositionAndKeyframes() throws {
    let p = try transformProject()
    let payload = try ClipboardPayload.copy(clipIDs: [22], from: p)
    let paste = PasteClips(payload, track: 4, at: 400)
    try paste.apply(to: p)
    // 200 + 0.5 × 150 = 275 (the §6 ungroup rule); the bare value becomes long form in place.
    #expect(try params(p, try #require(paste.pastedIDs.first)) == (try JSON.parse(
        #"{"translation0" : \#(long("275.0")), "scale0" : \#(long("0.5")), "scale1" : \#(long("0.5"))}"#)))

    // Keyframed child position: defaultValue and every keyframe value are mapped.
    let kf = #"{"translation0" : {"type" : "double", "defaultValue" : 0.0, "keyframes" : [{"endTime" : 10, "time" : 0, "value" : 10.0, "duration" : 10}]}}"#
    let g = group(60, params: #"{"translation0" : 200.0, "scale0" : 0.5, "scale1" : 0.5}"#,
                  [innerTrack(0, [still(61, start: 0, dur: 30, params: kf)])])
    let q = try projectWithAttributes([track(0, [g]), track(1, [])])
    q.root["sourceBin"] = try JSON.parse(bin)
    let out = PasteClips(try ClipboardPayload.copy(clipIDs: [61], from: q), track: 1, at: 0)
    try expectReversible(out, on: q)
    try out.apply(to: q)
    let want = #"{"translation0" : {"type" : "double", "defaultValue" : 200.0, "keyframes" : [{"endTime" : 10, "time" : 0, "value" : 205.0, "duration" : 10}]}, "scale0" : \#(long("0.5")), "scale1" : \#(long("0.5"))}"#
    #expect(try params(q, try #require(out.pastedIDs.first)) == (try JSON.parse(want)))
}

@MainActor @Test func pasteBackIntoOwnGroupIsIdentityAgain() throws {
    let p = try transformProject()
    let before = try group(p, 20).copy()
    let payload = try ClipboardPayload.copy(clipIDs: [21], from: p)
    let paste = PasteClips(payload, group: 20, at: .inner(150))
    try expectReversible(paste, on: p)
    try paste.apply(to: p)
    let id = try #require(paste.pastedIDs.first)
    #expect(paste.pastedTracks == [0])
    // Bytes of the original clip, new id and start.
    let want = still(id, start: 150, dur: 150)
    #expect(JSON.object(try Locator.locate(id, in: p).clip) == (try JSON.parse(want)))
    let g = try group(p, 20)
    #expect(g["duration"] == before["duration"] && g["mediaDuration"] == before["mediaDuration"])
    #expect(g["parameters"] == before["parameters"])
    try expectLossless(p)
}

@MainActor @Test func pasteIntoOtherGroupsReexpressesTransform() throws {
    let p = try transformProject()
    // Into the identity group: keeps scale 0.5 and X 200 (g6). Inner track 0 is busy → new track 1.
    let fromG20 = try ClipboardPayload.copy(clipIDs: [21], from: p)
    let into30 = PasteClips(fromG20, group: 30, at: .inner(0))
    try expectReversible(into30, on: p)
    try into30.apply(to: p)
    let a = try #require(into30.pastedIDs.first)
    #expect(into30.pastedTracks == [1])
    #expect(try params(p, a) == (try JSON.parse(
        #"{"translation0" : \#(long("200.0")), "scale0" : \#(long("0.5")), "scale1" : \#(long("0.5"))}"#)))
    let g30 = try group(p, 30)
    #expect(g30["tracks"]?.array?.count == 2)
    #expect(g30["tracks"]?.array?[1] == .object(ProjectTemplate.groupTrack(index: 1)).withMedias([still(a, start: 0, dur: 150, params: #"{"translation0" : \#(long("200.0")), "scale0" : \#(long("0.5")), "scale1" : \#(long("0.5"))}"#)]))
    try into30.revert(on: p)

    // A top-level clip at X 0 pasted into the group at X 1 gets X −1 (rev5-plain-group).
    let top = try ClipboardPayload.copy(clipIDs: [50], from: p)
    #expect(try JSON.parse(top.data).object?["space"] == nil)
    let into40 = PasteClips(top, group: 40, at: .inner(0))
    try expectReversible(into40, on: p)
    try into40.apply(to: p)
    #expect(try params(p, try #require(into40.pastedIDs.first)) == (try JSON.parse(#"{"translation0" : \#(long("-1.0"))}"#)))
    try expectLossless(p)
}

@MainActor @Test func versionOnePayloadKeepsItsTransform() throws {
    let p = try transformProject()
    let doc = try #require(try JSON.parse(try ClipboardPayload.copy(clipIDs: [21], from: p).data).object)
    doc["wizrecClipboard"] = .number(JSONNumber(Int64(1)))
    doc["space"] = nil
    let legacy = try ClipboardPayload(data: JSON.object(doc).serialized())
    for paste in [PasteClips(legacy, track: 4, at: 400), PasteClips(legacy, group: 40, at: .inner(0))] {
        try expectReversible(paste, on: p)
        try paste.apply(to: p)
        #expect(try params(p, try #require(paste.pastedIDs.first)) == (try JSON.parse("{}")))
        try paste.revert(on: p)
    }
}

/// [WizRec] Only a group's constant position and scale are composed: rotation, opacity and
/// the keyframes of an animated group position are not carried to the copy.
@MainActor @Test func copyComposesOnlyConstantGroupPositionAndScale() throws {
    let animated = #"{"type" : "double", "defaultValue" : 100.0, "keyframes" : [{"endTime" : 10, "time" : 0, "value" : 300.0, "duration" : 10}]}"#
    let gp = #"{"translation0" : \#(animated), "rotation2" : 0.5, "scale0" : 2.0, "scale1" : 2.0, "opacity" : 0.5}"#
    let p = try projectWithAttributes([track(0, [group(60, params: gp, [innerTrack(0, [still(61, start: 0, dur: 30)])])]),
                                       track(1, [])])
    p.root["sourceBin"] = try JSON.parse(bin)
    let payload = try ClipboardPayload.copy(clipIDs: [61], from: p)
    #expect(try JSON.parse(payload.data).object?["space"] == (try JSON.parse("[100.0, 0.0, 2.0, 2.0]")))
    let paste = PasteClips(payload, track: 1, at: 0)
    try paste.apply(to: p)
    #expect(try params(p, try #require(paste.pastedIDs.first)) == (try JSON.parse(
        #"{"translation0" : \#(long("100.0")), "scale0" : \#(long("2.0")), "scale1" : \#(long("2.0"))}"#)))
}

@MainActor @Test func nestedGroupsComposeOuterThenInner() throws {
    // Outer 70 (X 100, 50 %) holds inner 71 (X 40, 50 %) holding 72 (X 8).
    let inner = group(71, params: #"{"translation0" : 40.0, "scale0" : 0.5, "scale1" : 0.5}"#,
                      [innerTrack(0, [still(72, start: 0, dur: 30, params: #"{"translation0" : 8.0}"#)])])
    let outer = group(70, params: #"{"translation0" : 100.0, "scale0" : 0.5, "scale1" : 0.5}"#, [innerTrack(0, [inner])])
    let p = try projectWithAttributes([track(0, [outer]), track(1, [])])
    p.root["sourceBin"] = try JSON.parse(bin)
    let payload = try ClipboardPayload.copy(clipIDs: [72], from: p)
    // Canvas: 100 + 0.5 × (40 + 0.5 × 8) = 122; scale 0.25.
    #expect(try JSON.parse(payload.data).object?["space"] == (try JSON.parse("[120.0, 0.0, 0.25, 0.25]")))
    let top = PasteClips(payload, track: 1, at: 0)
    try top.apply(to: p)
    #expect(try params(p, try #require(top.pastedIDs.first)) == (try JSON.parse(
        #"{"translation0" : \#(long("122.0")), "scale0" : \#(long("0.25")), "scale1" : \#(long("0.25"))}"#)))
    try top.revert(on: p)
    // Back into the inner group (after 72): identity again.
    let back = PasteClips(payload, group: 71, at: .inner(30))
    try expectReversible(back, on: p)
    try back.apply(to: p)
    #expect(try params(p, try #require(back.pastedIDs.first)) == (try JSON.parse(#"{"translation0" : 8.0}"#)))
}

// MARK: - TL11-2 paste into an open group

/// Group 80 at 14 s (420) with `mediaStart` 2 s (60), window 2–10 s; inner track 0 busy over
/// the whole window, track 1 busy 2–5 s. Track 1: still 90 (1 s) to copy. Track 2: empty.
@MainActor private func windowProject() throws -> Project {
    let g = group(80, start: 420, dur: 240, ms: "60.0", md: "240.0", [
        innerTrack(0, [still(81, start: 60, dur: 240)]),
        innerTrack(1, [still(82, start: 60, dur: 90)]),
    ])
    let p = try projectWithAttributes([track(0, [g]), track(1, [still(90, start: 0, dur: 30)]), track(2, [])])
    p.root["sourceBin"] = try JSON.parse(bin)
    return p
}

@MainActor private func innerLayout(_ p: Project, _ gid: Int64) throws -> [[[Int64]]] {
    let g = try group(p, gid)
    return (g["tracks"]?.array?.items ?? []).map { t in
        trackClips(t.object ?? JSONObject()).map { [$0.clipID ?? -1, $0["start"]?.int ?? -1, $0["duration"]?.int ?? -1] }
    }
}

@MainActor @Test func groupPasteMapsPlayheadAndPicksLowestFreeTrack() throws {
    let p = try windowProject()
    let payload = try ClipboardPayload.copy(clipIDs: [90], from: p)
    let before = try group(p, 80).copy()
    // Playhead 16 s on the group at 14 s with mediaStart 2 s → inner 4 s (g9). Track 1 is busy
    // until 5 s, track 0 throughout → a new inner track 2.
    let a = PasteClips(payload, group: 80, at: .timeline(480))
    try expectReversible(a, on: p)
    try a.apply(to: p)
    #expect(try innerLayout(p, 80) == [[[81, 60, 240]], [[82, 60, 90]], [[91, 120, 30]]])
    #expect(a.pastedTracks == [2])
    try a.revert(on: p)
    // Playhead 18 s → inner 6 s: track 1 is free there.
    let b = PasteClips(payload, group: 80, at: .timeline(540))
    try expectReversible(b, on: p)
    try b.apply(to: p)
    #expect(try innerLayout(p, 80) == [[[81, 60, 240]], [[82, 60, 90], [91, 180, 30]]])
    let g = try group(p, 80)
    for k in ["start", "duration", "mediaStart", "mediaDuration"] { #expect(g[k] == before[k], "\(k)") }
    try expectLossless(p)
}

@MainActor @Test func groupPasteClampsToWindowAndNeverGrows() throws {
    let p = try windowProject()
    let payload = try ClipboardPayload.copy(clipIDs: [90], from: p)
    let before = try group(p, 80).copy()
    // Playhead 5 s, before the group: lands at the window start, inner 2 s (g10).
    let early = PasteClips(payload, group: 80, at: .timeline(150))
    try expectReversible(early, on: p)
    try early.apply(to: p)
    #expect(try innerLayout(p, 80)[2] == [[91, 60, 30]])
    try early.revert(on: p)
    // At the group's end (22 s → inner 10 s) and past it: inner 10 s, hidden; no growth (g4).
    for t in [Int64(660), 900] {
        let late = PasteClips(payload, group: 80, at: .timeline(t))
        try expectReversible(late, on: p)
        try late.apply(to: p)
        let layout = try innerLayout(p, 80)
        #expect(layout[0] == [[81, 60, 240], [91, 300, 30]], "playhead \(t)")
        let g = try group(p, 80)
        for k in ["start", "duration", "mediaStart", "mediaDuration"] { #expect(g[k] == before[k], "\(k)") }
        try late.revert(on: p)
    }
    // Inner times clamp the same way.
    let inner = PasteClips(payload, group: 80, at: .inner(0))
    try expectReversible(inner, on: p)
    try inner.apply(to: p)
    #expect(try innerLayout(p, 80)[2] == [[91, 60, 30]])
}

@MainActor @Test func groupPasteFixedTrackClampsWithoutGrowing() throws {
    let p = try windowProject()
    let payload = try ClipboardPayload.copy(clipIDs: [90], from: p)
    let before = try group(p, 80).copy()
    // Past the window on a fixed inner track: clamped to inner 10 s; overlaps still throw.
    let late = PasteClips(payload, group: 80, track: 1, at: .inner(400))
    try expectReversible(late, on: p)
    try late.apply(to: p)
    #expect(try innerLayout(p, 80)[1] == [[82, 60, 90], [91, 300, 30]])
    #expect(try group(p, 80)["duration"] == before["duration"])
    try late.revert(on: p)
    expectRejected(PasteClips(payload, group: 80, track: 1, at: .inner(0)), on: p, .invalid(""))  // clamps to 2 s: overlaps 82
}

@MainActor @Test func groupPasteKeepsPayloadTrackOrder() throws {
    // Two clips on two tracks; group 80's track 0 is busy, track 1 busy 2–5 s.
    let p = try projectWithAttributes([
        track(0, [group(80, start: 420, dur: 240, ms: "60.0", md: "240.0", [
            innerTrack(0, [still(81, start: 60, dur: 240)]), innerTrack(1, [still(82, start: 60, dur: 90)]),
        ])]),
        track(1, [still(90, start: 0, dur: 30)]), track(2, [still(92, start: 0, dur: 30)]),
    ])
    p.root["sourceBin"] = try JSON.parse(bin)
    let payload = try ClipboardPayload.copy(clipIDs: [90, 92], from: p)
    // Inner 6 s: row 0 → track 1 (free there), row 1 → above it: a new track 2.
    let paste = PasteClips(payload, group: 80, at: .inner(180))
    try expectReversible(paste, on: p)
    try paste.apply(to: p)
    #expect(paste.pastedTracks == [1, 2])
    #expect(try innerLayout(p, 80) == [[[81, 60, 240]], [[82, 60, 90], [93, 180, 30]], [[94, 180, 30]]])
    try expectLossless(p)
}

// MARK: - TL11-5 Rev media is closed

@MainActor @Test func revMediaRefusesCopyOutAndPasteIn() throws {
    let rev = #"{"RevBackground" : "backgrounds/x.tscshadervid", "groupType" : "revMedia"}"#
    let plain = group(101, [innerTrack(0, [still(102, start: 0, dur: 30)])])
    let g = group(100, metadata: rev, [innerTrack(0, [still(103, start: 0, dur: 30)]), innerTrack(1, [plain])])
    let p = try projectWithAttributes([track(0, [g]), track(1, [still(110, start: 0, dur: 30)]), track(2, [])])
    p.root["sourceBin"] = try JSON.parse(bin)
    let before = p.serialized()
    #expect(throws: EditError.self) { try ClipboardPayload.copy(clipIDs: [103], from: p) }
    #expect(throws: EditError.self) { try ClipboardPayload.copy(clipIDs: [102], from: p) }  // a plain group inside Rev
    let payload = try ClipboardPayload.copy(clipIDs: [110], from: p)
    expectRejected(PasteClips(payload, group: 100, at: .inner(30)), on: p, .invalid(""))
    expectRejected(PasteClips(payload, group: 100, track: 0, at: .inner(30)), on: p, .invalid(""))
    expectRejected(PasteClips(payload, group: 101, at: .inner(0)), on: p, .invalid(""))
    #expect(p.serialized() == before)
    // The whole Rev group still copies and pastes, with its keys.
    let whole = PasteClips(try ClipboardPayload.copy(clipIDs: [100], from: p), track: 2, at: 0)
    try expectReversible(whole, on: p)
    try whole.apply(to: p)
    let pasted = try group(p, try #require(whole.pastedIDs.first))
    #expect(pasted["metadata"] == (try JSON.parse(rev)))
}

private extension JSON {
    /// This track object with its `medias` replaced (test helper).
    func withMedias(_ medias: [String]) -> JSON {
        guard let o = object?.copy() else { return self }
        o["medias"] = (try? JSON.parse("[" + medias.joined(separator: ", ") + "]")) ?? .null
        return .object(o)
    }
}
