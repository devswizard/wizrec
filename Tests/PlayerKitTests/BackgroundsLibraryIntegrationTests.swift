import CoreGraphics
import Foundation
import MediaEngine
import Metal
import PlayerKit
import RenderEngine
import Testing
import TestGenKit
import TimelineEngine
import TSCProjKit
import WizRecAssets

// QA9-2 / app8: the Backgrounds library tab places every WizRec background through
// `EditorDocumentModel.placeBackground` (the tab's double-click), and `.tscshadervid` files dropped
// into a group or alongside other files get the SH2 `effectDef` / `sourceEffect`
// (`docs/specs/shader-backgrounds.md` §6). End to end with undo, render and save/reopen.

@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
@MainActor struct BackgroundsLibraryIntegrationTests {
    private static let rate: Int64 = 705_600_000

    private func tempDir(_ tag: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("qa9-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func writePNG(_ url: URL) throws {
        try MediaWriter.writePNG(to: url, width: 64, height: 64) { ctx in
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    private func render(_ project: Project, _ bundle: ProjectBundle, at ticks: Int64) async throws -> RGBAImage {
        let r = OfflineRenderer(scene: SceneModel(project: project, resolve: bundle.resolve),
                                pool: MediaPool(diskCacheDirectory: nil))
        return RGBAImage(try await r.image(at: ticks, size: CGSize(width: 320, height: 180)))
    }

    /// Distinct colours on a coarse grid (a flat or black frame has 1).
    private func distinct(_ img: RGBAImage) -> Int {
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: img.height, by: 6) {
            for x in stride(from: 0, to: img.width, by: 6) {
                let p = img.pixel(x, y)
                let packed: UInt32 = UInt32(p.r) << 16 | UInt32(p.g) << 8 | UInt32(p.b)
                seen.insert(packed)
            }
        }
        return seen.count
    }

    /// Every clip in the project, nested ones included.
    private func allClips(_ p: Project) -> [Clip] {
        var out: [Clip] = []
        for track in p.tracks { for top in track.clips { top.walk { c, _ in out.append(c) } } }
        return out
    }

    /// Every item of the Backgrounds tab (`AssetCatalog.backgrounds`, the tab's list) placed at the
    /// playhead over existing media: one "Add Background" undo step each, its own bundle file,
    /// SH2 source/clip keys, never overlapping on a track, drawn and animated, lossless on save.
    @Test func everyBackgroundsTabItemPlacesRendersAndUndoes() async throws {
        let dir = try tempDir("bg-tab")
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("still.png")
        try writePNG(png)
        let doc = try EditorDocumentModel.untitled(width: 1280, height: 720, in: dir)
        _ = try await doc.importAndInsert(png, at: 0)
        let playhead: Int64 = 2 * Self.rate
        let backgrounds = AssetCatalog.backgrounds
        #expect(backgrounds.count >= 9)

        for bg in backgrounds {
            let before = doc.project.serialized()
            let sources = doc.project.sourceBin.count
            let clipID = try await doc.placeBackground(bg, at: playhead)
            #expect(doc.undo.undoName == "Add Background", "\(bg.id)")
            #expect(doc.project.sourceBin.count == sources + 1, "\(bg.id)")
            let after = doc.project.serialized()

            let clip = try #require(doc.project.tracks.flatMap(\.clips).first { $0.id == clipID })
            #expect(clip.start == playhead, "\(bg.id)")
            #expect(clip.duration == 60 * Self.rate, "\(bg.id)")
            let src = try #require(clip.sourceID.flatMap { doc.project.source(id: $0) })
            #expect(src.src.hasSuffix("/\(bg.fileName)"), "\(bg.id): \(src.src)")
            #expect(FileManager.default.fileExists(atPath: doc.bundle.resolve(src).path), "\(bg.id) file in bundle")
            let defCount: Int = src.object["effectDef"]?.array?.count ?? 0
            #expect(defCount == bg.parameters.count + 1, "\(bg.id) effectDef")
            let se = clip.object["sourceEffect"]?.object
            #expect(se?["effectName"]?.string == "SourceEffect", "\(bg.id)")
            #expect(se?["parameters"]?.object?["sourceFileType"]?.string == "tscshadervid", "\(bg.id)")

            // Drawn and animated on its own (only this clip at the top of the stack).
            let solo = try Project(data: after)
            let others: [Int64] = solo.tracks.flatMap(\.clips).map { $0.id }.filter { $0 != clipID }
            try DeleteClips(clipIDs: others).apply(to: solo)
            let f1 = try await render(solo, doc.bundle, at: playhead + Self.rate)
            // Half a second on: not a whole period of any built-in (Moving Stripes repeats every 2 s).
            let f2 = try await render(solo, doc.bundle, at: playhead + 3 * Self.rate / 2)
            let colours: Int = distinct(f1)
            print("background \(bg.id): distinct colours \(colours)")
            // Two-colour patterns (stripes) give a handful of anti-aliased shades; flat or black is 1.
            #expect(colours > 2, "\(bg.id) not drawn: \(colours)")
            #expect(f1 != f2, "\(bg.id) does not animate")

            // Byte-exact undo / redo of the single step.
            try doc.undoLast()
            #expect(doc.project.serialized() == before, "\(bg.id) undo")
            try doc.redoLast()
            #expect(doc.project.serialized() == after, "\(bg.id) redo")
        }

        // Each background is its own source; no two clips overlap on any track.
        let srcs: [String] = doc.project.sourceBin.map { $0.src }
        #expect(Set(srcs).count == srcs.count)
        for track in doc.project.tracks {
            let spans: [(Int64, Int64)] = track.clips.map { ($0.start, $0.start + $0.duration) }.sorted { $0.0 < $1.0 }
            for (a, b) in zip(spans, spans.dropFirst()) { #expect(a.1 <= b.0, "overlap on a track: \(a) \(b)") }
        }

        // Lossless save / reopen, TSCProjKit fixed point.
        let saved = doc.project.serialized()
        try doc.save()
        let reopened = try EditorDocumentModel(url: doc.bundle.directory)
        #expect(reopened.missing.isEmpty)
        #expect(reopened.project.serialized() == saved)
        #expect(try Project(data: saved).serialized() == saved)
    }

    /// A `.tscshadervid` dropped into an open group: source `effectDef` and inner clip
    /// `sourceEffect` in the same undo step, drawn through the group, lossless on save.
    @Test func shaderFileDroppedIntoAGroupGetsSH2Keys() async throws {
        let dir = try tempDir("bg-group")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bg = try #require(AssetCatalog.background(id: "wizrec-aurora") ?? AssetCatalog.backgrounds.first)
        let shader = dir.appendingPathComponent(bg.fileName)
        try bg.shaderVidData().write(to: shader)
        let png = dir.appendingPathComponent("still.png")
        try writePNG(png)

        let doc = try EditorDocumentModel.untitled(width: 1280, height: 720, in: dir)
        let a = try await doc.importAndInsert(png, at: 0)
        let group = GroupClips(clipIDs: [a])
        try doc.perform(group)
        let gid = try #require(group.groupID)
        try doc.perform(AddGroupTrack(group: gid, at: 1))
        let before = doc.project.serialized()

        let ids = try await doc.placeInGroup(.files([shader]), group: gid, track: 1, at: 0)
        let innerID = try #require(ids.first)
        #expect(doc.project.tracks.flatMap(\.clips).allSatisfy { $0.id != innerID })   // nested, not top level
        let inner = try #require(allClips(doc.project).first { $0.id == innerID })
        let src = try #require(inner.sourceID.flatMap { doc.project.source(id: $0) })
        #expect(src.object["effectDef"]?.array?.count == bg.parameters.count + 1)
        #expect(inner.object["sourceEffect"]?.object?["parameters"]?.object?["sourceFileType"]?.string == "tscshadervid")

        // The group clips its inner timeline to its own length (the 5 s still); draw inside it.
        let frame = try await render(doc.project, doc.bundle, at: Self.rate / 2)
        let colours: Int = distinct(frame)
        #expect(colours > 8, "background inside the group not drawn: \(colours)")

        let after = doc.project.serialized()
        try doc.undoLast()
        #expect(doc.project.serialized() == before)
        try doc.redoLast()
        #expect(doc.project.serialized() == after)
        try doc.save()
        let reopened = try EditorDocumentModel(url: doc.bundle.directory)
        #expect(reopened.project.serialized() == after)
    }

    /// A mixed multi-file drop (image, shader, audio): one undo step, and only the shader's
    /// source and clip carry `effectDef` / `sourceEffect`.
    @Test func mixedDropMarksOnlyTheShader() async throws {
        let dir = try tempDir("bg-mixed")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bg = try #require(AssetCatalog.backgrounds.last)
        let shader = dir.appendingPathComponent(bg.fileName)
        try bg.shaderVidData().write(to: shader)
        let png = dir.appendingPathComponent("still.png")
        try writePNG(png)
        let wav = dir.appendingPathComponent("voice.wav")
        try AudioSignals.writeWAV(AudioSignals.pinkNoise(seconds: 2, lufs: -23), to: wav)

        let doc = try EditorDocumentModel.untitled(in: dir)
        let before = doc.project.serialized()
        let clips = try await doc.importAndPlace([png, shader, wav], at: 0, name: "Add Media")
        #expect(clips.count == 3)
        #expect(doc.project.sourceBin.count == 3)
        for s in doc.project.sourceBin {
            let isShader: Bool = s.src.hasSuffix(".tscshadervid")
            #expect((s.object["effectDef"] != nil) == isShader, "\(s.src)")
        }
        for c in allClips(doc.project) {
            let isShader: Bool = c.sourceID.flatMap { doc.project.source(id: $0) }?.src.hasSuffix(".tscshadervid") ?? false
            #expect((c.object["sourceEffect"] != nil) == isShader, "clip \(c.id)")
        }
        try doc.undoLast()
        #expect(doc.project.serialized() == before)
    }
}
