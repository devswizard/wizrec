import Foundation
import Testing
import TimelineEngine
import TSCProjKit
import WizRecAssets
@testable import PlayerKit

/// Where a library background came from (`docs/specs/shader-backgrounds.md` §1): only a
/// background placed on inner track 0 of a Rev group gets `metadata.ShaderVidSource` and the
/// group's `metadata.RevBackground`, as in Camtasia's demo save; top-level and plain-group
/// placements write neither [WizRec, DECISIONS 2026-10-20].
@MainActor @Suite struct ShaderBackgroundOriginTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("wizrec-bg-origin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func asset(_ id: String) throws -> BackgroundAsset {
        try #require(AssetCatalog.background(id: id) as BackgroundAsset?)
    }

    private func clip(_ id: Int64, in doc: EditorDocumentModel) -> Clip? {
        var found: Clip?
        for t in doc.project.tracks { for c in t.clips { c.walk { inner, _ in if inner.id == id { found = inner } } } }
        return found
    }

    /// An untitled document holding one background grouped on track 0; returns it and the group id.
    private func groupedDoc(in dir: URL, rev: Bool) async throws -> (EditorDocumentModel, Int64) {
        let doc = try EditorDocumentModel.untitled(in: dir)
        doc.backgroundLibraryRoot = dir.appendingPathComponent("Library", isDirectory: true)
        let first = try await doc.placeBackground(try asset("wizrec-aurora"), at: 0)
        let text = String(decoding: doc.project.serialized(), as: UTF8.self)
        #expect(!text.contains("ShaderVidSource") && !text.contains("RevBackground"))   // top level: neither
        let group = GroupClips(clipIDs: [first])
        try doc.perform(group)
        let gid = try #require(group.groupID)
        if rev { clip(gid, in: doc)?.metadata?["groupType"] = .string("revMedia") }
        return (doc, gid)
    }

    @Test func revGroupBackgroundRecordsItsLibraryFile() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (doc, gid) = try await groupedDoc(in: dir, rev: true)
        let before = doc.project.serialized()
        let bg = try asset("wizrec-stripes")
        let end = 60 * doc.project.timebase.editRate
        let id = try await doc.placeBackground(bg, inGroup: gid, track: 0, at: end)
        #expect(doc.undo.undoName == "Add Background")

        let file = doc.backgroundLibraryRoot.appendingPathComponent("backgrounds/\(bg.fileName)")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try Data(contentsOf: file) == (try bg.shaderVidData()))
        let placed = try #require(clip(id, in: doc))
        #expect(placed.metadata?["ShaderVidSource"]?.string == file.path)
        #expect(placed.metadata?.keys.first == "ShaderVidSource")
        #expect(placed.object["sourceEffect"] != nil)
        let group = try #require(clip(gid, in: doc))
        #expect(group.metadata?["RevBackground"]?.string == "backgrounds/\(bg.fileName)")
        #expect(group.metadata?.keys.first == "RevBackground")
        // The bundle plays its own copy, not the library file.
        let sourceID = try #require(placed.sourceID)
        let src = try #require(doc.project.source(id: sourceID)?.src)
        #expect(src.hasPrefix("./media/") && src.hasSuffix(bg.fileName))

        let after = doc.project.serialized()
        try doc.undoLast()
        #expect(doc.project.serialized() == before)
        try doc.redoLast()
        #expect(doc.project.serialized() == after)
    }

    @Test func plainGroupBackgroundWritesNoOrigin() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (doc, gid) = try await groupedDoc(in: dir, rev: false)
        let id = try await doc.placeBackground(try asset("wizrec-stripes"), inGroup: gid, track: 0,
                                               at: 60 * doc.project.timebase.editRate)
        #expect(clip(id, in: doc)?.object["sourceEffect"] != nil)
        let text = String(decoding: doc.project.serialized(), as: UTF8.self)
        #expect(!text.contains("ShaderVidSource") && !text.contains("RevBackground"))
    }

    @Test func defaultLibraryRootIsApplicationSupport() {
        let root = EditorDocumentModel.defaultBackgroundLibraryRoot
        #expect(root.lastPathComponent == "WizRec")
        #expect(root.deletingLastPathComponent().lastPathComponent == "Application Support")
    }
}
