import CoreGraphics
import Foundation
import TestGenKit
import Testing
import TimelineEngine
import TSCProjKit
@testable import PlayerKit

// QA15-1 / TL15-1: a new project starts with two empty tracks, as Camtasia's does
// (ui-workflow.md §2). End to end through the editor's document model: the start screen's New
// Project and media opened as a project (`EditorDocumentModel.untitled`), drops, a recording,
// Save As and reopen.

@Suite(.serialized) @MainActor struct NewProjectTracksIntegrationTests {
    private func tempDir(_ tag: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("qa16-\(tag)-\(UUID().uuidString)",
                                                                           isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func still(_ url: URL) throws {
        try MediaWriter.writePNG(to: url, width: 32, height: 18) { ctx in
            ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 18))
        }
    }

    /// New Project: two empty tracks (each with its `trackAttributes` entry), not dirty, nothing
    /// to undo; Save As and reopen keep them, and a second save writes the same bytes.
    @Test func newProjectHasTwoEmptyTracksThatSurviveSave() throws {
        let dir = try tempDir("new")
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try EditorDocumentModel.untitled(width: 640, height: 360, in: dir)
        #expect(doc.project.tracks.count == 2)
        #expect(doc.project.tracks.allSatisfy { $0.clips.isEmpty })
        #expect(doc.project.timeline?.trackAttributes.count == 2)
        #expect(!doc.isDirty && !doc.undo.canUndo)

        let saved = dir.appendingPathComponent("Empty.cmproj", isDirectory: true)
        #expect(try doc.saveAs(to: saved).isEmpty)
        let reopened = try EditorDocumentModel(url: saved)
        #expect(reopened.project.tracks.count == 2 && reopened.project.timeline?.trackAttributes.count == 2)
        #expect(reopened.project.serialized() == doc.project.serialized())
        try reopened.save()
        #expect(try EditorDocumentModel(url: saved).project.serialized() == reopened.project.serialized())
    }

    /// Drops on a new project use the two tracks before adding any: canvas drops at the same
    /// playhead fill track 0, then track 1, then make track 2; a recording's files stack on the
    /// existing tracks. Undo of every step returns the two empty tracks.
    @Test func dropsAndRecordingsUseTheTwoTracksFirst() async throws {
        let dir = try tempDir("drops")
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("still.png")
        try still(png)
        let wav = dir.appendingPathComponent("voice.wav")
        try AudioSignals.writeWAV(AudioSignals.pinkNoise(seconds: 2, lufs: -23), to: wav)
        let doc = try EditorDocumentModel.untitled(width: 640, height: 360, in: dir)
        let empty = doc.project.serialized()

        // A recording into the new project: screen on track 0, audio on track 1, no new track.
        let rec = try await doc.importAndPlace([png, wav], at: 0, name: "Add Recording")
        func track(_ id: Int64) -> Int? { doc.project.tracks.firstIndex { $0.clips.contains { $0.id == id } } }
        #expect(rec.map(track) == [0, 1])
        #expect(doc.project.tracks.count == 2)
        try doc.undoLast()
        #expect(doc.project.serialized() == empty)

        // Canvas drops of a bin item at playhead 0.
        let src = try await doc.importMedia(png)
        let ids = try (0..<3).map { _ in try doc.insertSource(src, at: 0) }
        #expect(ids.map(track) == [0, 1, 2])
        #expect(doc.project.tracks.count == 3, "only the third drop adds a track")
        for _ in 0..<4 { try doc.undoLast() }
        #expect(doc.project.serialized() == empty)
    }
}
