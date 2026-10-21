import CoreGraphics
import Foundation
import TestGenKit
import Testing
import TimelineEngine
import TSCProjKit
import WizRecAssets
@testable import PlayerKit

// QA15-1: every import path of the session-10 app merge (app14) places through the drop rules
// (`DropRules` / `DropClip`, ui-workflow.md §4, group-edits.md §8.7). The app target is not
// testable, so each test takes the path `EditorWindowController` / `WizRecDocumentController`
// take through PlayerKit, with the same arguments:
//   toolbar Import, File ▸ Import Media…, canvas empty-state Import, bin "+", bin drop
//     → `importFiles(_, place: false)` → `importInSequence(place: false)`: media bin only;
//   start-screen drop / media opened as a project
//     → `importFiles(media, place: true, at: 0)` → `importInSequence(place: true, from: 0)`;
//   canvas drop → `place(_, track: nil, at: playhead)`: files `importInSequence(from: playhead)`,
//     bin items `insertSource(id, at: t)` one after another (`t` = previous clip's end);
//   timeline drop (no group open) → `place(_, track: track, at: ticks)`, same calls with `track`;
//   media-bin tile / Backgrounds library double-click → `insertSource(id)` at the playhead /
//     `placeBackground(bg, at: playhead)`;
//   finished recording → `importAndPlace(files, at: start, name: "Add Recording")`.
// Each placement is checked against `DropRules.place` on the project just before the drop.

@Suite(.serialized) @MainActor struct ImportPathPlacementIntegrationTests {
    /// A temp folder with an untitled 640×360 project and two stills (5 s clips each).
    @MainActor struct Fixture {
        let dir: URL
        let doc: EditorDocumentModel
        let still: URL
        let still2: URL
        let wav: URL
        var tb: Timebase { doc.project.timebase }
        func s(_ seconds: Double) -> Int64 { tb.ticks(seconds: seconds) }
        func cleanUp() { try? FileManager.default.removeItem(at: dir) }
    }

    func fixture(_ tag: String) throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qa16-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let still = dir.appendingPathComponent("still.png")
        let still2 = dir.appendingPathComponent("still two.png")
        for (url, red) in [(still, 1.0), (still2, 0.2)] as [(URL, CGFloat)] {
            try MediaWriter.writePNG(to: url, width: 32, height: 18) { ctx in
                ctx.setFillColor(CGColor(red: red, green: 0.3, blue: 0.1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 18))
            }
        }
        let wav = dir.appendingPathComponent("voice.wav")
        try AudioSignals.writeWAV(AudioSignals.pinkNoise(seconds: 2, lufs: -23), to: wav)
        let doc = try EditorDocumentModel.untitled(width: 640, height: 360, in: dir)
        return Fixture(dir: dir, doc: doc, still: still, still2: still2, wav: wav)
    }

    /// Where top-level clip `id` sits.
    func spot(_ id: Int64, _ doc: EditorDocumentModel) -> (track: Int, start: Int64, end: Int64)? {
        for (i, t) in doc.project.tracks.enumerated() {
            if let c = t.clips.first(where: { $0.id == id }) { return (i, c.start, c.end) }
        }
        return nil
    }

    /// What the drop rules decide for source `source` dropped at `target` on the project as it is now.
    func rule(_ doc: EditorDocumentModel, _ source: Int64, _ target: DropTarget) throws -> DropPlacement {
        let d = try DropRules.clipDuration(source: source, in: doc.project)
        return try DropRules.place(target, duration: d, in: doc.project)
    }

    /// `EditorWindowController.place(.sources(ids), track:, at:)`: each bin item in turn, the
    /// next one from the previous clip's end.
    @discardableResult
    func placeSources(_ ids: [Int64], track: Int?, at ticks: Int64,
                              _ doc: EditorDocumentModel) throws -> [Int64] {
        var t = ticks
        var out: [Int64] = []
        for id in ids {
            let clip = try doc.insertSource(id, at: t, track: track)
            if let c = doc.project.tracks.flatMap(\.clips).first(where: { $0.id == clip }) { t = c.end }
            out.append(clip)
        }
        return out
    }

    /// `true` when `p` is where clip `id` landed.
    func landed(_ id: Int64, _ p: DropPlacement, _ doc: EditorDocumentModel) -> Bool {
        guard let at = spot(id, doc) else { return false }
        return at.track == p.track && at.start == p.start
    }

    // MARK: Bin only

    /// Toolbar Import, File ▸ Import Media…, the canvas empty state's Import, the bin's "+" and
    /// drops on the bin all import into the media bin and place nothing; projects and other
    /// documents among dropped items are sorted out before import (`DroppedFiles`).
    @Test func binOnlyPathsImportWithoutPlacing() async throws {
        let f = try fixture("bin")
        defer { f.cleanUp() }
        let project = f.dir.appendingPathComponent("Other.cmproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let notes = f.dir.appendingPathComponent("notes.txt")
        try Data("not media".utf8).write(to: notes)
        let sorted = DroppedFiles([f.still, project, notes, f.wav])
        #expect(sorted.projects == [project])
        #expect(sorted.media == [f.still, f.wav])
        #expect(sorted.unsupported == [notes])
        #expect(sorted.unsupportedMessage()?.contains("notes.txt") == true)

        let before = f.doc.project.serialized()
        let r = await f.doc.importInSequence(sorted.media, place: false, from: f.s(3))
        #expect(r.placed.isEmpty && r.failures.isEmpty)
        #expect(f.doc.project.sourceBin.count == 2)
        #expect(f.doc.project.tracks.allSatisfy { $0.clips.isEmpty }, "nothing on the timeline")
        #expect(f.doc.undo.undoName == "Import Media")
        try f.doc.undoLast(); try f.doc.undoLast()
        #expect(f.doc.project.serialized() == before)
    }

    // MARK: Start screen

    /// A drop on the start screen (or media opened as a project) makes a new project with the
    /// files back to back from 0 on the bottom track: each one a canvas drop at the previous end.
    @Test func startScreenDropPlacesBackToBackFromZero() async throws {
        let f = try fixture("start")
        defer { f.cleanUp() }
        let r = await f.doc.importInSequence([f.still, f.wav, f.still2], place: true, from: 0)
        #expect(r.failures.isEmpty)
        try #require(r.placed.count == 3)
        #expect(r.placed.map(\.track) == [0, 0, 0])
        let spots = r.placed.compactMap { spot($0.clip, f.doc) }
        try #require(spots.count == 3)
        #expect(spots[0].start == 0)
        #expect(spots[1].start == spots[0].end && spots[2].start == spots[1].end, "back to back")
        #expect(spots[1].end - spots[1].start == f.s(2), "the 2 s WAV keeps its length")
        #expect(f.doc.undo.undoName == "Add to Timeline")
    }

    // MARK: Canvas

    /// A canvas drop goes at the playhead on the lowest unlocked track with room for the whole
    /// clip, else on a new top track (ui-workflow.md §4) — for bin items and for files.
    @Test func canvasDropGoesAtThePlayheadOnTheLowestTrackWithRoom() async throws {
        let f = try fixture("canvas")
        defer { f.cleanUp() }
        let doc = f.doc
        let src = try await doc.importMedia(f.still)
        let a = try placeSources([src], track: nil, at: 0, doc)[0]      // track 0, 0–5 s
        let d = try DropRules.clipDuration(source: src, in: doc.project)
        #expect(d == f.s(5) && spot(a, doc)?.track == 0)

        // Playhead 2 s: track 0 busy → the lowest track above with room (or a new top track).
        let p1 = try rule(doc, src, .canvas(playhead: f.s(2)))
        #expect(p1.track == 1 && p1.start == f.s(2))
        let b = try placeSources([src], track: nil, at: f.s(2), doc)[0]
        #expect(landed(b, p1, doc))
        // Same playhead again: tracks 0 and 1 busy → new top track 2.
        let p2 = try rule(doc, src, .canvas(playhead: f.s(2)))
        #expect(p2.rule == .newTopTrack && p2.track == 2)
        let c = try placeSources([src], track: nil, at: f.s(2), doc)[0]
        #expect(landed(c, p2, doc) && doc.project.tracks.count == 3)
        // Playhead 4 s: the clip must fit whole from 4 s; tracks 0–2 are all busy then → new top.
        let p3 = try rule(doc, src, .canvas(playhead: f.s(4)))
        #expect(p3.rule == .newTopTrack && p3.track == 3)
        // Playhead 5 s: track 0 is free from 5 s → back on the bottom track.
        let p4 = try rule(doc, src, .canvas(playhead: f.s(5)))
        #expect(p4.rule == .lowestTrackWithRoom && p4.track == 0 && p4.start == f.s(5))

        // A file dropped on the canvas: imported, then placed by the same rule.
        let r = await doc.importInSequence([f.still2], place: true, from: f.s(5))
        #expect(r.failures.isEmpty)
        let fileClip = try #require(r.placed.first?.clip)
        #expect(landed(fileClip, p4, doc))
        #expect(doc.project.sourceBin.count == 2)

        // A locked bottom track is never chosen: playhead 10 s, track 0 free there but locked.
        try doc.perform(SetTrackFlag(track: 0, .locked, true))
        let p5 = try rule(doc, src, .canvas(playhead: f.s(10)))
        #expect(p5.track != 0 && p5.start == f.s(10))
        let e = try placeSources([src], track: nil, at: f.s(10), doc)[0]
        #expect(landed(e, p5, doc))
    }

    /// Several bin items dropped on the canvas together: each one a canvas drop at the previous
    /// clip's end, so they run back to back on the lowest track with room.
    @Test func severalBinItemsOnTheCanvasRunBackToBack() async throws {
        let f = try fixture("canvas-multi")
        defer { f.cleanUp() }
        let doc = f.doc
        let src = try await doc.importMedia(f.still)
        _ = try placeSources([src], track: nil, at: f.s(3), doc)        // track 0, 3–8 s
        let ids = try placeSources([src, src], track: nil, at: 0, doc)
        let s0 = try #require(spot(ids[0], doc)), s1 = try #require(spot(ids[1], doc))
        // The first does not fit before 3 s on track 0 (5 s long) → track 1 at 0; the second at
        // 5 s: track 0 busy until 8 s → track 1 again, right after the first.
        #expect(s0.track == 1 && s0.start == 0)
        #expect(s1.track == 1 && s1.start == s0.end)
    }

    // MARK: Timeline

    /// A timeline drop (no group open): a free spot takes the clip where dropped; a busy spot
    /// within 1 s of a clip's start (and in its first half) inserts there and pushes that track;
    /// elsewhere the lowest higher track with room; with no room, a new top track (§8.7).
    @Test func timelineDropFollowsTheBusySpotRules() async throws {
        let f = try fixture("timeline")
        defer { f.cleanUp() }
        let doc = f.doc
        let src = try await doc.importMedia(f.still)
        let frame = f.tb.editRate / 30
        let a = try placeSources([src], track: 0, at: 0, doc)[0]        // track 0, 0–5 s
        #expect(spot(a, doc)?.start == 0)

        // Free spot on track 0 at 7 s: the drop's own track and time.
        let free = try rule(doc, src, .timeline(track: 0, at: .timeline(f.s(7))))
        #expect(free.rule == .target)
        let b = try placeSources([src], track: 0, at: f.s(7), doc)[0]   // track 0, 7–12 s
        #expect(landed(b, free, doc))

        // Exactly 1 s into clip a (inclusive bound): inserted at 0, a and b pushed by 5 s.
        let before = doc.project.serialized()
        let ins = try rule(doc, src, .timeline(track: 0, at: .timeline(f.s(1))))
        #expect(ins.rule == .insertAtClipStart && ins.start == 0 && ins.push == f.s(5))
        let c = try placeSources([src], track: 0, at: f.s(1), doc)[0]
        #expect(landed(c, ins, doc))
        #expect(spot(a, doc)?.start == f.s(5) && spot(b, doc)?.start == f.s(12), "that track pushed")
        try doc.undoLast()
        #expect(doc.project.serialized() == before, "one undo step")

        // One frame past the window: not an insert → the lowest higher track with room.
        let up = try rule(doc, src, .timeline(track: 0, at: .timeline(f.s(1) + frame)))
        #expect(up.rule != .insertAtClipStart && up.track >= 1 && up.start == f.s(1) + frame)
        let g = try placeSources([src], track: 0, at: f.s(1) + frame, doc)[0]
        #expect(landed(g, up, doc))
        #expect(spot(a, doc)?.start == 0, "nothing pushed")

        // Busy on every track at 2 s: a new top track.
        let top = try rule(doc, src, .timeline(track: 0, at: .timeline(f.s(2))))
        #expect(top.rule == .newTopTrack && top.track == doc.project.tracks.count)
        let h = try placeSources([src], track: 0, at: f.s(2), doc)[0]
        #expect(landed(h, top, doc))

        // The empty area above the top track: a new top track at the drop time.
        let count = doc.project.tracks.count
        let above = try placeSources([src], track: count, at: f.s(20), doc)[0]
        #expect(spot(above, doc)?.track == count && spot(above, doc)?.start == f.s(20))

        // A file dropped near a clip start inserts the same way.
        let pushTarget = try rule(doc, src, .timeline(track: 0, at: .timeline(f.s(7) + f.s(0.5))))
        #expect(pushTarget.rule == .insertAtClipStart && pushTarget.start == f.s(7))
        let r = await doc.importInSequence([f.still2], place: true, from: f.s(7.5), track: 0)
        let fileClip = try #require(r.placed.first?.clip)
        #expect(landed(fileClip, pushTarget, doc))
        #expect(spot(b, doc)?.start == f.s(12))
    }

    /// Two bin items dropped together just after a clip's start: the second goes where the first
    /// ends, which is the pushed clip's new start, so both insert and the track moves twice.
    @Test func severalBinItemsInsertTogetherAtAClipStart() async throws {
        let f = try fixture("timeline-multi")
        defer { f.cleanUp() }
        let doc = f.doc
        let src = try await doc.importMedia(f.still)
        let a = try placeSources([src], track: 0, at: 0, doc)[0]
        let ids = try placeSources([src, src], track: 0, at: f.s(0.5), doc)
        #expect(ids.compactMap { spot($0, doc)?.track } == [0, 0])
        #expect(ids.compactMap { spot($0, doc)?.start } == [0, f.s(5)])
        #expect(spot(a, doc)?.start == f.s(10), "pushed by both")
        #expect(doc.project.tracks.count == 1 || doc.project.tracks.dropFirst().allSatisfy { $0.clips.isEmpty })
    }

    // MARK: Library double-click

    /// A media-bin tile's double-click and a Backgrounds tile's double-click place at the
    /// playhead like a canvas drop (lowest track with room, else a new top track).
    @Test func libraryDoubleClickPlacesLikeACanvasDrop() async throws {
        let f = try fixture("library")
        defer { f.cleanUp() }
        let doc = f.doc
        doc.backgroundLibraryRoot = f.dir.appendingPathComponent("Library", isDirectory: true)
        let src = try await doc.importMedia(f.still)
        let bin = try placeSources([src], track: nil, at: f.s(1), doc)[0]   // tile double-click
        #expect(spot(bin, doc)?.track == 0 && spot(bin, doc)?.start == f.s(1))

        let aurora = try #require(AssetCatalog.background(id: "wizrec-aurora") as BackgroundAsset?)
        // The background (60 s) at playhead 3 s: track 0 busy → the next track with room.
        let bg = try await doc.placeBackground(aurora, at: f.s(3))
        let at = try #require(spot(bg, doc))
        #expect(at.track == 1 && at.start == f.s(3))
        #expect(at.end - at.start == f.s(60))
        #expect(doc.undo.undoName == "Add Background")
        // Again at 3 s: both busy → new top track; at 70 s: track 0 has room again.
        let bg2 = try await doc.placeBackground(aurora, at: f.s(3))
        #expect(spot(bg2, doc)?.track == 2)
        let bg3 = try await doc.placeBackground(aurora, at: f.s(70))
        #expect(spot(bg3, doc)?.track == 0 && spot(bg3, doc)?.start == f.s(70))
    }

    // MARK: Recording

    /// A finished recording's files go at the playhead where it started, stacked upward on the
    /// lowest tracks with room, as one undo step.
    @Test func recordingFilesStackOnTracksWithRoom() async throws {
        let f = try fixture("recording")
        defer { f.cleanUp() }
        let doc = f.doc
        let src = try await doc.importMedia(f.still)
        _ = try placeSources([src], track: nil, at: 0, doc)             // track 0, 0–5 s
        let before = doc.project.serialized()
        let ids = try await doc.importAndPlace([f.still2, f.wav], at: f.s(6), name: "Add Recording")
        #expect(ids.compactMap { spot($0, doc)?.track } == [0, 1], "screen on the free bottom track, audio above")
        #expect(ids.compactMap { spot($0, doc)?.start } == [f.s(6), f.s(6)])
        #expect(doc.undo.undoName == "Add Recording")
        try doc.undoLast()
        #expect(doc.project.serialized() == before)
    }
}
