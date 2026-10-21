import CoreGraphics
import Foundation
import TestGenKit
import Testing
import TimelineEngine
import TSCProjKit
import RenderEngine
@testable import PlayerKit

// QA15-1: the session-11 edit features end to end through the editor's document model, the
// render plan and save/reopen. The app target is not testable, so each test takes the path
// `EditorWindowController` takes, with the same arguments:
//   track header ▸ Move Track Up/Down → `MoveTrack(from: t, to: t ± 1)`; Rename → `RenameTrack`;
//   Timeline ▸ Split All Tracks at Playhead → `SplitAllTracks(at: playhead)`, right halves selected;
//   Edit ▸ Select Clips at Playhead → `TimelineSelection.clips(at: playhead)`;
//   Animations tile dropped on a clip → `AddAnimation(clipID:, preset:, at: playhead)`;
//     Animations double-click → one `CompoundCommand` of `AddAnimation` per selected clip;
//   canvas handles → `ClipInspection.changes` from `CanvasGeometry.scale/rotation/crop`,
//     `preview` while dragging, `commitPreview` on mouse-up; canvas Scale ▸ Fit → `set`.

@Suite(.serialized) @MainActor struct Session11EditIntegrationTests {
    struct Fixture {
        let dir: URL
        let doc: EditorDocumentModel
        let still: URL
        let wav: URL
        func cleanUp() { try? FileManager.default.removeItem(at: dir) }
    }

    func fixture(_ tag: String) throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qa17-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let still = dir.appendingPathComponent("still.png")
        try MediaWriter.writePNG(to: still, width: 160, height: 90) { ctx in
            ctx.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
        }
        let wav = dir.appendingPathComponent("voice.wav")
        try AudioSignals.writeWAV(AudioSignals.pinkNoise(seconds: 2, lufs: -23), to: wav)
        let doc = try EditorDocumentModel.untitled(width: 640, height: 360, in: dir)
        return Fixture(dir: dir, doc: doc, still: still, wav: wav)
    }

    func s(_ doc: EditorDocumentModel, _ seconds: Double) -> Int64 { doc.project.timebase.ticks(seconds: seconds) }

    func trackOf(_ id: Int64, _ doc: EditorDocumentModel) -> Int? {
        doc.project.tracks.firstIndex { $0.clips.contains { $0.id == id } }
    }

    /// Ids of the layers drawn at `seconds`, bottom first.
    func drawn(_ doc: EditorDocumentModel, at seconds: Double) -> [Int64] {
        doc.scene.evaluate(at: s(doc, seconds)).layers.map(\.clipID)
    }

    func layer(_ id: Int64, _ doc: EditorDocumentModel, at seconds: Double) -> Layer? {
        doc.scene.evaluate(at: s(doc, seconds)).layers.first { $0.clipID == id }
    }

    // MARK: Tracks

    /// Move Track Up/Down swaps the draw order; the track's name and lock travel with it, also
    /// through Save As and reopen; undo returns the exact bytes.
    @Test func moveAndRenameTrackChangeDrawOrderAndSurviveSave() async throws {
        let f = try fixture("tracks")
        defer { f.cleanUp() }
        let doc = f.doc
        let src = try await doc.importMedia(f.still)
        let a = try doc.insertSource(src, at: 0)                 // canvas drop: track 0
        let b = try doc.insertSource(src, at: 0)                 // track 1
        #expect([a, b].map { trackOf($0, doc) } == [0, 1])
        #expect(drawn(doc, at: 1) == [a, b], "b on top")
        let before = doc.project.serialized()

        try doc.perform(RenameTrack(track: 1, name: "Webcam"))
        try doc.perform(SetTrackFlag(track: 1, .locked, true))
        try doc.perform(MoveTrack(from: 1, to: 0))               // track 1 ▸ Move Track Down
        #expect([a, b].map { trackOf($0, doc) } == [1, 0])
        #expect(drawn(doc, at: 1) == [b, a], "a on top now")
        let attrs = doc.project.timeline?.trackAttributes ?? []
        #expect(attrs.first?["ident"]?.string == "Webcam")
        #expect(attrs.first?["metadata"]?.object?["IsLocked"]?.string == "True")
        #expect(doc.project.tracks.map(\.index) == [0, 1], "trackIndex renumbered")
        #expect(doc.undo.undoName == "Move Track")

        let saved = f.dir.appendingPathComponent("Tracks.cmproj", isDirectory: true)
        #expect(try doc.saveAs(to: saved).isEmpty)
        let reopened = try EditorDocumentModel(url: saved)
        #expect(reopened.project.serialized() == doc.project.serialized())
        #expect(reopened.scene.evaluate(at: s(doc, 1)).layers.map(\.clipID) == [b, a])

        for _ in 0..<3 { try doc.undoLast() }
        #expect(doc.project.serialized() == before)
    }

    // MARK: Split All Tracks, Select at Playhead

    /// Split All Tracks at 3 s: every clip strictly under the playhead on an unlocked track is
    /// split; a clip ending at 3 s and a locked track are left alone. What draws is unchanged;
    /// Select Clips at Playhead then lists the clips playing there (locked included).
    @Test func splitAllTracksSplitsWhatIsUnderThePlayhead() async throws {
        let f = try fixture("split-all")
        defer { f.cleanUp() }
        let doc = f.doc
        let still = try await doc.importMedia(f.still)
        let wav = try await doc.importMedia(f.wav)
        let a = try doc.insertSource(still, at: 0)                       // track 0, 0–5 s
        let b = try doc.insertSource(still, at: s(doc, 2))               // track 1, 2–7 s
        let c = try doc.insertSource(wav, at: s(doc, 1))                 // track 2, 1–3 s (ends at the playhead)
        let d = try doc.insertSource(still, at: 0)                       // track 3, 0–5 s
        #expect([a, b, c, d].map { trackOf($0, doc) } == [0, 1, 2, 3])
        try doc.perform(SetTrackFlag(track: 3, .locked, true))
        let at = s(doc, 3)
        #expect(TimelineSelection.clips(at: at, in: doc.project).sorted() == [a, b, d].sorted())
        let plans = [1.0, 2.5, 4.0, 6.0].map { doc.scene.evaluate(at: s(doc, $0)) }
        let before = doc.project.serialized()

        let split = SplitAllTracks(at: at)
        try doc.perform(split)
        #expect(split.rightIDs.count == 2)
        #expect(doc.undo.undoName == "Split")
        let clips = doc.project.tracks.map { $0.clips.map { [$0.start, $0.end] } }
        #expect(clips[0] == [[0, at], [at, s(doc, 5)]])
        #expect(clips[1] == [[s(doc, 2), at], [at, s(doc, 7)]])
        #expect(clips[2] == [[s(doc, 1), at]], "touching the playhead: not split")
        #expect(clips[3] == [[0, s(doc, 5)]], "locked track: not split")
        // The same pictures from the same media frames, right halves included.
        for (i, t) in [1.0, 2.5, 4.0, 6.0].enumerated() {
            let p = doc.scene.evaluate(at: s(doc, t))
            #expect(p.frameRequests == plans[i].frameRequests, "t \(t)")
            #expect(p.layers.map(\.transform) == plans[i].layers.map(\.transform), "t \(t)")
        }
        // Select Clips at Playhead after the split: the right halves and the locked clip.
        #expect(Set(TimelineSelection.clips(at: at, in: doc.project)) == Set(split.rightIDs + [d]))

        try doc.undoLast()
        #expect(doc.project.serialized() == before)
        // Nothing strictly under the playhead: the command refuses, nothing changes.
        #expect(throws: (any Error).self) { try doc.perform(SplitAllTracks(at: s(doc, 8))) }
        #expect(doc.project.serialized() == before)
    }

    // MARK: Animations

    /// An Animations tile dropped on a clip: a 1 s segment ending at the playhead, drawn by the
    /// render plan (opacity 1 before, 0 from the playhead on), kept through Save As and reopen.
    @Test func animationDropAnimatesTheRenderedLayer() async throws {
        let f = try fixture("animation")
        defer { f.cleanUp() }
        let doc = f.doc
        let src = try await doc.importMedia(f.still)
        let a = try doc.insertSource(src, at: 0)                         // 0–5 s
        #expect(AddAnimation.canApply(.noOpacity, clipID: a, in: doc.project))
        let before = doc.project.serialized()

        try doc.perform(AddAnimation(clipID: a, preset: .noOpacity, at: s(doc, 3)))
        #expect(doc.undo.undoName == "Add Animation")
        let o = [1.0, 2.0, 2.5, 3.0, 4.0].map { layer(a, doc, at: $0)?.opacity ?? -1 }
        #expect(abs(o[0] - 1) < 1e-6 && abs(o[1] - 1) < 1e-6, "before the segment: \(o)")
        #expect(o[2] > 0.01 && o[2] < 0.99, "mid segment: \(o[2])")
        #expect(o[3] < 1e-6 && o[4] < 1e-6, "from the playhead on: \(o)")

        let saved = f.dir.appendingPathComponent("Anim.cmproj", isDirectory: true)
        #expect(try doc.saveAs(to: saved).isEmpty)
        let reopened = try EditorDocumentModel(url: saved)
        let o2 = [1.0, 2.5, 4.0].map { t in
            reopened.scene.evaluate(at: s(doc, t)).layers.first { $0.clipID == a }?.opacity ?? -1
        }
        #expect(o2 == [o[0], o[2], o[4]])

        try doc.undoLast()
        #expect(doc.project.serialized() == before)
    }

    /// The Animations double-click: Scale Up on every selected clip with a picture (an audio
    /// clip is skipped by `canApply`), one undo step; the layers end 1.25× larger.
    @Test func animationDoubleClickAnimatesEverySelectedClip() async throws {
        let f = try fixture("animation-multi")
        defer { f.cleanUp() }
        let doc = f.doc
        let still = try await doc.importMedia(f.still)
        let wav = try await doc.importMedia(f.wav)
        let a = try doc.insertSource(still, at: 0)
        let b = try doc.insertSource(still, at: 0)
        let c = try doc.insertSource(wav, at: 0)
        let selection = [a, b, c]
        let ids = selection.sorted().filter { AddAnimation.canApply(.scaleUp, clipID: $0, in: doc.project) }
        #expect(ids == [a, b].sorted())
        let at = s(doc, 2)
        let w0 = [a, b].map { layer($0, doc, at: 0.5)?.transform.a ?? 0 }
        let before = doc.project.serialized()
        let steps: [CompoundCommand.Builder] = ids.map { id in { _, _ in AddAnimation(clipID: id, preset: .scaleUp, at: at) } }
        try doc.perform(CompoundCommand(name: "Add Animation", steps))
        let w1 = [a, b].map { layer($0, doc, at: 3)?.transform.a ?? 0 }
        for (x0, x1) in zip(w0, w1) { #expect(abs(x1 / x0 - 1.25) < 1e-6, "\(x0) → \(x1)") }
        try doc.undoLast()
        #expect(doc.project.serialized() == before, "one undo step for all clips")
    }

    // MARK: Canvas handles

    /// Dragging the canvas handles: a corner drag doubles the scale, the rotation knob turns the
    /// clip 90°, a crop-mode edge crops a quarter; each drag previews without undo steps and
    /// commits one on mouse-up; the frame the handles draw follows. Scale ▸ Fit fills the
    /// canvas height.
    @Test func canvasHandleDragsCommitOneUndoStepEach() async throws {
        let f = try fixture("handles")
        defer { f.cleanUp() }
        let doc = f.doc
        let src = try await doc.importMedia(f.still)
        let a = try doc.insertSource(src, at: 0)
        let t = s(doc, 1)
        func frame() throws -> CanvasFrame {
            try #require(CanvasGeometry.frame(of: a, plan: doc.scene.evaluate(at: t), project: doc.project))
        }
        func inspection() throws -> ClipInspection {
            try #require(ClipInspection.make(project: doc.project, clipID: a, playhead: t))
        }
        func width(_ fr: CanvasFrame) -> Double { hypot(fr.corners[1].x - fr.corners[0].x, fr.corners[1].y - fr.corners[0].y) }
        let before = doc.project.serialized()
        let f0 = try frame()
        let w0 = width(f0)
        #expect(w0 > 0)

        // Corner: from the top-right corner to twice as far from the centre, in two drag steps.
        let i0 = try inspection()
        let corner = f0.corners[2]
        let far = CGPoint(x: f0.center.x + 2 * (corner.x - f0.center.x), y: f0.center.y + 2 * (corner.y - f0.center.y))
        let mid = CGPoint(x: (corner.x + far.x) / 2, y: (corner.y + far.y) / 2)
        let undoCount = doc.undo.changeCount
        for p in [mid, far] {
            let v = CanvasGeometry.scale(from: i0.values[.scale] ?? 1, center: f0.center, start: corner, current: p)
            try doc.preview(i0.changes(.scale, v))
        }
        #expect(doc.isPreviewing && doc.undo.changeCount == undoCount, "no undo step while dragging")
        try doc.commitPreview()
        #expect(abs(width(try frame()) / w0 - 2) < 1e-3)
        let afterScale = doc.project.serialized()

        // Rotation knob: a quarter turn counter-clockwise about the centre.
        let f1 = try frame(), i1 = try inspection()
        let start = CGPoint(x: f1.center.x, y: f1.center.y + 100), end = CGPoint(x: f1.center.x - 100, y: f1.center.y)
        let r = CanvasGeometry.rotation(from: i1.values[.rotation] ?? 0, center: f1.center, start: start, current: end, snap: true)
        #expect(abs(r - .pi / 2) < 1e-6)
        try doc.preview(i1.changes(.rotation, r))
        try doc.commitPreview()
        let f2 = try frame()
        let bottom = CGVector(dx: f2.corners[1].x - f2.corners[0].x, dy: f2.corners[1].y - f2.corners[0].y)
        #expect(abs(bottom.dx) < 1e-5 * bottom.dy && bottom.dy > 0, "the bottom edge now points up: \(bottom)")
        try doc.undoLast()
        #expect(doc.project.serialized() == afterScale)

        // Crop mode: the left edge dragged a quarter of the clip's width inward.
        let f3 = try frame(), i3 = try inspection()
        let left = try #require(f3.edgeMidpoints[.left])
        let inward = CGPoint(x: left.x + w0 * 2 / 4, y: left.y)   // the clip is 2 w0 wide now
        let crop = CanvasGeometry.crop(.left, frame: f3, start: left, current: inward)
        #expect(abs(crop - 0.25) < 1e-4)
        try doc.preview(i3.changes(CanvasCropEdge.left.field, crop))
        try doc.commitPreview()
        #expect(abs(width(try frame()) / (2 * w0) - 0.75) < 1e-3)
        try doc.undoLast(); try doc.undoLast()
        #expect(doc.project.serialized() == before)

        // Canvas ▸ Scale ▸ Fit to Canvas: the 16:9 still fills the 640×360 canvas, centred.
        let size = try #require(CanvasGeometry.mediaSize(of: a, plan: doc.scene.evaluate(at: t), project: doc.project))
        let canvas = doc.scene.canvasSize
        let fit = min(canvas.width / size.width, canvas.height / size.height)
        let i4 = try inspection()
        try doc.set(i4.changes(.scale, fit) + i4.changes(.positionX, 0) + i4.changes(.positionY, 0))
        let f4 = try frame()
        #expect(abs(width(f4) - canvas.width) < 0.5 && abs(f4.center.x) < 1e-6 && abs(f4.center.y) < 1e-6)
    }
}
