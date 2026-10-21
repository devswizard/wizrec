import CoreGraphics
import CoreMedia
import Foundation
import MediaEngine
import RenderEngine
import TestGenKit
import Testing
import TimelineEngine
import TSCProjKit
@testable import PlayerKit

/// A fresh temp folder per test; every write in these tests stays inside it.
private func tempDir(_ name: String = #function) throws -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("wizrec-editor-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// 2 s of 640×360 h264 at 30 fps.
private func writeClip(_ url: URL, frames: Int = 60) async throws {
    try await MediaWriter.writeH264(to: url, width: 640, height: 360, fps: 30, frameCount: frames) { n, ctx in
        ctx.setFillColor(CGColor(red: Double(n % 30) / 30, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
    }
}

private func writeImage(_ url: URL) throws {
    try MediaWriter.writePNG(to: url, width: 320, height: 200) { ctx in
        ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
    }
}

@Suite struct ChangeTrackerTests {
    @Test func performUndoRedoSave() {
        var t = ChangeTracker()
        #expect(!t.isDirty)
        t.performed()
        #expect(t.isDirty)
        t.undid()
        #expect(!t.isDirty)
        t.redid()
        #expect(t.isDirty)
        t.saved()
        #expect(!t.isDirty)
        t.undid()
        #expect(t.isDirty)        // undo past the save point
        t.redid()
        #expect(!t.isDirty)       // back at the saved state
    }

    @Test func newEditAfterUndoingPastSaveIsDirtyForever() {
        var t = ChangeTracker()
        t.performed(); t.performed()
        t.saved()                 // saved at 2
        t.undid(); t.undid()      // 0
        t.performed()             // branch: saved state unreachable
        #expect(t.isDirty)
        t.undid()
        #expect(t.isDirty)        // position 0 again, but the save was at the lost branch
        t.performed(count: 2)
        #expect(t.isDirty)
        t.saved()
        #expect(!t.isDirty)
    }

    @Test func multiplePerforms() {
        var t = ChangeTracker()
        t.performed(count: 3)
        t.saved()
        t.performed(count: 0)
        #expect(!t.isDirty)
        t.undid()
        #expect(t.isDirty)
    }
}

@Suite struct SourceDescriptorTests {
    @Test func movieMapsToVideoTrack() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip.mp4")
        try await writeClip(url)
        let info = try await MediaPool().probe(url)
        let d = SourceDescriptor(info: info, src: "./media/1/clip.mp4", lastModified: Date(timeIntervalSince1970: 0))
        #expect(d.src == "./media/1/clip.mp4")
        #expect(d.tracks.count == 1)
        let v = try #require(d.tracks.first)
        #expect(v.type == 0)
        #expect(v.width == 640 && v.height == 360)
        #expect(v.sampleRate == Rational(30))
        #expect(v.editRate > 0)
        #expect(abs(Double(v.rangeEnd) / Double(v.editRate) - 2.0) < 0.05)
        #expect(abs(Double(d.naturalDuration(editRate: 705_600_000)) / 705_600_000 - 2.0) < 0.05)
    }

    @Test func imageMapsToStillTrack() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("still.png")
        try writeImage(url)
        let info = try await MediaPool().probe(url)
        let d = SourceDescriptor(info: info, src: "./still.png")
        #expect(d.tracks == [SourceDescriptor.Track(type: 1, editRate: 600, rangeEnd: 1, width: 320, height: 200,
                                                     sampleRate: Rational(0), bitDepth: 0, channelCount: 0)])
        #expect(d.naturalDuration(editRate: 705_600_000) == 5 * 705_600_000)
    }

    @Test func shaderBackgroundsPlaceForSixtySeconds() {
        // A background dropped on the timeline becomes a 60 s clip [obs, shader-backgrounds.md SH2].
        let d = SourceDescriptor(src: "./bg.tscshadervid", lastModified: Date(), tracks: [
            SourceDescriptor.Track(type: 0, editRate: 30, rangeEnd: Int64.max, width: 1920, height: 1080,
                                   sampleRate: Rational(30), bitDepth: 32, channelCount: 0)])
        #expect(d.naturalDuration(editRate: 705_600_000) == 60 * 705_600_000)
    }

    @Test func probeMetadataWins() {
        let info = MediaInfo(url: URL(fileURLWithPath: "/r.trec"), kind: .recording, streams: [
            StreamInfo(index: 0, kind: .video, codec: "tscc2", pixelSize: CGSize(width: 3024, height: 1964),
                       nominalFrameRate: 5.3352, duration: CMTime(value: 1_132_415, timescale: 44100),
                       timescale: 44100, length: 1_132_415, frameRate: Rational(6669, 1250), bitDepth: 24),
            StreamInfo(index: 1, kind: .audio, codec: "aac", sampleRate: 44100, channelCount: 1,
                       duration: CMTime(value: 1_133_222, timescale: 44100),
                       timescale: 44100, length: 1_133_222, bitDepth: 16),
        ], duration: CMTime(value: 1_133_222, timescale: 44100))
        let d = SourceDescriptor(info: info, src: "./recordings/1/r.trec", lastModified: Date())
        #expect(d.tracks[0] == SourceDescriptor.Track(type: 0, editRate: 44100, rangeEnd: 1_132_415, width: 3024,
                                                       height: 1964, sampleRate: Rational(6669, 1250), bitDepth: 24,
                                                       channelCount: 0))
        #expect(d.tracks[1] == SourceDescriptor.Track(type: 2, editRate: 44100, rangeEnd: 1_133_222, width: 0, height: 0,
                                                       sampleRate: Rational(44100), bitDepth: 16, channelCount: 1))
    }

    @Test func audioAndOddRates() {
        let info = MediaInfo(url: URL(fileURLWithPath: "/x.m4a"), kind: .movie, streams: [
            StreamInfo(index: 0, kind: .video, codec: "h264", pixelSize: CGSize(width: 1920, height: 1080),
                       nominalFrameRate: 60000.0 / 1001, duration: CMTime(value: 1_253_252, timescale: 60000)),
            StreamInfo(index: 1, kind: .other, codec: "tmcd", duration: .zero),
            StreamInfo(index: 2, kind: .audio, codec: "aac", sampleRate: 48000, channelCount: 2,
                       duration: CMTime(seconds: 10, preferredTimescale: 48000)),
        ], duration: CMTime(seconds: 21, preferredTimescale: 600))
        let d = SourceDescriptor(info: info, src: "x", lastModified: Date())
        #expect(d.tracks.count == 2)                   // tmcd skipped: index stays = trackNumber
        #expect(d.tracks[0].editRate == 60000 && d.tracks[0].rangeEnd == 1_253_252)
        #expect(d.tracks[0].sampleRate == Rational(2997, 50))
        #expect(d.tracks[1].type == 2 && d.tracks[1].editRate == 48000 && d.tracks[1].rangeEnd == 480_000)
        #expect(d.tracks[1].channelCount == 2 && d.tracks[1].bitDepth == 0)
    }
}

@Suite struct RelinkMatcherTests {
    @Test func matchesByNameAndPrefersLongerSuffix() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        for p in ["a/Rec 1.trec", "b/media/123/Rec 1.trec", "c/Clip.MP4", "c/other.mov"] {
            let u = dir.appendingPathComponent(p)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0]).write(to: u)
        }
        let missing = [
            MissingMedia(id: 1, src: "./media/123/Rec 1.trec", path: ""),
            MissingMedia(id: 2, src: "C:\\Users\\me\\Videos\\clip.mp4", path: ""),
            MissingMedia(id: 3, src: "./media/9/nothere.wav", path: ""),
        ]
        let m = RelinkMatcher.matches(for: missing, in: dir)
        #expect(m[1]?.path.hasSuffix("b/media/123/Rec 1.trec") == true)
        #expect(m[2]?.lastPathComponent == "Clip.MP4")
        #expect(m[3] == nil)
    }

    @Test func projectPathIsRelativeInsideBundle() {
        let b = URL(fileURLWithPath: "/tmp/x/P.cmproj")
        #expect(EditorDocumentModel.projectPath(for: URL(fileURLWithPath: "/tmp/x/P.cmproj/media/1/a.mp4"), bundleDirectory: b)
                == "./media/1/a.mp4")
        #expect(EditorDocumentModel.projectPath(for: URL(fileURLWithPath: "/tmp/elsewhere/a.mp4"), bundleDirectory: b)
                == "/tmp/elsewhere/a.mp4")
    }
}

@MainActor @Suite struct EditorDocumentTests {
    /// New project → import → place → move → save → reopen, all in a temp dir.
    @Test func importPlaceMoveSaveReopen() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clipURL = dir.appendingPathComponent("clip.mp4")
        try await writeClip(clipURL)

        let doc = try EditorDocumentModel.untitled(in: dir)
        #expect(doc.isUntitled)
        #expect(!doc.isDirty)
        var changes = 0
        doc.onChange = { changes += 1 }

        let clipID = try await doc.importAndInsert(clipURL, at: 0)
        #expect(doc.isDirty)
        #expect(doc.undo.undoName == "Add to Timeline")
        #expect(doc.project.sourceBin.count == 1)
        let src = try #require(doc.project.sourceBin.first?.src)
        #expect(src.hasPrefix("./media/") && src.hasSuffix("/clip.mp4"))
        #expect(doc.missing.isEmpty)
        #expect(doc.scene.duration > 0)
        #expect(changes == 1)

        // Move it on the canvas (one undo step for both axes).
        let insp = try #require(ClipInspection.make(project: doc.project, clipID: clipID, playhead: 0))
        #expect(insp.visualClipID == clipID)
        try doc.set(insp.changes(.positionX, 120) + insp.changes(.positionY, -40))
        #expect(doc.undo.undoName == "Change Property")
        let moved = try #require(ClipInspection.make(project: doc.project, clipID: clipID, playhead: 0))
        #expect(moved.values[.positionX] == 120 && moved.values[.positionY] == -40)
        #expect(doc.scene.evaluate(at: 0).layers.first?.transform.tx == 120)

        // Save As (first save of an untitled project) moves it out of the temp folder.
        let target = dir.appendingPathComponent("Saved.cmproj")
        let lost = try doc.saveAs(to: target)
        #expect(lost.isEmpty)
        #expect(!doc.isUntitled && !doc.isDirty)
        #expect(doc.bundle.directory.standardizedFileURL == target.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent(String(src.dropFirst(2))).path))

        // Undo history survives Save As; undo then redo returns to clean.
        try doc.undoLast()
        #expect(doc.isDirty)
        try doc.redoLast()
        #expect(!doc.isDirty)

        // Second save keeps a backup of the first.
        try doc.set(insp.changes(.opacity, 0.5))
        try doc.save()
        #expect(!doc.isDirty)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("project.tscproj.wizrec-backup").path))

        let reopened = try EditorDocumentModel(url: target)
        #expect(reopened.missing.isEmpty)
        let r = try #require(ClipInspection.make(project: reopened.project, clipID: clipID, playhead: 0))
        #expect(r.values[.positionX] == 120 && r.values[.positionY] == -40 && r.values[.opacity] == 0.5)
        let reopenedClips: Int = reopened.project.tracks.flatMap(\.clips).count
        #expect(reopenedClips == 1)
    }

    @Test func previewIsOneUndoStep() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let img = dir.appendingPathComponent("still.png")
        try writeImage(img)
        let doc = try EditorDocumentModel.untitled(in: dir)
        let clip = try await doc.importAndInsert(img, at: 0)
        let before = doc.project.serialized()
        let i = try #require(ClipInspection.make(project: doc.project, clipID: clip, playhead: 0))
        for v in stride(from: 0.9, through: 0.3, by: -0.1) { try doc.preview(i.changes(.opacity, v)) }
        #expect(doc.isPreviewing)
        #expect(doc.undo.undoName == "Add to Timeline")   // nothing recorded yet
        try doc.commitPreview()
        #expect(!doc.isPreviewing)
        #expect(doc.undo.undoName == "Change Property")
        let after = try #require(ClipInspection.make(project: doc.project, clipID: clip, playhead: 0))
        #expect(abs((after.values[.opacity] ?? 0) - 0.3) < 1e-9)
        try doc.undoLast()
        #expect(doc.project.serialized() == before)

        // Cancel restores without a step.
        try doc.preview(i.changes(.opacity, 0.1))
        doc.cancelPreview()
        #expect(doc.project.serialized() == before)
    }

    @Test func externalPerformsCountAsDirty() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try EditorDocumentModel.untitled(in: dir)
        try doc.undo.perform(AddTrack(at: 1))           // e.g. a timeline gesture
        doc.syncWithUndoStack()
        #expect(doc.isDirty)
        #expect(doc.project.tracks.count == 3)          // a new project has two tracks (TL15-1)
        try doc.undoLast()
        #expect(!doc.isDirty)
        #expect(doc.project.tracks.count == 2)
    }

    @Test func placementAvoidsOverlapAndAddsTrack() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let img = dir.appendingPathComponent("still.png")
        try writeImage(img)
        let doc = try EditorDocumentModel.untitled(in: dir)
        let first = try await doc.importAndInsert(img, at: 0)
        let source = try #require(doc.project.sourceBin.first?.id)
        // Drop rules (ui-workflow.md §4, DropRules): 3 s into the 5 s image is past the insert
        // window, so the busy timeline drop goes on the lowest higher track with room: the new
        // project's empty track 1 (TL15-1).
        let second = try doc.insertSource(source, at: 3 * 705_600_000, track: 0)
        #expect(doc.project.tracks.count == 2)
        #expect(doc.project.tracks[0].clips.map(\.id) == [first])
        #expect(doc.project.tracks[1].clips.map(\.id) == [second])
        #expect(doc.undo.undoName == "Add to Timeline")
        // With every higher track busy: a new top track, removed again with the clip on undo.
        let third = try doc.insertSource(source, at: 4 * 705_600_000, track: 0)
        #expect(doc.project.tracks.count == 3)
        #expect(doc.project.tracks[2].clips.map(\.id) == [third])
        try doc.undoLast()
        #expect(doc.project.tracks.count == 2)          // track and clip removed together
        try doc.undoLast()
        #expect(doc.project.tracks[1].clips.isEmpty)
        // 1 s in (inside the insert window): inserted at the image's start, the image pushed right.
        let inserted = try doc.insertSource(source, at: 705_600_000, track: 0)
        #expect(doc.project.tracks.count == 2)
        #expect(doc.project.tracks[0].clips.map(\.id) == [inserted, first])
        #expect(doc.project.tracks[0].clips.first?.start == 0)
        #expect(doc.project.tracks[0].clips.last?.start == doc.project.tracks[0].clips.first?.end)
        try doc.undoLast()
        let fourth = try doc.insertSource(source, at: 5 * 705_600_000, track: 0)    // free after the first
        #expect(doc.project.tracks[0].clips.map(\.id).contains(fourth))
    }

    @Test func severalFilesStackInOneStep() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appendingPathComponent("screen.mp4"), img = dir.appendingPathComponent("cam.png")
        try await writeClip(clip)
        try writeImage(img)
        let doc = try EditorDocumentModel.untitled(in: dir)
        // A file already inside the bundle (as the recorder writes it) is referenced, not copied.
        let rec = doc.bundle.directory.appendingPathComponent("recordings/1792384811.000000", isDirectory: true)
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: clip, to: rec.appendingPathComponent("screen.mp4"))
        let ids = try await doc.importAndPlace([rec.appendingPathComponent("screen.mp4"), img], at: 0, name: "Add Recording")
        #expect(ids.count == 2)
        #expect(doc.project.sourceBin.map(\.src).first == "./recordings/1792384811.000000/screen.mp4")
        #expect(doc.project.tracks.count == 2)
        #expect(doc.project.tracks[0].clips.map(\.id) == [ids[0]])
        #expect(doc.project.tracks[1].clips.map(\.id) == [ids[1]])
        #expect(doc.undo.undoName == "Add Recording")
        try doc.undoLast()
        #expect(doc.project.sourceBin.isEmpty && doc.project.tracks.count == 2)
        try doc.redoLast()
        #expect(doc.project.tracks.flatMap(\.clips).map(\.id).sorted() == ids.sorted())
    }

    @Test func relinkAllFromFolder() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clipURL = dir.appendingPathComponent("clip.mp4")
        try await writeClip(clipURL)
        let doc = try EditorDocumentModel.untitled(in: dir)
        _ = try await doc.importAndInsert(clipURL, at: 0)
        let target = dir.appendingPathComponent("P.cmproj")
        try doc.saveAs(to: target)
        // Simulate a project from another computer: its media folder is gone.
        try FileManager.default.removeItem(at: target.appendingPathComponent("media"))
        let away = try EditorDocumentModel(url: target)
        #expect(away.missing.count == 1)
        let ids = try await away.relinkAll(in: dir)
        #expect(ids.count == 1)
        #expect(away.missing.isEmpty)
        #expect(away.project.sourceBin.first?.src == clipURL.standardizedFileURL.resolvingSymlinksInPath().path)
        #expect(away.undo.undoName == "Relink Media")
        #expect(away.isDirty)
    }

    @Test func untitledDiscardRemovesTempFolder() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try EditorDocumentModel.untitled(in: dir)
        let folder = doc.bundle.directory.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: folder.path))
        doc.discardUntitled()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func replaceSceneKeepsPlayhead() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let img = dir.appendingPathComponent("still.png")
        try writeImage(img)
        let doc = try EditorDocumentModel.untitled(in: dir)
        _ = try await doc.importAndInsert(img, at: 0)
        let engine = doc.makeEngine(audio: false)
        doc.onChange = { engine.replaceScene(doc.scene, audioScene: doc.audioScene) }
        engine.seek(toTicks: 705_600_000 * 2)
        let frame = engine.currentFrame
        let source = try #require(doc.project.sourceBin.first?.id)
        _ = try doc.insertSource(source, at: 5 * 705_600_000, track: 0)
        #expect(engine.grid.duration == 10 * 705_600_000)
        #expect(engine.currentFrame == frame)
        try doc.undoLast()
        #expect(engine.grid.duration == 5 * 705_600_000)
        #expect(engine.currentFrame == frame)
    }
}

@Suite struct HitTestTests {
    @Test func canvasPointMapping() {
        let view = CGSize(width: 960, height: 540), canvas = CGSize(width: 1920, height: 1080)
        #expect(CanvasHitTest.canvasPoint(CGPoint(x: 480, y: 270), viewSize: view, canvasSize: canvas) == .zero)
        #expect(CanvasHitTest.canvasPoint(CGPoint(x: 960, y: 0), viewSize: view, canvasSize: canvas) == CGPoint(x: 960, y: 540))
        // Letterboxed: a wide view has bars left/right.
        let wide = CGSize(width: 1200, height: 540)
        #expect(CanvasHitTest.canvasPoint(CGPoint(x: 50, y: 270), viewSize: wide, canvasSize: canvas) == nil)
    }

    @Test func layerContainsHonoursTransformAndCrop() {
        var l = Layer(clipID: 1, content: .unsupported(type: "x"), size: CGSize(width: 200, height: 100),
                      transform: CGAffineTransform(translationX: 100, y: 0))
        #expect(CanvasHitTest.contains(l, CGPoint(x: 190, y: 40)))
        #expect(!CanvasHitTest.contains(l, CGPoint(x: -10, y: 0)))
        l.geometryCrop = Insets(left: 0.5)
        #expect(!CanvasHitTest.contains(l, CGPoint(x: 50, y: 0)))
        #expect(CanvasHitTest.contains(l, CGPoint(x: 150, y: 0)))
    }
}
