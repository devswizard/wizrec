import Foundation
import MediaEngine
import TestGenKit
import Testing
import TimelineEngine
import TSCProjKit
@testable import PlayerKit

/// Context-menu edits composed in the app (APP15-1c): Duplicate and Ripple Cut, each one undo
/// step with its own name.
@Suite @MainActor struct DuplicateRippleCutTests {
    func makeDoc(_ dir: URL) async throws -> (EditorDocumentModel, a: Int64, b: Int64) {
        let wav = dir.appendingPathComponent("voice.wav")
        try AudioSignals.writeWAV(AudioSignals.pinkNoise(seconds: 1, lufs: -23), to: wav)
        let doc = try EditorDocumentModel.untitled(in: dir)
        let a = try await doc.importAndInsert(wav, at: 0)
        let end = try #require(doc.project.tracks.flatMap(\.clips).first { $0.id == a }?.end)
        let src = try #require(doc.project.sourceBin.first?.id)
        let b = try doc.insertSource(src, at: end, track: 0)
        return (doc, a, b)
    }

    func clips(_ doc: EditorDocumentModel, track: Int) -> [(id: Int64, start: Int64, end: Int64)] {
        guard doc.project.tracks.indices.contains(track) else { return [] }
        return doc.project.tracks[track].clips.map { ($0.id, $0.start, $0.end) }
    }

    @Test func duplicatePlacesCopiesRightAfterTheSelection() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-dup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (doc, a, b) = try await makeDoc(dir)
        let before = doc.project.serialized()
        let end = try #require(clips(doc, track: 0).last?.end)
        // Duplicating clip a: b already sits at a's end, so the copy goes on a new top track there.
        let aEnd = try #require(clips(doc, track: 0).first?.end)
        let one = try await doc.duplicateClips([a], end: aEnd, track: 0)
        #expect(doc.undo.undoName == "Duplicate")
        #expect(one.count == 1 && clips(doc, track: 0).count == 2)
        #expect(clips(doc, track: doc.project.tracks.count - 1).map(\.start) == [aEnd])
        try doc.undoLast()
        #expect(doc.project.serialized() == before)
        // Duplicating both: the copies follow on the same track.
        let two = try await doc.duplicateClips([a, b], end: end, track: 0)
        #expect(two.count == 2)
        #expect(clips(doc, track: 0).count == 4 && clips(doc, track: 0)[2].start == end)
        try doc.undoLast()
        #expect(doc.project.serialized() == before)
    }

    @Test func rippleCutClosesTheGapInOneStep() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-rcut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (doc, a, b) = try await makeDoc(dir)
        let before = doc.project.serialized()
        let payload = try doc.rippleCutClips([a])
        #expect(doc.undo.undoName == "Ripple Cut")
        #expect(clips(doc, track: 0).map(\.id) == [b] && clips(doc, track: 0).first?.start == 0)
        // The payload pastes back the cut clip.
        let pasted = try await doc.paste(payload, origin: nil, track: 0, at: 0)
        #expect(pasted.count == 1)
        try doc.undoLast()
        try doc.undoLast()
        #expect(doc.project.serialized() == before)
    }
}
