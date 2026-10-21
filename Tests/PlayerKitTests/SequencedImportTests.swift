import CoreGraphics
import Foundation
import TestGenKit
import Testing
import TSCProjKit
@testable import PlayerKit

/// Files dropped or opened together go onto the timeline back to back; a file that fails is
/// skipped (`EditorDocumentModel.importInSequence`).
@Suite @MainActor struct SequencedImportTests {
    private static func media() throws -> (dir: URL, wav: URL, png: URL, txt: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-seq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("voice.wav")
        try AudioSignals.writeWAV(AudioSignals.pinkNoise(seconds: 3, lufs: -23), to: wav)
        let png = dir.appendingPathComponent("still.png")
        try MediaWriter.writePNG(to: png, width: 32, height: 32) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let txt = dir.appendingPathComponent("notes.txt")
        try Data("not media".utf8).write(to: txt)
        return (dir, wav, png, txt)
    }

    @Test func placesBackToBackAndSkipsFailures() async throws {
        let m = try Self.media()
        defer { try? FileManager.default.removeItem(at: m.dir) }
        let doc = try EditorDocumentModel.untitled(in: m.dir)
        let tb = doc.project.timebase
        let r = await doc.importInSequence([m.wav, m.txt, m.png], place: true, from: tb.ticks(seconds: 1))
        #expect(r.failures.map(\.file) == [m.txt])
        if case DocumentError.unsupportedMedia(let name)? = r.failures.first?.error { #expect(name == "notes.txt") }
        else { Issue.record("expected unsupportedMedia, got \(String(describing: r.failures.first?.error))") }
        try #require(r.placed.count == 2)
        let clips = doc.project.tracks.flatMap(\.clips)
        let first = try #require(clips.first { $0.id == r.placed[0].clip })
        let second = try #require(clips.first { $0.id == r.placed[1].clip })
        #expect(first.start == tb.ticks(seconds: 1))
        #expect(second.start == first.end)          // back to back
        #expect(r.placed.map(\.track) == [0, 0])    // the track is free after the first clip
        #expect(doc.project.sourceBin.count == 2)
    }

    @Test func binOnlyImportPlacesNothing() async throws {
        let m = try Self.media()
        defer { try? FileManager.default.removeItem(at: m.dir) }
        let doc = try EditorDocumentModel.untitled(in: m.dir)
        let r = await doc.importInSequence([m.wav, m.png], place: false, from: 0)
        #expect(r.placed.isEmpty)
        #expect(r.failures.isEmpty)
        #expect(doc.project.sourceBin.count == 2)
        let empty = doc.project.tracks.allSatisfy { $0.clips.isEmpty }
        #expect(empty)
    }
}

/// File ▸ Open enables projects, media and plain folders, never other packages.
@Suite struct OpenPanelRuleTests {
    private func u(_ p: String) -> URL { URL(fileURLWithPath: "/tmp/\(p)") }

    @Test func enablesWhatWizRecOpensAndFolders() {
        #expect(OpenableFile.enablesInOpenPanel(u("demo.cmproj"), isDirectory: true, isPackage: true))
        #expect(OpenableFile.enablesInOpenPanel(u("a.tscproj"), isDirectory: false, isPackage: false))
        #expect(OpenableFile.enablesInOpenPanel(u("v.mp4"), isDirectory: false, isPackage: false))
        #expect(OpenableFile.enablesInOpenPanel(u("Movies"), isDirectory: true, isPackage: false))
        #expect(!OpenableFile.enablesInOpenPanel(u("Tool.app"), isDirectory: true, isPackage: true))
        #expect(!OpenableFile.enablesInOpenPanel(u("Doc.pages"), isDirectory: true, isPackage: true))
        #expect(!OpenableFile.enablesInOpenPanel(u("notes.txt"), isDirectory: false, isPackage: false))
    }

    @Test func readsTheFileSystem() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-openpanel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let txt = dir.appendingPathComponent("notes.txt")
        try Data().write(to: txt)
        #expect(OpenableFile.enablesInOpenPanel(dir))
        #expect(!OpenableFile.enablesInOpenPanel(txt))
    }
}
