import AVFoundation
import Exporter
import Foundation
import MediaEngine
import Metal
import PlayerKit
import TestGenKit
import Testing
import TSCProjKit
import UniformTypeIdentifiers
import WizRecTestSupport

// QA14-2: the session-9 workflows (start screen, editor toolbar, File ▸ Open by extension, a
// media file opened as a new project), end to end at the model level. The app target is not
// testable, so each test follows the path `WizRecDocumentController` / `EditorWindowController`
// take through PlayerKit:
//   Open/drop of media → `EditorDocumentModel.untitled` + `importAndInsert(at: 0)` per file,
//     the next one at the previous clip's end (`importFiles(_:place:at:)`);
//   toolbar Undo/Redo → `undoLast`/`redoLast`, enabled while `undoName`/`redoName` is non-nil;
//   toolbar Record → the finished recording's files `importAndPlace(_, name: "Add Recording")`;
//   toolbar Export → an `ExportQueue` job running an `ExportSession` on the model's scene;
//   start screen → `RecentProjects.list` of the saved project.

@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
@MainActor struct StartScreenWorkflowIntegrationTests {
    private func tempDir(_ tag: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("qa14-\(tag)-\(UUID().uuidString)",
                                                                           isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// `frames` frames of a 320×180 test card at 30 fps (frame numbers readable back).
    private func movie(_ url: URL, frames: Int, label: String = "Q") async throws -> TestCard {
        let card = TestCard(width: 320, height: 180, label: label)
        try await MediaWriter.writeH264(to: url, width: 320, height: 180, fps: 30, frameCount: frames) { n, ctx in
            card.draw(frame: n, fps: 30, in: ctx)
        }
        return card
    }

    private func png(_ url: URL) throws {
        try MediaWriter.writePNG(to: url, width: 64, height: 36) { ctx in
            ctx.setFillColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        }
    }

    private func clips(_ doc: EditorDocumentModel) -> [Clip] {
        doc.project.tracks.flatMap(\.clips).sorted { $0.start < $1.start }
    }

    /// Opening a movie (File ▸ Open, Finder, Dock) starts an untitled project with the movie at
    /// 0 on track 1, as one undoable step; Save As makes it a real project that the start screen
    /// lists and File ▸ Open opens as a project.
    @Test func mediaFileOpensAsNewProject() async throws {
        let dir = try tempDir("open-media")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Screen Take.mp4")
        _ = try await movie(file, frames: 45)
        #expect(OpenableFile(file) == .media)

        let doc = try EditorDocumentModel.untitled(width: 320, height: 180, in: dir)
        let temp = doc.bundle.directory.deletingLastPathComponent()
        #expect(doc.isUntitled && !doc.isDirty && doc.project.sourceBin.isEmpty)
        let id = try await doc.importAndInsert(file, at: 0)

        let placed = clips(doc)
        #expect(placed.map(\.id) == [id])
        let clip = try #require(placed.first)
        #expect(clip.start == 0)
        #expect(clip.duration == doc.project.timebase.editRate * 45 / 30, "1.5 s of media → 1.5 s clip")
        #expect(doc.project.tracks.first?.clips.map(\.id) == [id], "first track holds the clip")
        let src = try #require(doc.project.sourceBin.first?.src)
        #expect(src.hasPrefix("./media/") && src.hasSuffix("/Screen Take.mp4"), "copied into the package: \(src)")
        #expect(doc.isDirty && doc.undo.undoName == "Add to Timeline")

        let saved = dir.appendingPathComponent("Screen Take.cmproj", isDirectory: true)
        #expect(try doc.saveAs(to: saved).isEmpty)
        #expect(!doc.isUntitled && !doc.isDirty)
        #expect(!FileManager.default.fileExists(atPath: temp.path), "untitled temp folder removed after Save As")

        // The saved package is a project for File ▸ Open and a start-screen row.
        #expect(OpenableFile(saved) == .project)
        let rows = RecentProjects.list([saved, file])
        #expect(rows.map(\.name) == ["Screen Take"], "the movie itself is never a recent project")
        #expect(rows.first?.exists == true && rows.first?.modified != nil)

        let reopened = try EditorDocumentModel(url: saved)
        #expect(reopened.missing.isEmpty)
        #expect(reopened.project.tracks.flatMap(\.clips).map(\.start) == [0])
    }

    /// Several media files dropped on the start screen (or chosen in Open) go into one new
    /// project, one after another from 0; each file is its own undo step. Projects and
    /// unopenable files in the same drop are split off by extension.
    @Test func droppedMediaGoIntoOneProjectBackToBack() async throws {
        let dir = try tempDir("drop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.mp4"), b = dir.appendingPathComponent("b.MOV")
        let still = dir.appendingPathComponent("still.png")
        _ = try await movie(a, frames: 30, label: "A")
        _ = try await movie(b, frames: 15, label: "B")
        try png(still)
        let project = dir.appendingPathComponent("Existing.cmproj", isDirectory: true)
        _ = try ProjectBundle.create(at: project, width: 320, height: 180, fps: 30)
        let notes = dir.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: notes)

        let dropped = [a, project, notes, b, still]
        #expect(dropped.filter { OpenableFile($0) == .project } == [project])
        let media = dropped.filter { OpenableFile($0) == .media }
        #expect(media == [a, b, still])
        #expect(dropped.filter { OpenableFile($0) == nil } == [notes])

        let doc = try EditorDocumentModel.untitled(width: 320, height: 180, in: dir)
        let empty = doc.project.serialized()
        var t: Int64 = 0
        var ids: [Int64] = []
        for url in media {
            let id = try await doc.importAndInsert(url, at: t)
            ids.append(id)
            t = try #require(clips(doc).first { $0.id == id }).end
        }
        let placed = clips(doc)
        #expect(placed.map(\.id) == ids)
        let rate = doc.project.timebase.editRate
        #expect(placed.map(\.start) == [0, rate, rate + rate / 2], "back to back from 0")
        #expect(doc.project.tracks.filter { !$0.clips.isEmpty }.count == 1, "all on one track")
        #expect(doc.project.sourceBin.count == 3)

        // Undo (toolbar) takes them off one at a time, newest first; Redo puts them back.
        for n in stride(from: 2, through: 0, by: -1) {
            try doc.undoLast()
            #expect(clips(doc).map(\.id) == Array(ids.prefix(n)))
        }
        #expect(doc.project.serialized() == empty)
        #expect(doc.undo.undoName == nil, "toolbar Undo disabled again")
        for n in 1...3 {
            try doc.redoLast()
            #expect(clips(doc).map(\.id) == Array(ids.prefix(n)))
        }
        #expect(doc.undo.redoName == nil, "toolbar Redo disabled again")
    }

    /// Toolbar state on a new project, then Import (bin only), Undo/Redo names, and Export
    /// through the export queue to a decodable movie with the right frames.
    @Test func toolbarImportUndoRedoExport() async throws {
        let dir = try tempDir("toolbar")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("take.mp4")
        let card = try await movie(file, frames: 30)
        let doc = try EditorDocumentModel.untitled(width: 320, height: 180, in: dir)
        #expect(doc.undo.undoName == nil && doc.undo.redoName == nil, "Undo and Redo start disabled")

        // Import: media bin only, timeline untouched.
        let source = try await doc.importMedia(file)
        #expect(doc.project.source(id: source) != nil && clips(doc).isEmpty)
        #expect(doc.undo.undoName == "Import Media")
        try doc.undoLast()
        #expect(doc.project.sourceBin.isEmpty && doc.undo.redoName == "Import Media")
        try doc.redoLast()
        #expect(doc.project.source(id: source) != nil && doc.undo.redoName == nil)

        // Place it, then Export the project (one queue job, as the toolbar's Export sheet does).
        _ = try doc.insertSource(source, at: 0)
        #expect(doc.undo.undoName != nil)
        var settings = ExportSettings(format: .mp4(codec: "h264", bitrate: nil))
        settings.includeAudio = false
        let scene = doc.scene, audio = doc.audioScene
        let queue = ExportQueue { _, output, progress in
            let session = ExportSession(scene: scene, audio: audio, pool: MediaPool(diskCacheDirectory: nil),
                                        settings: settings, output: output)
            await session.setProgressHandler(progress)
            try await session.run()
            progress(1)
        }
        let base = (doc.bundle.directory.lastPathComponent as NSString).deletingPathExtension
        let out = ExportNaming.uniqueURL(directory: dir, base: base, ext: "mp4")
        #expect(out.lastPathComponent == "Untitled.mp4")
        _ = queue.add(name: "MP4", output: out)
        let idle = Task { @MainActor in await queue.waitUntilIdle() }
        try await Deadline.value(of: idle, "toolbar export to finish", seconds: 120)
        #expect(queue.jobs.map(\.state) == [.done], "\(queue.jobs.map(\.state))")

        let info = try await MovieFrameReader.info(out)
        #expect(info.width == 320 && info.height == 180)
        let frames = try await MovieFrameReader.frames(out, indices: [0, 29])
        #expect(card.decodeFrameNumber(try #require(frames[0])) == 0)
        #expect(card.decodeFrameNumber(try #require(frames[29])) == 29)
    }

    /// Toolbar Record: a finished recording (screen movie and mic audio written into the
    /// project's `recordings/<ts>/`) is placed at the recording's start, stacked on free tracks,
    /// referenced in place (never copied to `media/`), as one "Add Recording" step.
    @Test func recordingIsAddedInPlaceAsOneStep() async throws {
        let dir = try tempDir("record")
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try EditorDocumentModel.untitled(width: 320, height: 180, in: dir)
        let folder = doc.bundle.directory.appendingPathComponent("recordings/1761000000.000000", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let screen = folder.appendingPathComponent("screen.mp4"), mic = folder.appendingPathComponent("mic.wav")
        _ = try await movie(screen, frames: 30, label: "R")
        try AudioSignals.writeWAV(AudioSignals.pinkNoise(seconds: 1, lufs: -23), to: mic)

        let start = doc.project.timebase.editRate / 2
        let ids = try await doc.importAndPlace([screen, mic], at: start, name: "Add Recording")
        #expect(ids.count == 2)
        #expect(doc.undo.undoName == "Add Recording")
        let placed = doc.project.tracks.flatMap(\.clips)
        #expect(Set(placed.map(\.id)) == Set(ids))
        #expect(placed.allSatisfy { $0.start == start })
        let tracks = ids.compactMap { id in doc.project.tracks.firstIndex { $0.clips.contains { $0.id == id } } }
        #expect(tracks.count == 2 && tracks[0] != tracks[1], "screen and mic on separate tracks: \(tracks)")
        let srcs = doc.project.sourceBin.map(\.src).sorted()
        #expect(srcs == ["./recordings/1761000000.000000/mic.wav", "./recordings/1761000000.000000/screen.mp4"],
                "\(srcs)")
        let media = doc.bundle.directory.appendingPathComponent("media", isDirectory: true)
        let copied = FileManager.default.enumerator(atPath: media.path)?.allObjects.compactMap { $0 as? String } ?? []
        #expect(!copied.contains { $0.hasSuffix("screen.mp4") || $0.hasSuffix("mic.wav") }, "copied into media/: \(copied)")

        try doc.undoLast()
        #expect(doc.project.tracks.flatMap(\.clips).isEmpty && doc.project.sourceBin.isEmpty)
        #expect(FileManager.default.fileExists(atPath: screen.path), "undo keeps the recording's files")
    }
}

/// File ▸ Open decides by extension (`OpenableFile`) on real files on disk, whatever type
/// Launch Services gives them: with Camtasia installed, `.cmproj`/`.tscproj` resolve to its
/// declared types, which conform to nothing WizRec filters on.
@Suite struct OpenByExtensionIntegrationTests {
    @Test func filesOnDiskOpenByExtensionWhateverTheirSystemType() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qa14-open-\(UUID().uuidString)",
                                                                             isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let package = dir.appendingPathComponent("Lesson 1.cmproj", isDirectory: true)
        _ = try ProjectBundle.create(at: package, width: 320, height: 180, fps: 30)
        let loose = dir.appendingPathComponent("Loose.TSCPROJ")
        try FileManager.default.copyItem(at: package.appendingPathComponent("project.tscproj"), to: loose)
        let movie = dir.appendingPathComponent("clip.mov"), text = dir.appendingPathComponent("readme.md")
        try Data().write(to: movie)
        try Data("x".utf8).write(to: text)

        for url in [package, loose] {
            let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType
            print("open by extension: \(url.lastPathComponent) → system type \(type?.identifier ?? "none")")
            #expect(OpenableFile(url) == .project, "\(url.lastPathComponent) (system type \(type?.identifier ?? "none"))")
            // A trailing slash (folders from a drop) changes nothing.
            #expect(OpenableFile(URL(fileURLWithPath: url.path + "/")) == .project)
        }
        #expect(OpenableFile(movie) == .media, "decided by name: an empty .mov still offers to open")
        #expect(OpenableFile(text) == nil)
        // The package is a folder: the start screen and Open treat it as one file.
        #expect(RecentProjects.list([package]).map(\.name) == ["Lesson 1"])
    }

    /// Where another app declares the project extensions (Camtasia), its types do not conform to
    /// movie/image, so a content-type filter would grey projects out; `OpenableFile` still opens.
    @Test(arguments: ["cmproj", "tscproj"])
    func projectExtensionsNeedNoTypeDeclaration(_ ext: String) {
        let type = UTType(filenameExtension: ext)
        if let type {
            print("open by extension: .\(ext) is \(type.identifier) (dynamic: \(type.isDynamic))")
            #expect(!type.conforms(to: .audiovisualContent) && !type.conforms(to: .image))
        }
        #expect(OpenableFile(URL(fileURLWithPath: "/nonexistent/p.\(ext)")) == .project)
    }
}
