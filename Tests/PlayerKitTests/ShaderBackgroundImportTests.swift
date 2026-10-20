import CoreGraphics
import ImageIO
import Foundation
import MediaEngine
import RenderEngine
import Testing
import TimelineEngine
import TSCProjKit
import WizRecAssets
@testable import PlayerKit

/// Shader backgrounds placed from the library or imported as `.tscshadervid` files get the
/// source `effectDef` and clip `sourceEffect` of `docs/specs/shader-backgrounds.md` §6 (SH2).
@MainActor @Suite struct ShaderBackgroundImportTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("wizrec-shader-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func centre(_ img: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(img, in: CGRect(x: -img.width / 2, y: -img.height / 2, width: img.width, height: img.height))
        return px
    }

    private var background: BackgroundAsset {
        get throws { try #require(AssetCatalog.background(id: "wizrec-gradient-drift") as BackgroundAsset?) }
    }

    /// Checks the source and clip against the background's own `ShaderSourceLayout`.
    private func expectLayout(_ doc: EditorDocumentModel, clip clipID: Int64, _ bg: BackgroundAsset) throws {
        let entries = try bg.sourceBinEntries()
        let source = try #require(doc.project.sourceBin.first)
        #expect(source.src.hasSuffix("/\(bg.fileName)"))
        let def = (source.object["effectDef"]?.array?.items ?? []).compactMap { $0.object }
        #expect(def.map { $0["name"]?.string ?? "" } == entries.map(\.name))
        #expect(def.last?["defaultValue"]?.string == "tscshadervid")
        let color = try #require(def.first)
        #expect(color.keys == ["name", "type", "defaultValue", "scalingType", "unitType", "userInterfaceType"])
        #expect(color["scalingType"]?.int == 3 && color["userInterfaceType"]?.int == 6)
        #expect(source.object.keys.firstIndex(of: "effectDef") == source.object.keys.firstIndex(of: "sourceTracks").map { $0 + 1 })

        let clip = try #require(doc.project.tracks.flatMap(\.clips).first { $0.id == clipID })
        #expect(clip.object["_type"]?.string == "VMFile")
        let se = try #require(clip.object["sourceEffect"]?.object)
        #expect(se["effectName"]?.string == "SourceEffect" && se["bypassed"]?.bool == false)
        let params = try #require(se["parameters"]?.object)
        #expect(params.keys == entries.flatMap { $0.clipParameters.map(\.key) })   // file order, ends with sourceFileType
        #expect(params["sourceFileType"]?.string == "tscshadervid")
        #expect(params["Speed"]?.object?["interp"]?.string == "linr")
        #expect(params["Color0-alpha"]?.object?["defaultValue"]?.double == 1)
        #expect(clip.metadata?["lockAspectRatio"] == (try JSON.parse(#"{"type" : "bool", "value" : true}"#)))
        #expect(clip.metadata?["default-scale"]?.string == "1")
        #expect(clip.duration == 60 * doc.project.timebase.editRate)
    }

    @Test func libraryBackgroundWritesSH2LayoutAndRenders() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try EditorDocumentModel.untitled(in: dir)
        let before = doc.project.serialized()
        let bg = try background
        let clipID = try await doc.placeBackground(bg, at: 0)
        #expect(doc.undo.undoName == "Add Background")
        try expectLayout(doc, clip: clipID, bg)
        let after = doc.project.serialized()

        // Byte-exact undo / redo.
        try doc.undoLast()
        #expect(doc.project.serialized() == before)
        try doc.redoLast()
        #expect(doc.project.serialized() == after)

        // Lossless save and reopen.
        let target = dir.appendingPathComponent("BG.cmproj")
        _ = try doc.saveAs(to: target)
        let reopened = try EditorDocumentModel(url: target)
        #expect(reopened.missing.isEmpty)
        #expect(reopened.project.serialized() == after)
        #expect(try Project(data: reopened.project.serialized()).serialized() == after)

        // The renderer draws it from the clip's sourceEffect.
        let pool = MediaPool(diskCacheDirectory: nil)
        let px = centre(try await OfflineRenderer(scene: reopened.scene, pool: pool).image(at: 0))
        #expect(px[3] == 255 && Int(px[0]) + Int(px[1]) + Int(px[2]) > 60, "\(px)")

        // All four colours pure red in sourceEffect → a red frame (proves the clip values are used).
        let red = try Project(data: reopened.project.serialized())
        let params = try #require(red.tracks.flatMap(\.clips).first?.object["sourceEffect"]?.object?["parameters"]?.object)
        for n in 0..<4 {
            for (ch, v) in [("red", 1.0), ("green", 0.0), ("blue", 0.0)] {
                params["Color\(n)-\(ch)"]?.object?["defaultValue"] = .number(JSONNumber(v))
            }
        }
        let redPx = centre(try await OfflineRenderer(scene: SceneModel(project: red, resolve: reopened.bundle.resolve),
                                                     pool: pool).image(at: 0))
        #expect(redPx[0] >= 250 && redPx[1] <= 5 && redPx[2] <= 5, "\(redPx)")
    }

    @Test func importedShaderFileGetsEffectDefInTheSameUndoStep() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bg = try background
        let file = dir.appendingPathComponent(bg.fileName)
        try bg.shaderVidData().write(to: file)
        let doc = try EditorDocumentModel.untitled(in: dir)
        let before = doc.project.serialized()

        let id = try await doc.importMedia(file)
        #expect(doc.undo.undoName == "Import Media")
        #expect(doc.project.source(id: id)?.object["effectDef"]?.array?.count == bg.parameters.count + 1)
        try doc.undoLast()
        #expect(doc.project.serialized() == before)
        try doc.redoLast()

        // Placing it from the bin gives the clip its sourceEffect.
        let clip = try doc.insertSource(id, at: 0)
        try expectLayout(doc, clip: clip, bg)

        // Dropping the file straight onto the timeline does the same in one step.
        let doc2 = try EditorDocumentModel.untitled(in: dir)
        let c2 = try await doc2.importAndInsert(file, at: 0)
        try expectLayout(doc2, clip: c2, bg)
        try doc2.undoLast()
        #expect(doc2.project.sourceBin.isEmpty)
    }

    @Test func ordinaryImportsGetNoEffectDef() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("still.png")
        let ctx = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let img = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        #expect(CGImageDestinationFinalize(dest))
        let doc = try EditorDocumentModel.untitled(in: dir)
        let clip = try await doc.importAndInsert(png, at: 0)
        #expect(doc.project.sourceBin.first?.object["effectDef"] == nil)
        #expect(doc.project.tracks.flatMap(\.clips).first { $0.id == clip }?.object["sourceEffect"] == nil)
    }
}
