import CoreGraphics
import Foundation
import MediaEngine
import TestGenKit
import Testing
import TimelineEngine
import TSCProjKit
import WizRecAssets
@testable import PlayerKit

@Suite @MainActor struct CalloutInsertionTests {
    @Test func defJSONIsThePresetDefinitionInOrder() throws {
        let blur = try #require(AssetCatalog.callout(id: "region-blur"))
        let def = try #require(try JSON.parse(CalloutInsertion.defJSON(blur)).object)
        #expect(def.keys == blur.definition.map(\.key))
        #expect(def["kind"]?.string == "TypeWinBlur")
        #expect(def["width"]?.double == blur.width)
    }

    @Test func displayWidthRules() throws {
        let blur = try #require(AssetCatalog.callout(id: "region-blur"))
        let arrow = try #require(AssetCatalog.callout(id: "arrow-basic"))
        let title = try #require(AssetCatalog.callout(id: "text-title"))
        #expect(CalloutInsertion.displayWidth(blur, canvasWidth: 1920) == 640)     // CO3
        #expect(CalloutInsertion.displayWidth(blur, canvasWidth: 1280) == 1280.0 / 3)
        #expect(CalloutInsertion.displayWidth(arrow, canvasWidth: 1920) == nil)    // no box
        #expect(CalloutInsertion.displayWidth(title, canvasWidth: 1920) == title.width)
        #expect(CalloutInsertion.displayWidth(title, canvasWidth: 960) == title.width / 2)
    }

    @Test func insertsAboveTheClipsAtThePlayheadForFiveSeconds() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-callout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("still.png")
        try MediaWriter.writePNG(to: png, width: 64, height: 64) { ctx in
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let doc = try EditorDocumentModel.untitled(in: dir)   // one empty track
        let tb = doc.project.timebase
        _ = try await doc.importAndInsert(png, at: 0, track: 0)   // 0–5 s on track 0
        try doc.perform(AddTrack(at: 1))
        let blur = try #require(AssetCatalog.callout(id: "region-blur"))

        // Over the image: track 1 (just above it), scaled to 640 px.
        let c = CalloutInsertion.command(blur, project: doc.project, playhead: tb.ticks(seconds: 1))
        #expect(c.track == 1)
        try doc.perform(c)
        let id = try #require(c.clipID)
        let clip = try #require(doc.project.tracks[1].clips.first { $0.id == id })
        #expect(clip.start == tb.ticks(seconds: 1))
        #expect(clip.duration == tb.ticks(seconds: 5))
        #expect(clip.kind == .callout)
        let scale = clip.object["parameters"]?.object?["scale0"]?.double ?? 0
        #expect(abs(scale - 640 / blur.width) < 1e-6)

        // Over the image and that callout: a new top track.
        let d = CalloutInsertion.command(blur, project: doc.project, playhead: tb.ticks(seconds: 2))
        #expect(d.track == nil)
        try doc.perform(d)
        #expect(doc.project.tracks.count == 3)
        // Where nothing plays: the bottom track.
        #expect(CalloutInsertion.track(in: doc.project, start: tb.ticks(seconds: 20), duration: tb.ticks(seconds: 5)) == 0)
        try doc.undoLast()
        try doc.undoLast()
        #expect(doc.project.tracks.count == 2)
    }
}
