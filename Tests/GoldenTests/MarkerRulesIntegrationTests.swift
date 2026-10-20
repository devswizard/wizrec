import Foundation
import Testing
import TestGenKit
import TimelineEngine
import TSCProjKit

// S5-QA-1 / timeline7 X8: timeline markers are default-named "Marker" and stay where they are
// when clips are ripple-deleted, moved, split or trimmed (Camtasia leaves `toc` alone) [obs,
// markers.md]; save/reopen keeps them; undo restores the bytes.

@Suite @MainActor struct MarkerRulesIntegrationTests {
    @Test func rippleEditsLeaveTimelineMarkers() throws {
        let dir = try scratchDir("s5-markers")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("mk.cmproj"), width: 320, height: 180)
        let setup = EditChain(bundle.project)
        let add = AddSource(movieDescriptor(src: "./media/m.mov", frames: 90, audio: true))
        add.addedAt = Date(timeIntervalSince1970: 1_792_376_869)
        try setup.run(add)
        let source = try #require(add.sourceID)
        let a = try #require(try setup.run(InsertClip(sourceID: source, track: 0, start: 0)).clipID)
        let b = try #require(try setup.run(InsertClip(sourceID: source, track: 0, start: frames(90))).clipID)
        _ = try setup.run(InsertClip(sourceID: source, track: 0, start: frames(180)))
        let chain = EditChain(bundle.project)
        let original = chain.project.serialized()

        try chain.run(AddMarker(at: frames(60)))
        try chain.run(AddMarker(at: frames(150), name: "Chapter 2"))
        try chain.run(AddMarker(at: frames(240)))
        let expected = [Marker(time: frames(60), name: Markers.defaultName), Marker(time: frames(150), name: "Chapter 2"),
                        Marker(time: frames(240), name: "Marker")]
        #expect(Markers.timeline(chain.project) == expected)

        // Ripple-delete the middle clip: later clips move 3 s earlier, markers do not.
        try chain.run(DeleteClips(clipIDs: [b], ripple: true))
        #expect(chain.project.tracks[0].clips.map(\.start) == [0, frames(90)])
        #expect(Markers.timeline(chain.project) == expected, "ripple delete moved markers")

        // Split, trim and move the first clip: markers still untouched.
        let right = try #require(try chain.run(SplitClip(clipID: a, at: frames(45))).rightID)
        try chain.run(TrimClip(clipID: right, edge: .end, to: frames(80)))
        try chain.run(MoveClip(clipID: a, toTrack: 0, start: frames(200)))
        #expect(Markers.timeline(chain.project) == expected, "clip edits moved markers")

        try bundle.saveWithBackup()
        let reopened = try ProjectBundle(url: bundle.directory)
        #expect(Markers.timeline(reopened.project) == expected)
        #expect(reopened.project.serialized() == chain.project.serialized())

        try chain.run(RemoveMarker(at: frames(150)))
        #expect(Markers.timeline(chain.project).map(\.time) == [frames(60), frames(240)])
        try chain.expectUndoRedoWalk()
        try chain.undoAll()
        #expect(chain.project.serialized() == original)
        #expect(Markers.timeline(chain.project).isEmpty)
    }
}
