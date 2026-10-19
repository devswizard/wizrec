import CoreGraphics
import Foundation
import TestGenKit
import Testing
import TimelineEngine
import TSCProjKit
@testable import PlayerKit

@MainActor @Suite struct ClipboardTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("wizrec-clipboard-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func image(_ url: URL) throws {
        try MediaWriter.writePNG(to: url, width: 64, height: 48) { ctx in
            ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
    }

    @Test func copyPasteInSameProjectAvoidsOverlap() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("a.png")
        try image(png)
        let doc = try EditorDocumentModel.untitled(in: dir)
        let clip = try await doc.importAndInsert(png, at: 0)
        let payload = try doc.copyClips([clip])
        // Pasting over the original (track 0, t = 0) lands on a new top track instead.
        let ids = try await doc.paste(payload, origin: doc.bundle.directory, track: 0, at: 0)
        #expect(ids.count == 1)
        #expect(doc.project.tracks.count == 2)
        #expect(doc.project.tracks[1].clips.map(\.id) == ids)
        #expect(doc.project.sourceBin.count == 1)                 // source reused by src
        #expect(doc.undo.undoName == "Paste")
        try doc.undoLast()
        #expect(doc.project.tracks.count == 1)
        // Free spot: same track.
        let later = try await doc.paste(payload, origin: doc.bundle.directory, track: 0, at: 6 * 705_600_000)
        #expect(doc.project.tracks[0].clips.map(\.id).contains(later[0]))
    }

    @Test func cutRemovesAndPasteRestores() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("a.png")
        try image(png)
        let doc = try EditorDocumentModel.untitled(in: dir)
        let clip = try await doc.importAndInsert(png, at: 0)
        let payload = try doc.cutClips([clip])
        #expect(doc.project.tracks[0].clips.isEmpty)
        #expect(doc.undo.undoName == "Cut")
        let ids = try await doc.paste(payload, origin: nil, track: nil, at: 0)
        #expect(doc.project.tracks[0].clips.map(\.id) == ids)
    }

    @Test func crossProjectPasteImportsMedia() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("a.png")
        try image(png)
        let a = try EditorDocumentModel.untitled(in: dir)
        let clip = try await a.importAndInsert(png, at: 0)
        let payload = try a.copyClips([clip])

        let b = try EditorDocumentModel.untitled(in: dir)
        let ids = try await b.paste(payload, origin: a.bundle.directory, track: nil, at: 0)
        #expect(ids.count == 1)
        #expect(b.missing.isEmpty)
        let src = try #require(b.project.sourceBin.first?.src)
        #expect(src.hasPrefix("./media/"))
        #expect(FileManager.default.fileExists(atPath: b.bundle.directory.appendingPathComponent(String(src.dropFirst(2))).path))
        try b.undoLast()                                           // paste + relink are one step
        #expect(b.project.sourceBin.isEmpty && b.project.tracks[0].clips.isEmpty)

        // Without the origin the pasted source is reported missing (the app offers relink).
        let c = try EditorDocumentModel.untitled(in: dir)
        _ = try await c.paste(payload, origin: nil, track: nil, at: 0)
        #expect(c.missing.count == 1)
    }
}
