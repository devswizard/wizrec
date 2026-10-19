import CoreGraphics
import Foundation
import MediaEngine
import TestGenKit
import Testing
import TimelineEngine
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

    private func nestedStarts(_ ids: [Int64], in doc: EditorDocumentModel) -> [Int64] {
        var out: [Int64: Int64] = [:]
        for t in doc.project.tracks {
            for c in t.clips { c.walk { inner, depth in if depth > 0, ids.contains(inner.id) { out[inner.id] = inner.start } } }
        }
        return ids.compactMap { out[$0] }
    }
}
