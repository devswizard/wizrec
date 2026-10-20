import CoreGraphics
import Foundation
import MediaEngine
import Metal
import PlayerKit
import RenderEngine
import Testing
import TestGenKit
import TSCProjKit
import WizRecAssets

// S5-QA-1 / render6 SH2: a shader background (WizRec's own, from AssetCatalog) imported and
// placed on the timeline the way the editor does becomes a 60 s clip, renders animated content
// over its whole length through OfflineRenderer, and survives save/reopen with identical pixels.

@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
@MainActor struct ShaderBackgroundIntegrationTests {
    private func render(_ bundle: ProjectBundle, _ project: Project, at seconds: Double) async throws -> RGBAImage {
        let r = OfflineRenderer(scene: SceneModel(project: project, resolve: bundle.resolve), pool: MediaPool(diskCacheDirectory: nil))
        return RGBAImage(try await r.image(at: Int64(seconds * 705_600_000), size: CGSize(width: 320, height: 180)))
    }

    /// Distinct colours on a coarse grid (a flat or black frame has 1).
    private func distinct(_ img: RGBAImage) -> Int {
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: img.height, by: 6) {
            for x in stride(from: 0, to: img.width, by: 6) {
                let p = img.pixel(x, y)
                seen.insert(UInt32(p.r) << 16 | UInt32(p.g) << 8 | UInt32(p.b))
            }
        }
        return seen.count
    }

    @Test func importedBackgroundIsSixtySecondsAndRenders() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s5-shader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let asset = try #require(AssetCatalog.backgrounds.first)
        let file = dir.appendingPathComponent(asset.fileName)
        try asset.shaderVidData().write(to: file)

        let doc = try EditorDocumentModel.untitled(width: 1280, height: 720, in: dir)
        let clipID = try await doc.importAndInsert(file, at: 0)
        let clip = try #require(doc.project.tracks.flatMap(\.clips).first { $0.id == clipID })
        #expect(clip.start == 0)

        var frames: [RGBAImage] = []
        for s in [0.0, 1.0, 30.0, 59.9] { frames.append(try await render(doc.bundle, doc.project, at: s)) }
        let counts = frames.map(distinct)
        print("shader background \(asset.id): clip \(Double(clip.duration) / 705_600_000) s; distinct colours at 0/1/30/59.9 s = \(counts)")
        #expect(clip.duration == 60 * 705_600_000, "shader clip is \(Double(clip.duration) / 705_600_000) s")
        #expect(counts.allSatisfy { $0 > 20 }, "background not drawn: \(counts)")
        #expect(frames[0] != frames[1] && frames[1] != frames[2], "background does not animate")
        let after = try await render(doc.bundle, doc.project, at: 60.5)
        #expect(distinct(after) <= 2, "background drawn past its 60 s clip")

        try doc.save()
        let reopened = try ProjectBundle(url: doc.bundle.directory)
        #expect(reopened.project.serialized() == doc.project.serialized())
        #expect(try await render(reopened, reopened.project, at: 30) == frames[2], "render changed across save/reopen")
    }
}
