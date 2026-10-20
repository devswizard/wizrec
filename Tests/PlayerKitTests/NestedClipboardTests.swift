import CoreGraphics
import Foundation
import TestGenKit
import Testing
import TimelineEngine
import TSCProjKit
@testable import PlayerKit

// TL10-1: Copy/Cut/Paste with a group open on the timeline.
@MainActor @Suite struct NestedClipboardTests {
    private static let rate: Int64 = 705_600_000

    @Test func copyInsideOpenGroupAndPasteBackIntoIt() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wizrec-nested-clipboard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("a.png")
        try MediaWriter.writePNG(to: png, width: 64, height: 48) { ctx in
            ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        let doc = try EditorDocumentModel.untitled(in: dir)
        let clip = try await doc.importAndInsert(png, at: 0)
        let group = GroupClips(clipIDs: [clip])
        try doc.perform(group)
        let gid = try #require(group.groupID)
        let inner = try #require(doc.project.tracks[0].clips.first?.tracks.first?.clips.first?.id)

        // With the group open, the inner selection is what Copy takes; closed, nothing nested.
        let open: [Int64] = doc.clipboardSelection([inner], openGroup: gid)
        let closed: [Int64] = doc.clipboardSelection([inner], openGroup: nil)
        let outer: [Int64] = doc.clipboardSelection([gid], openGroup: gid)   // nothing inside selected
        #expect(open == [inner] && closed.isEmpty && outer == [gid])
        #expect(doc.pasteTrack([inner], openGroup: gid) == 0)
        #expect(doc.pasteTrack([inner], openGroup: nil) == nil)

        let before = doc.project.serialized()
        let payload = try doc.copyClips([inner])
        // Over the original (inner track 0 at 0): lands on a new inner track on top.
        let ids = try await doc.paste(payload, origin: nil, track: 0, at: 0, group: gid)
        let g = try #require(doc.project.tracks[0].clips.first)
        #expect(ids.count == 1 && g.tracks.count == 2)
        #expect(g.tracks[1].clips.map { [$0.id, $0.start] } == [[ids[0], 0]])
        #expect(doc.project.tracks.count == 1 && doc.undo.undoName == "Paste")
        try doc.undoLast()
        #expect(doc.project.serialized() == before)

        // A free spot after the clip: same inner track; the group grows to show it.
        let at = g.start + g.duration
        let later = try await doc.paste(payload, origin: nil, track: 0, at: at, group: gid)
        let h = try #require(doc.project.tracks[0].clips.first)
        #expect(h.tracks.count == 1 && h.tracks[0].clips.map(\.id).contains(later[0]))
        #expect(h.duration == 2 * g.duration)

        // Pasted at top level instead (no group): a plain top-level clip.
        let top = try await doc.paste(payload, origin: nil, track: nil, at: 30 * Self.rate)
        #expect(doc.project.tracks[0].clips.map(\.id).contains(top[0]))
    }
}
