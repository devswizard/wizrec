import CoreGraphics
import Foundation
import MediaEngine
import Metal
import RenderEngine
import Testing
import TestGenKit
import TimelineEngine
import TSCProjKit
import WizRecAssets
@testable import PlayerKit

// QA9-2 / app9: shader backgrounds after placement. A library background placed into a Rev
// group (ShaderVidSource / RevBackground, `shader-backgrounds.md` §11) through save/reopen,
// ungroup, split and copy/paste; inspector edits (`ShaderInspection` → `SetSourceEffectParameters`)
// constant and keyframed, checked on rendered pixels, and pixel-stable across split and save.

@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
@MainActor struct ShaderBackgroundEditIntegrationTests {
    private static let rate: Int64 = 705_600_000

    private func tempDir(_ tag: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("qa9-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func asset(_ id: String) throws -> BackgroundAsset {
        try #require(AssetCatalog.background(id: id) as BackgroundAsset?)
    }

    private func render(_ doc: EditorDocumentModel, at ticks: Int64) async throws -> RGBAImage {
        let r = OfflineRenderer(scene: SceneModel(project: doc.project, resolve: doc.bundle.resolve),
                                pool: MediaPool(diskCacheDirectory: nil))
        return RGBAImage(try await r.image(at: ticks, size: CGSize(width: 320, height: 180)))
    }

    /// Clip `id` anywhere in the project (nested included).
    private func clip(_ id: Int64, in p: Project) -> Clip? {
        var found: Clip?
        for t in p.tracks { for c in t.clips { c.walk { inner, _ in if inner.id == id { found = inner } } } }
        return found
    }

    private func text(_ p: Project) -> String { String(decoding: p.serialized(), as: UTF8.self) }

    private func shader(_ doc: EditorDocumentModel, _ clipID: Int64, playhead: Int64) throws -> ShaderInspection {
        let i = try #require(ClipInspection.make(project: doc.project, clipID: clipID, playhead: playhead))
        return try #require(i.shader)
    }

    /// Aurora at 0 grouped into a Rev group, then Moving Stripes placed on its inner track 0
    /// after it (the library double-click into an open Rev group). Returns the doc, group, clip.
    private func revFixture(in dir: URL) async throws -> (EditorDocumentModel, group: Int64, clip: Int64, before: Data) {
        let doc = try EditorDocumentModel.untitled(width: 1280, height: 720, in: dir)
        doc.backgroundLibraryRoot = dir.appendingPathComponent("Library", isDirectory: true)
        let first = try await doc.placeBackground(try asset("wizrec-aurora"), at: 0)
        let group = GroupClips(clipIDs: [first])
        try doc.perform(group)
        let gid = try #require(group.groupID)
        // A Rev group as Camtasia saves one (`groupType` "revMedia", §11); WizRec has no Rev UI yet.
        clip(gid, in: doc.project)?.metadata?["groupType"] = .string("revMedia")
        let before = doc.project.serialized()
        let id = try await doc.placeBackground(try asset("wizrec-stripes"), inGroup: gid, track: 0, at: 60 * Self.rate)
        return (doc, gid, id, before)
    }

    /// Rev placement → save/reopen lossless with both keys; ungroup keeps `ShaderVidSource` on the
    /// clip and drops `RevBackground` with the group; undo of each step is byte-exact.
    @Test func revGroupBackgroundSurvivesSaveReopenAndUngroup() async throws {
        let dir = try tempDir("rev")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (doc, gid, id, before) = try await revFixture(in: dir)
        #expect(doc.undo.undoName == "Add Background")
        let after = doc.project.serialized()
        let libraryFile = doc.backgroundLibraryRoot.appendingPathComponent("backgrounds/wizrec-stripes.tscshadervid")
        #expect(clip(id, in: doc.project)?.metadata?["ShaderVidSource"]?.string == libraryFile.path)
        #expect(clip(gid, in: doc.project)?.metadata?["RevBackground"]?.string == "backgrounds/wizrec-stripes.tscshadervid")

        try doc.undoLast()
        #expect(doc.project.serialized() == before)
        try doc.redoLast()
        #expect(doc.project.serialized() == after)

        // Lossless save / reopen; the bundle plays its own copy, so nothing is missing even
        // with the library file gone.
        try doc.save()
        try FileManager.default.removeItem(at: libraryFile)
        let reopened = try EditorDocumentModel(url: doc.bundle.directory)
        #expect(reopened.missing.isEmpty)
        #expect(reopened.project.serialized() == after)
        #expect(try Project(data: after).serialized() == after)
        #expect(clip(id, in: reopened.project)?.metadata?["ShaderVidSource"]?.string == libraryFile.path)

        // The background is drawn from the reopened project (inside the group at its inner time).
        let groupClip = try #require(clip(gid, in: reopened.project))
        let inner = try #require(clip(id, in: reopened.project))
        #expect(groupClip.start + groupClip.duration >= inner.start + inner.duration, "group does not cover the new background")
        let a = try await render(reopened, at: 100 * Self.rate)
        let b = try await render(reopened, at: 100 * Self.rate + Self.rate / 2)
        #expect(a != b, "nested Rev background not drawn or not animated")

        // Ungroup: the clip keeps ShaderVidSource; RevBackground goes with the group.
        let reopenedBytes = reopened.project.serialized()
        let ungroup = UngroupClip(clipID: gid)
        try reopened.perform(ungroup)
        let released = try #require(clip(id, in: reopened.project))
        #expect(reopened.project.tracks.flatMap(\.clips).contains { $0.id == id })
        #expect(released.metadata?["ShaderVidSource"]?.string == libraryFile.path)
        #expect(released.object["sourceEffect"] != nil)
        #expect(!text(reopened.project).contains("RevBackground"))
        try reopened.undoLast()
        #expect(reopened.project.serialized() == reopenedBytes)
    }

    /// Splitting the nested Rev background keeps ShaderVidSource and sourceEffect on both
    /// halves; copying a half to the top level keeps them too (plain metadata travels).
    @Test func splitAndCopyKeepShaderVidSource() async throws {
        let dir = try tempDir("rev-split")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (doc, gid, id, _) = try await revFixture(in: dir)
        let path = try #require(clip(id, in: doc.project)?.metadata?["ShaderVidSource"]?.string)
        let beforeSplit = doc.project.serialized()

        let split = SplitClip(clipID: id, at: 90 * Self.rate)   // inner timeline ticks
        try doc.perform(split)
        let right = try #require(split.rightID)
        for half in [id, right] {
            let c = try #require(clip(half, in: doc.project))
            #expect(c.metadata?["ShaderVidSource"]?.string == path, "half \(half)")
            #expect(c.object["sourceEffect"]?.object?["parameters"]?.object?["sourceFileType"]?.string == "tscshadervid")
        }
        // The group's RevBackground is untouched by the split.
        #expect(clip(gid, in: doc.project)?.metadata?["RevBackground"]?.string == "backgrounds/wizrec-stripes.tscshadervid")

        // Copy the whole Rev group, which carries RevBackground and both ShaderVidSource halves
        // into the pasted copy (a nested clip copied alone carries only its ShaderVidSource).
        let payload = try ClipboardPayload.copy(clipIDs: [gid], from: doc.project)
        let topTrack: Int = doc.project.tracks.count
        try doc.perform(AddTrack(at: topTrack))
        let paste = PasteClips(payload, track: topTrack, at: 200 * Self.rate)
        try doc.perform(paste)
        let pastedID = try #require(paste.pastedIDs.first)
        let pasted = try #require(doc.project.tracks[topTrack].clips.first { $0.id == pastedID })
        #expect(pasted.metadata?["RevBackground"]?.string == "backgrounds/wizrec-stripes.tscshadervid")
        var copiedOrigins: [String] = []
        pasted.walk { c, _ in
            if c.id != pastedID, let s = c.metadata?["ShaderVidSource"]?.string { copiedOrigins.append(s) }
        }
        #expect(copiedOrigins == [path, path], "pasted group's stripes halves: \(copiedOrigins)")
        // The pasted copy draws: at 200 s + 100 s inner, its stripes are the top layer.
        let frame = try await render(doc, at: 300 * Self.rate)
        let px = frame.pixel(160, 90)
        #expect(px.a == 255 && Int(px.r) + Int(px.g) + Int(px.b) > 60, "pasted background not drawn: \(px)")

        try doc.undoLast(); try doc.undoLast(); try doc.undoLast()
        #expect(doc.project.serialized() == beforeSplit)
    }

    /// Inspector edits (`ShaderInspection.parameterChanges` → `doc.set`): a constant colour
    /// changes the frame and undoes to the same pixels; a keyframed value from the playhead
    /// changes only frames after the first keyframe; split and save/reopen keep every pixel.
    @Test func inspectorEditsChangeRenderedFramesAndSurviveSplitAndSave() async throws {
        let dir = try tempDir("inspect")
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try EditorDocumentModel.untitled(width: 1280, height: 720, in: dir)
        let id = try await doc.placeBackground(try asset("wizrec-aurora"), at: 0)
        let t1: Int64 = Self.rate, t4: Int64 = 4 * Self.rate
        let base0 = try await render(doc, at: 0)
        let base1 = try await render(doc, at: t1)
        let base4 = try await render(doc, at: t4)
        let placed = doc.project.serialized()

        // Constant: sky colour to pure red.
        try doc.set(try shader(doc, id, playhead: t1).parameterChanges("Color0", [1, 0, 0, 1]))
        #expect(doc.undo.undoName == "Change Background")
        let red1 = try await render(doc, at: t1)
        #expect(red1 != base1, "constant colour edit did not change the frame")
        try doc.undoLast()
        #expect(doc.project.serialized() == placed)
        #expect(try await render(doc, at: t1) == base1, "undo did not restore the pixels")

        // Keyframed: Intensity held at its default at 0, then 0 at the 4 s playhead (inspector path).
        let intensity = try #require(try shader(doc, id, playhead: 0).items.first { $0.name == "Intensity" })
        let start = try #require(intensity.values.first)
        try doc.perform(SetSourceEffectParameters(clipID: id, changes: [.init("Intensity", start, keyframeAt: 0)]))
        let s4 = try shader(doc, id, playhead: t4)
        #expect(s4.keyframeTime == t4)
        let kfChanges = s4.parameterChanges("Intensity", [0])
        #expect(kfChanges.allSatisfy { $0.isSourceEffect && $0.keyframeAt == t4 })
        try doc.set(kfChanges)
        #expect(try await render(doc, at: 0) == base0, "frame at the first keyframe changed")
        let kf4 = try await render(doc, at: t4)
        #expect(kf4 != base4, "keyframed Intensity 0 did not change the frame at 4 s")
        let mid = try await render(doc, at: 2 * Self.rate)

        // Split between the keyframes: every frame on both sides is unchanged.
        let keyed = doc.project.serialized()
        let split = SplitClip(clipID: id, at: 3 * Self.rate)
        try doc.perform(split)
        #expect(split.rightID != nil)
        #expect(try await render(doc, at: 2 * Self.rate) == mid, "split changed the left half")
        #expect(try await render(doc, at: t4) == kf4, "split changed the right half")
        try doc.undoLast()
        #expect(doc.project.serialized() == keyed)

        // Save / reopen: same bytes, same pixels.
        try doc.save()
        let reopened = try EditorDocumentModel(url: doc.bundle.directory)
        #expect(reopened.project.serialized() == keyed)
        #expect(try await render(reopened, at: t4) == kf4)
    }
}
