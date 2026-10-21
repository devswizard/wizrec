import CoreGraphics
import Foundation
import MediaEngine
import TestGenKit
import Testing
import TimelineEngine
import TSCProjKit
import WizRecAssets
@testable import PlayerKit

@Suite @MainActor struct GroupPlacementTests {
    @Test func placesSourcesAndFilesInsideAGroupAsOneUndoStep() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-groupdrop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("voice.wav")
        try AudioSignals.writeWAV(AudioSignals.pinkNoise(seconds: 2, lufs: -23), to: wav)
        let png = dir.appendingPathComponent("still.png")
        try MediaWriter.writePNG(to: png, width: 64, height: 64) { ctx in
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let doc = try EditorDocumentModel.untitled(in: dir)
        let tb = doc.project.timebase
        let a = try await doc.importAndInsert(wav, at: 0)
        let group = GroupClips(clipIDs: [a])
        try doc.perform(group)
        let gid = try #require(group.groupID)
        try doc.perform(AddGroupTrack(group: gid, at: 1))  // empty inner track 1 above the grouped clip
        let src = try #require(doc.project.sourceBin.first { $0.src.hasSuffix("voice.wav") }?.id)
        let before = doc.project.serialized()
        let sources = doc.project.sourceBin.count

        // Two bin items on inner track 1 from 0.5 s: the second starts where the first ends.
        let half = tb.ticks(seconds: 0.5)
        let ids = try await doc.placeInGroup(.sources([src, src]), group: gid, track: 1, at: half)
        #expect(ids.count == 2)
        let e0 = try #require(EditorDocumentModel.innerClipEnd(ids[0], in: doc.project))
        #expect(e0 > half)
        #expect(nestedStarts(ids, in: doc) == [half, e0])
        #expect(doc.project.tracks.flatMap(\.clips).allSatisfy { !ids.contains($0.id) })  // not top level
        try doc.undoLast()
        #expect(doc.project.serialized() == before)

        // A file is imported into the bin and placed in the same undo step.
        let fileIDs = try await doc.placeInGroup(.files([png]), group: gid, track: 1, at: 0)
        #expect(fileIDs.count == 1)
        #expect(doc.project.sourceBin.count == sources + 1)
        try doc.undoLast()
        #expect(doc.project.sourceBin.count == sources)
        #expect(doc.project.serialized() == before)

        await #expect(throws: (any Error).self) {
            try await doc.placeInGroup(.sources([src]), group: 999_999, track: 0, at: 0)
        }
        #expect(doc.project.serialized() == before)
    }

    /// The UI check's scenario on a Camtasia-authored group (demo fixture, group 4 with three full
    /// inner tracks): a file dropped on inner track 0 after its last clip is imported, nested in
    /// the group (which never grows, group-edits §8.6), saved and reopened; top-level clips are
    /// unchanged.
    @Test func dropAfterLastClipOfCamtasiaGroupKeepsItAndSurvivesSave() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-groupdrop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = dir.appendingPathComponent("demo.cmproj")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.fixture, to: bundle.appendingPathComponent("project.tscproj"))
        let png = dir.appendingPathComponent("dropped.png")
        try MediaWriter.writePNG(to: png, width: 64, height: 36) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        }
        let doc = try EditorDocumentModel(url: bundle)
        let group = try #require(doc.project.tracks.flatMap(\.clips).first { $0.kind == .group })
        let topLevel = doc.project.tracks.map { $0.clips.map(\.id) }
        let innerEnd = try #require(group.tracks.first?.clips.map(\.end).max())
        let before = doc.project.serialized()

        let ids = try await doc.placeInGroup(.files([png]), group: group.id, track: 0, at: innerEnd)
        let id = try #require(ids.first)
        let g2 = try #require(doc.project.tracks.flatMap(\.clips).first { $0.id == group.id })
        let placed = try #require(g2.tracks.first?.clips.first { $0.id == id })
        #expect(placed.start == innerEnd)
        #expect(g2.duration == group.duration && g2.mediaDuration == group.mediaDuration)
        #expect(doc.project.tracks.map { $0.clips.map(\.id) } == topLevel)
        #expect(doc.project.sourceBin.count == 3)

        try doc.save()
        let reopened = try EditorDocumentModel(url: bundle)
        let g3 = try #require(reopened.project.tracks.flatMap(\.clips).first { $0.id == group.id })
        #expect(g3.tracks.first?.clips.contains { $0.id == id } == true)
        #expect(reopened.project.sourceBin.count == 3)

        try doc.undoLast()
        #expect(doc.project.serialized() == before)
    }

    /// APP12-4: a library background double-clicked with a group open goes on a new top inner
    /// track at the playhead mapped into the group (unclamped), and the group never grows.
    @Test func libraryBackgroundGoesOnANewTopInnerTrackAtThePlayhead() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-groupbg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try EditorDocumentModel.untitled(width: 640, height: 360, in: dir)
        doc.backgroundLibraryRoot = dir.appendingPathComponent("Library", isDirectory: true)
        let tb = doc.project.timebase
        let aurora = try #require(AssetCatalog.background(id: "wizrec-aurora") as BackgroundAsset?)
        let first = try await doc.placeBackground(aurora, at: tb.ticks(seconds: 10))
        let group = GroupClips(clipIDs: [first])
        try doc.perform(group)
        let gid = try #require(group.groupID)
        func groupClip() throws -> Clip { try #require(doc.project.tracks.flatMap(\.clips).first { $0.id == gid }) }
        let g0 = try groupClip()
        #expect(g0.tracks.count == 1)
        let before = doc.project.serialized()

        // Playhead 25 s = inner 15 s (group at 10 s, mediaStart 0): new inner track 1.
        let id = try await doc.placeBackground(aurora, inGroup: gid, atPlayhead: tb.ticks(seconds: 25))
        let g1 = try groupClip()
        #expect(g1.tracks.count == 2)
        #expect(g1.tracks[1].clips.map(\.id) == [id] && g1.tracks[1].clips.first?.start == tb.ticks(seconds: 15))
        #expect(g1.duration == g0.duration && g1.mediaDuration == g0.mediaDuration && g1.start == g0.start)
        #expect(g1.tracks[1].clips.first?.metadata?["ShaderVidSource"] == nil)   // not inner track 0
        #expect(doc.undo.undoName == "Add Background")

        // Before the group: kept at inner −5 s (hidden), on a further new top track; no growth.
        let early = try await doc.placeBackground(aurora, inGroup: gid, atPlayhead: tb.ticks(seconds: 5))
        let g2 = try groupClip()
        #expect(g2.tracks.count == 3 && g2.tracks[2].clips.first?.id == early)
        #expect(g2.tracks[2].clips.first?.start == -tb.ticks(seconds: 5))
        #expect(g2.duration == g0.duration && g2.start == g0.start)

        try doc.undoLast(); try doc.undoLast()
        #expect(doc.project.serialized() == before)
    }

    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TSCProjKitTests/Fixtures/demo.tscproj")

    private func nestedStarts(_ ids: [Int64], in doc: EditorDocumentModel) -> [Int64] {
        var out: [Int64: Int64] = [:]
        for t in doc.project.tracks {
            for c in t.clips { c.walk { inner, depth in if depth > 0, ids.contains(inner.id) { out[inner.id] = inner.start } } }
        }
        return ids.compactMap { out[$0] }
    }
}
