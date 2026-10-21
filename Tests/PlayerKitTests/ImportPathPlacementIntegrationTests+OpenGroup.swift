import Foundation
import Testing
import TimelineEngine
import TSCProjKit
@testable import PlayerKit

// QA16-F1 / APP15-2: drops while a group is open follow the drop rules inside the group
// (group-edits §8.7: open groups follow the top-level rules; the group never grows).

extension ImportPathPlacementIntegrationTests {
    /// A timeline drop while a group is open (`onGroupDrop` → `placeInGroup`) on a busy inner
    /// spot: 0.5 s into the inner clip it inserts at the clip's start and pushes; 3 s in it goes
    /// to the free inner track above — what `DropRules.place(_, group:)` / `DropClip(group:)`
    /// decide. The group keeps its timing.
    @Test func openGroupDropOnABusyInnerSpotFollowsTheDropRules() async throws {
        let f = try fixture("group-busy")
        defer { f.cleanUp() }
        let doc = f.doc
        let src = try await doc.importMedia(f.still)
        let a = try placeSources([src], track: 0, at: 0, doc)[0]        // track 0, 0–5 s
        let group = GroupClips(clipIDs: [a])
        try doc.perform(group)
        let gid = try #require(group.groupID)
        try doc.perform(AddGroupTrack(group: gid, at: 1))                // free inner track 1
        let d = try DropRules.clipDuration(source: src, in: doc.project)
        let g0 = try #require(doc.project.tracks.flatMap(\.clips).first { $0.id == gid })

        for (at, rule) in [(f.s(0.5), DropPlacement.Rule.insertAtClipStart),
                           (f.s(3), DropPlacement.Rule.lowestTrackWithRoom)] as [(Int64, DropPlacement.Rule)] {
            let before = doc.project.serialized()
            let want = try DropRules.place(.timeline(track: 0, at: .inner(at)), group: gid, duration: d, in: doc.project)
            #expect(want.rule == rule)
            let ids = try await doc.placeInGroup(.sources([src]), group: gid, track: 0, at: at)
            let id = try #require(ids.first)
            #expect(EditorDocumentModel.innerClipEnd(id, in: doc.project) == want.start + d, "\(rule)")
            let g1 = try #require(doc.project.tracks.flatMap(\.clips).first { $0.id == gid })
            #expect(g1.start == g0.start && g1.duration == g0.duration && g1.mediaDuration == g0.mediaDuration,
                    "the group never grows")
            try doc.undoLast()
            #expect(doc.project.serialized() == before)
        }
    }
}
