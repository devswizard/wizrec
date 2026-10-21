import Foundation
import Testing
import TimelineEngine
import TSCProjKit
import WizRecAssets
@testable import PlayerKit

// QA16-F1 / APP15-2: drops while a group is open follow the drop rules inside the group
// (group-edits §8.7: open groups follow the top-level rules; §8.6: the group never grows, inner
// time = timeline − group start + mediaStart, unclamped). Paths, as `EditorWindowController`
// takes them with a group open:
//   timeline drop → `onGroupDrop` → `placeInGroup(_, group:, track:, at: inner)`;
//   canvas drop, media-bin double-click → `place(_, track: nil, …)` →
//     `placeInGroup(_, group:, atPlayhead:)` (canvas rule, [WizRec] DECISIONS session 11);
//   Backgrounds double-click → `placeBackground(_, inGroup:, atPlayhead:)`.

extension ImportPathPlacementIntegrationTests {
    /// Inner track and start of clip `id` inside group `gid` (top level).
    func innerSpot(_ id: Int64, group gid: Int64, _ doc: EditorDocumentModel) -> (track: Int, start: Int64)? {
        guard let g = doc.project.tracks.flatMap(\.clips).first(where: { $0.id == gid }) else { return nil }
        for (i, t) in g.tracks.enumerated() {
            if let c = t.clips.first(where: { $0.id == id }) { return (i, c.start) }
        }
        return nil
    }

    /// Group timing that must never change on a drop.
    func groupTiming(_ gid: Int64, _ doc: EditorDocumentModel) -> [String]? {
        guard let g = doc.project.tracks.flatMap(\.clips).first(where: { $0.id == gid }) else { return nil }
        return ["\(g.start)", "\(g.duration)", "\(g.mediaStart)", "\(g.mediaDuration)"]
    }

    /// A 5 s still grouped at timeline `at` (group start `at`, mediaStart 0) with an empty inner
    /// track 1 above it. Returns the group id, the still's source id and its clip duration.
    func groupedStill(_ f: Fixture, at: Int64, freeTrackAbove: Bool = true) async throws -> (gid: Int64, src: Int64, d: Int64) {
        let src = try await f.doc.importMedia(f.still)
        let a = try placeSources([src], track: 0, at: at, f.doc)[0]
        let group = GroupClips(clipIDs: [a])
        try f.doc.perform(group)
        let gid = try #require(group.groupID)
        if freeTrackAbove { try f.doc.perform(AddGroupTrack(group: gid, at: 1)) }
        return (gid, src, try DropRules.clipDuration(source: src, in: f.doc.project))
    }

    /// A timeline drop while a group is open on a busy inner spot: 0.5 s into the inner clip it
    /// inserts at the clip's start and pushes; 3 s in it goes to the free inner track above —
    /// what `DropRules.place(_, group:)` decides. The group keeps its timing.
    @Test func openGroupDropOnABusyInnerSpotFollowsTheDropRules() async throws {
        let f = try fixture("group-busy")
        defer { f.cleanUp() }
        let doc = f.doc
        let g = try await groupedStill(f, at: 0)
        let timing = groupTiming(g.gid, doc)

        for (at, rule) in [(f.s(0.5), DropPlacement.Rule.insertAtClipStart),
                           (f.s(3), DropPlacement.Rule.lowestTrackWithRoom)] as [(Int64, DropPlacement.Rule)] {
            let before = doc.project.serialized()
            let want = try DropRules.place(.timeline(track: 0, at: .inner(at)), group: g.gid, duration: g.d, in: doc.project)
            #expect(want.rule == rule)
            let ids = try await doc.placeInGroup(.sources([g.src]), group: g.gid, track: 0, at: at)
            let id = try #require(ids.first)
            let got = try #require(innerSpot(id, group: g.gid, doc))
            #expect(got.track == want.track && got.start == want.start, "\(rule)")
            #expect(groupTiming(g.gid, doc) == timing, "the group never grows")
            try doc.undoLast()
            #expect(doc.project.serialized() == before)
        }
    }

    /// Two bin items dropped together on a busy inner spot mid clip: the first moves up to inner
    /// track 1; the second follows on the track the first landed on, at its end.
    @Test func severalItemsDroppedInAGroupFollowTheFirst() async throws {
        let f = try fixture("group-multi")
        defer { f.cleanUp() }
        let doc = f.doc
        let g = try await groupedStill(f, at: 0)
        let ids = try await doc.placeInGroup(.sources([g.src, g.src]), group: g.gid, track: 0, at: f.s(3))
        try #require(ids.count == 2)
        let s0 = try #require(innerSpot(ids[0], group: g.gid, doc))
        let s1 = try #require(innerSpot(ids[1], group: g.gid, doc))
        #expect(s0.track == 1 && s0.start == f.s(3))
        #expect(s1.track == 1 && s1.start == f.s(3) + g.d)
        #expect(doc.undo.undoName == "Add to Group")
    }

    /// A canvas drop or bin double-click with a group open (group at 10 s): the playhead maps
    /// onto the inner timeline; the lowest inner track with room there takes the clip, else a new
    /// top inner track; past the window's end the clip is kept (hidden) and the group does not
    /// grow. Files dropped on the canvas are imported in the same step.
    @Test func canvasDropWithAGroupOpenGoesIntoTheGroup() async throws {
        let f = try fixture("group-canvas")
        defer { f.cleanUp() }
        let doc = f.doc
        let g = try await groupedStill(f, at: f.s(10))
        let timing = groupTiming(g.gid, doc)
        let topLevel = doc.project.tracks.map { $0.clips.map(\.id) }

        // Playhead 12 s = inner 2 s: inner track 0 busy (0–5 s) → inner track 1.
        let want = try DropRules.place(.canvas(playhead: f.s(12)), group: g.gid, duration: g.d, in: doc.project)
        #expect(want.rule == .lowestTrackWithRoom && want.track == 1 && want.start == f.s(2))
        let b = try #require(try await doc.placeInGroup(.sources([g.src]), group: g.gid, atPlayhead: f.s(12)).first)
        #expect(innerSpot(b, group: g.gid, doc).map { [$0.track, Int($0.start)] } == [1, Int(f.s(2))])
        // Same playhead: both inner tracks busy → a new top inner track 2.
        let c = try #require(try await doc.placeInGroup(.sources([g.src]), group: g.gid, atPlayhead: f.s(12)).first)
        #expect(innerSpot(c, group: g.gid, doc)?.track == 2)
        // Playhead 16 s = inner 6 s, past the window (inner 0–5 s): inner track 0 has room.
        let files = doc.project.sourceBin.count
        let d = try #require(try await doc.placeInGroup(.files([f.still2]), group: g.gid, atPlayhead: f.s(16)).first)
        #expect(innerSpot(d, group: g.gid, doc).map { [$0.track, Int($0.start)] } == [0, Int(f.s(6))])
        #expect(doc.project.sourceBin.count == files + 1, "the file is imported")

        #expect(groupTiming(g.gid, doc) == timing, "the group never grows")
        #expect(doc.project.tracks.map { $0.clips.map(\.id) } == topLevel, "nothing at top level")
    }

    /// A WizRec background into a Rev group: Rev keys (`ShaderVidSource`, `RevBackground`) only
    /// when the drop rules really land it on inner track 0 (an insert at the clip's start), not
    /// when a busy spot moves it up.
    @Test func revKeysOnlyWhenABackgroundLandsOnInnerTrackZero() async throws {
        let f = try fixture("group-rev")
        defer { f.cleanUp() }
        let doc = f.doc
        doc.backgroundLibraryRoot = f.dir.appendingPathComponent("Library", isDirectory: true)
        let aurora = try #require(AssetCatalog.background(id: "wizrec-aurora") as BackgroundAsset?)
        let first = try await doc.placeBackground(aurora, at: 0)
        let group = GroupClips(clipIDs: [first])
        try doc.perform(group)
        let gid = try #require(group.groupID)
        func clip(_ id: Int64) -> Clip? {
            var found: Clip?
            for t in doc.project.tracks { for c in t.clips { c.walk { inner, _ in if inner.id == id { found = inner } } } }
            return found
        }
        clip(gid)?.metadata?["groupType"] = .string("revMedia")

        // 30 s into the 60 s background (second half): moved up → a new top inner track, no Rev keys.
        let up = try await doc.placeBackground(aurora, inGroup: gid, track: 0, at: f.s(30))
        #expect(innerSpot(up, group: gid, doc)?.track == 1)
        #expect(clip(up)?.metadata?["ShaderVidSource"] == nil && clip(gid)?.metadata?["RevBackground"] == nil)
        try doc.undoLast()

        // 0.5 s in: inserted at the start of inner track 0 → Rev keys written.
        let ins = try await doc.placeBackground(aurora, inGroup: gid, track: 0, at: f.s(0.5))
        #expect(innerSpot(ins, group: gid, doc).map { [$0.track, Int($0.start)] } == [0, 0])
        #expect(clip(ins)?.metadata?["ShaderVidSource"]?.string != nil)
        #expect(clip(gid)?.metadata?["RevBackground"]?.string == "backgrounds/\(aurora.fileName)")
    }
}
