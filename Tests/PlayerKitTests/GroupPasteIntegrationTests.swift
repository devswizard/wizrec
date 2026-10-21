import CoreGraphics
import Foundation
import MediaEngine
import Metal
import PlayerKit
import RenderEngine
import TestGenKit
import Testing
import TimelineEngine
import TSCProjKit
import WizRecTestSupport

/// QA12-2 (timeline11 merged): copy/paste with groups through the document model, checked on
/// rendered pixels. A clip copied out of a moved and scaled group lands where it was on the
/// canvas; a clip pasted into such a group stays where it was; a paste into an open group is
/// clamped to the group's window and never grows the group (group-edits.md §8.2, §8.3).
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
@MainActor struct GroupPasteIntegrationTests {
    private static let (w, h) = (320, 180)
    private static let rate: Int64 = 705_600_000
    private static func s(_ seconds: Double) -> Int64 { Int64(seconds * Double(rate)) }

    /// A colour key: which pixels belong to a clip of that colour.
    private enum Key { case green, red }

    /// Untitled 320×180 doc in `dir` with a 64×48 green still (X −60) inside a group that starts
    /// at 2 s, sits at (40, 20) and is scaled 50 %. Returns the doc, group id and inner clip id.
    private func groupedDoc(in dir: URL) async throws -> (EditorDocumentModel, Int64, Int64) {
        let green = try still(in: dir, "green.png", (0, 1, 0))
        let doc = try EditorDocumentModel.untitled(width: Self.w, height: Self.h, in: dir)
        let clip = try await doc.importAndInsert(green, at: Self.s(2))
        let group = GroupClips(clipIDs: [clip])
        try doc.perform(group)
        let gid = try #require(group.groupID)
        // Grouping centres the group on its clip; the inner offset is set afterwards.
        try doc.perform(SetParameter(clipID: clip, parameter: "translation0", value: -60))
        for (name, value) in [("translation0", 40.0), ("translation1", 20.0), ("scale0", 0.5), ("scale1", 0.5)] {
            try doc.perform(SetParameter(clipID: gid, parameter: name, value: value))
        }
        return (doc, gid, clip)
    }

    private func still(in dir: URL, _ name: String, _ rgb: (CGFloat, CGFloat, CGFloat)) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try MediaWriter.writePNG(to: url, width: 64, height: 48) { ctx in
            ctx.setFillColor(CGColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        return url
    }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qa12-group-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The canvas frame at `ticks` (offline renderer = the export path), bounded.
    private func frame(_ doc: EditorDocumentModel, at ticks: Int64) async throws -> RGBAImage {
        let renderer = OfflineRenderer(scene: doc.scene, pool: MediaPool(diskCacheDirectory: nil))
        let size = CGSize(width: Self.w, height: Self.h)
        let task = Task { try await renderer.image(at: ticks, size: size) }
        return RGBAImage(try await Deadline.value(of: task, "frame at \(ticks)", seconds: GPUWait.defaultSeconds))
    }

    /// Bounding box (x0, y0, x1, y1; inclusive, top-left origin) of `key`-coloured pixels.
    private func box(_ image: RGBAImage, _ key: Key) -> [Int]? {
        var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let p = image.pixel(x, y)
                let hit: Bool
                switch key {
                case .green: hit = p.g > 160 && p.r < 90 && p.b < 90
                case .red: hit = p.r > 160 && p.g < 90 && p.b < 90
                }
                if hit { x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y) }
            }
        }
        return x1 < 0 ? nil : [x0, y0, x1, y1]
    }

    /// True when boxes `a` and `b` match within `tolerance` px on every edge.
    private func close(_ a: [Int]?, _ b: [Int]?, tolerance: Int = 1) -> Bool {
        guard let a, let b, a.count == 4, b.count == 4 else { return false }
        return zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    @Test func copyOutOfMovedScaledGroupKeepsCanvasPlacement() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (doc, gid, inner) = try await groupedDoc(in: dir)
        let g = try #require(doc.project.tracks[0].clips.first)
        let inGroup = try #require(box(try await frame(doc, at: g.start + Self.s(1)), .green))
        // The group really moves and scales its clip: 32×24 px, off centre.
        #expect(abs((inGroup[2] - inGroup[0] + 1) - 32) <= 1 && abs((inGroup[3] - inGroup[1] + 1) - 24) <= 1,
                "inner clip drawn at \(inGroup)")
        #expect(abs((inGroup[0] + inGroup[2]) / 2 - (160 + 10)) <= 1, "inner clip centre x at \(inGroup)")

        let copied = doc.clipboardSelection([inner], openGroup: gid)
        #expect(copied == [inner])
        let payload = try doc.copyClips(copied)
        let at = g.start + g.duration + Self.s(3)
        let pasted = try await doc.paste(payload, origin: nil, track: nil, at: at)
        #expect(pasted.count == 1 && doc.undo.undoName == "Paste")
        let top = try #require(doc.project.tracks.flatMap(\.clips).first { $0.id == pasted.first })
        #expect(top.start == at)
        let outside = try #require(box(try await frame(doc, at: at + Self.s(1)), .green))
        #expect(close(outside, inGroup), "pasted at \(outside), was \(inGroup) inside the group")

        // Survives save and reopen; undo removes the paste.
        let saved = dir.appendingPathComponent("saved.cmproj", isDirectory: true)
        try doc.saveAs(to: saved)
        let reopened = try EditorDocumentModel(url: saved)
        #expect(reopened.project.serialized() == doc.project.serialized())
        #expect(close(box(try await frame(reopened, at: at + Self.s(1)), .green), inGroup))
        try doc.undoLast()
        #expect(box(try await frame(doc, at: at + Self.s(1)), .green) == nil)
    }

    @Test func pasteIntoMovedScaledGroupKeepsCanvasPlacement() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (doc, gid, _) = try await groupedDoc(in: dir)
        let g = try #require(doc.project.tracks[0].clips.first)
        let red = try still(in: dir, "red.png", (1, 0, 0))
        let free = g.start + g.duration + Self.s(2)
        let b = try await doc.importAndInsert(red, at: free)
        try doc.perform(SetParameter(clipID: b, parameter: "translation1", value: -30))
        let alone = try #require(box(try await frame(doc, at: free + Self.s(1)), .red))
        #expect(abs((alone[2] - alone[0] + 1) - 64) <= 1, "top-level red clip drawn at \(alone)")

        let before = (g.start, g.duration, g.mediaStart, g.mediaDuration)
        let payload = try doc.copyClips([b])
        let into = try await doc.paste(payload, origin: nil, track: nil, at: g.start + Self.s(1), group: gid)
        #expect(into.count == 1)
        let after = try #require(doc.project.tracks[0].clips.first { $0.id == gid })
        #expect(after.tracks.count == 2, "inner track 0 is busy at 1 s: a new inner track on top")
        #expect(after.start == before.0 && after.duration == before.1)
        #expect(after.mediaStart == before.2 && after.mediaDuration == before.3)
        // Inside the 50 % group it is still 64×48 at the same canvas spot.
        let inside = try #require(box(try await frame(doc, at: g.start + Self.s(1) + Self.s(0.5)), .red))
        #expect(close(inside, alone), "pasted into the group at \(inside), was \(alone)")
    }

    @Test func pasteIntoOpenGroupClampsToWindowAndNeverGrows() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (doc, gid, inner) = try await groupedDoc(in: dir)
        let g = try #require(doc.project.tracks[0].clips.first)
        let end = g.start + g.duration
        let projectEnd = doc.scene.duration
        let original = doc.project.serialized()
        let payload = try doc.copyClips(doc.clipboardSelection([inner], openGroup: gid))

        // Playhead before the group (0.5 s): lands at the window start, so it shows from the
        // group's first frame, on a new inner track (inner track 0 is busy there).
        let early = try await doc.paste(payload, origin: nil, track: nil, at: Self.s(0.5), group: gid)
        let e = try #require(doc.project.tracks[0].clips.first { $0.id == gid })
        #expect(e.tracks.count == 2 && e.tracks[1].clips.map(\.id) == early)
        #expect(e.tracks[1].clips.first.map { Double($0.start) } == e.mediaStart.double, "clamped to the window start")
        #expect(e.duration == g.duration && doc.scene.duration == projectEnd)
        // Two copies of the clip stacked at the same canvas spot: one box, the inner clip's.
        let first = try #require(box(try await frame(doc, at: g.start), .green))
        #expect(abs((first[2] - first[0] + 1) - 32) <= 1)
        try doc.undoLast()
        #expect(doc.project.serialized() == original)

        // At the group's end and well past it: at the window end, hidden; nothing grows.
        for at in [end, end + Self.s(20)] {
            let late = try await doc.paste(payload, origin: nil, track: nil, at: at, group: gid)
            let l = try #require(doc.project.tracks[0].clips.first { $0.id == gid })
            #expect(l.start == g.start && l.duration == g.duration && l.mediaDuration == g.mediaDuration,
                    "group grew for a paste at \(at)")
            #expect(doc.scene.duration == projectEnd, "project grew for a paste at \(at)")
            let placed = try #require(l.tracks.flatMap(\.clips).first { $0.id == late.first })
            #expect(Double(placed.start) == (l.mediaStart.double + l.mediaDuration.double).rounded(.down), "paste at \(at) not at the window end")
            // The last group frame shows only the original clip; after the group, nothing.
            let last = try await frame(doc, at: end - Self.s(1.0 / 30))
            #expect(box(last, .green) != nil)
            #expect(box(try await frame(doc, at: end + Self.s(0.5)), .green) == nil, "hidden paste drawn")
            try doc.undoLast()
            #expect(doc.project.serialized() == original)
        }
    }
}
