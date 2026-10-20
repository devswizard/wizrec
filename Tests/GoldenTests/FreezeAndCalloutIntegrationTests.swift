import AudioEngine
import CoreGraphics
import Exporter
import Foundation
import MediaEngine
import Metal
import RenderEngine
import Testing
import TestGenKit
import TimelineEngine
import TSCProjKit

// S5-QA-1, last slice:
// - timeline Extend Frame (ED1: StitchedMedia + held IMFile frame) end to end: the held frame
//   renders the clip's last frame (decoded from the test card's barcode) in preview and in a
//   ProRes export, save/reopen keeps it, undo restores the bytes;
// - InsertCallout with CO3 Keystroke and Sketch Motion definitions (our own SVG, never
//   TechSmith's `xmlContent`) through OfflineRenderer, including the `DrawTime` draw-on ramp.

private let W = 320, H = 180

@MainActor
private func render(_ bundle: ProjectBundle, _ project: Project, at ticks: Int64) async throws -> RGBAImage {
    let r = OfflineRenderer(scene: SceneModel(project: project, resolve: bundle.resolve), pool: MediaPool(diskCacheDirectory: nil))
    return RGBAImage(try await r.image(at: ticks, size: CGSize(width: W, height: H)))
}

/// Pixels that differ from `b` by more than 24 in any channel.
private func changed(_ a: RGBAImage, _ b: RGBAImage) -> Int {
    var n = 0
    for i in stride(from: 0, to: min(a.pixels.count, b.pixels.count), by: 4) {
        if (0..<3).contains(where: { abs(Int(a.pixels[i + $0]) - Int(b.pixels[i + $0])) > 24 }) { n += 1 }
    }
    return n
}

@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
@MainActor struct FreezeAndCalloutIntegrationTests {
    @Test func extendFrameHoldsTheLastFrameInPreviewAndExport() async throws {
        let dir = try scratchDir("s5-freeze")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("fz.cmproj"), width: W, height: H)
        let card = TestCard(width: W, height: H, label: "F")
        let movie = dir.appendingPathComponent("card.mp4")
        _ = try MediaWriter.writeH264(to: movie, width: W, height: H, fps: 30, frameCount: 30, bitsPerSecond: 8_000_000) { n, ctx in
            card.draw(frame: n, fps: 30, in: ctx)
        }
        let setup = EditChain(bundle.project)
        let add = AddSource(movieDescriptor(src: try bundle.importFile(movie), frames: 30, audio: false))
        add.addedAt = Date(timeIntervalSince1970: 1_792_376_869)
        try setup.run(add)
        let sourceID = try #require(add.sourceID)
        let clip = try #require(try setup.run(InsertClip(sourceID: sourceID, track: 0, start: 0)).clipID)
        let chain = EditChain(bundle.project)
        let original = chain.project.serialized()

        let freeze = try chain.run(ExtendFrame(clipID: clip, duration: frames(15)))
        let stitched = try #require(freeze.stitchedID)
        #expect(freeze.freezeID != nil)
        #expect(chain.project.tracks[0].clips.map(\.id) == [stitched])
        #expect(chain.project.duration == frames(45))

        // Preview: the clip plays, then its last frame (29) holds for 15 frames.
        let expected: [(Int64, Int)] = [(5, 5), (29, 29), (30, 29), (37, 29), (44, 29)]
        for (t, source) in expected {
            let shown = card.decodeFrameNumber(try await render(bundle, chain.project, at: frames(t)))
            #expect(shown == source, "preview frame \(t): barcode \(shown.map(String.init) ?? "–"), expected \(source)")
        }

        // Export (ProRes 4444): 45 frames, the same held frame.
        let out = dir.appendingPathComponent("out.mov")
        var settings = ExportSettings(format: .mov(profile: "4444"))
        settings.includeAudio = false
        try await ExportSession(scene: SceneModel(project: chain.project, resolve: bundle.resolve),
                                audio: AudioScene(project: chain.project, resolve: bundle.resolve),
                                pool: MediaPool(diskCacheDirectory: nil), settings: settings, output: out).run()
        let info = try await MovieFrameReader.info(out)
        #expect(abs(info.duration - 1.5) < 0.02, "export lasts \(info.duration) s")
        let exported = try await MovieFrameReader.frames(out, indices: expected.map { Int($0.0) })
        for (t, source) in expected {
            let img = try #require(exported[Int(t)])
            #expect(card.decodeFrameNumber(img) == source, "export frame \(t): expected source frame \(source)")
        }

        try bundle.saveWithBackup()
        let reopened = try ProjectBundle(url: bundle.directory)
        #expect(reopened.project.serialized() == chain.project.serialized())
        #expect(ProjectInvariants.check(reopened.project).isEmpty)
        #expect(card.decodeFrameNumber(try await render(reopened, reopened.project, at: frames(40))) == 29)

        try chain.expectUndoRedoWalk()
        try chain.undoAll()
        #expect(chain.project.serialized() == original)
        #expect(chain.project.duration == frames(30))
    }

    /// Keystroke (MacKey) and Sketch Motion (TypeWinSVG, our own two-stroke SVG) callouts placed
    /// with InsertCallout at the playhead (5 s, new tracks) render through OfflineRenderer; the
    /// sketch's `leftEdgeMods` DrawTime ramp draws fewer stroke pixels early than once complete;
    /// save/reopen keeps the bytes and the picture; undo restores the original.
    @Test func keystrokeAndSketchCalloutsRender() async throws {
        let dir = try scratchDir("s5-callouts")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("co.cmproj"), width: 640, height: 360)
        let chain = EditChain(bundle.project)
        let original = chain.project.serialized()
        func render640(_ p: Project, _ t: Int64) async throws -> RGBAImage {
            let r = OfflineRenderer(scene: SceneModel(project: p, resolve: bundle.resolve), pool: MediaPool(diskCacheDirectory: nil))
            return RGBAImage(try await r.image(at: t, size: CGSize(width: 640, height: 360)))
        }
        let empty = try await render640(chain.project, frames(45))

        let key = #"{"kind":"MacKey","shape":"","style":"","keys":"⌘ A","name":"⌘ A","keyStyle":2,"showKeyBackg":1,"showKeyHint":0,"corner-radius":6.0,"width":128.0,"height":64.0}"#
        let k = try chain.run(InsertCallout(def: key, start: frames(30)))
        let keyID = try #require(k.clipID)
        let placed = try #require(chain.project.tracks.flatMap(\.clips).first { $0.id == keyID })
        #expect(placed.start == frames(30) && placed.duration == 5 * 705_600_000)
        let withKey = try await render640(chain.project, frames(45))
        #expect(changed(withKey, empty) > 1500, "keystroke callout not drawn (\(changed(withKey, empty)) px)")
        #expect(changed(try await render640(chain.project, frames(10)), empty) == 0, "keystroke drawn before its start")

        // Our own drawing: a zig-zag and a circle in a 200×100 viewBox.
        let svg = #"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 200 100\"><path d=\"M10 90 L60 10 L110 90 L160 10\"/><path d=\"M170 50 a20 20 0 1 0 0.1 0\"/></svg>"#
        let sketch = #"{"kind":"TypeWinSVG","shape":"","style":"","DrawTime":1.0,"borderColorRed":1.0,"borderColorGreen":1.0,"borderColorBlue":0.0,"borderWidth":3.0,"corner-radius":6.0,"width":400.0,"height":200.0,"xmlContent":"\#(svg)"}"#
        let s = try chain.run(InsertCallout(def: sketch, start: frames(200), track: nil, duration: frames(90)))
        let sketchID = try #require(s.clipID)
        let sketchClip = try #require(chain.project.tracks.flatMap(\.clips).first { $0.id == sketchID })
        // Draw-on over the first second, as Camtasia writes it for Sketch Motion [CO3]. A TSCProjKit
        // tree edit (no TimelineEngine command writes edge mods yet).
        sketchClip.object["leftEdgeMods"] = .array(JSONArray([.object(JSONObject([
            ("group", .string("DrawPercentageFade")), ("duration", .number(JSONNumber(705_600_000))),
            ("parameters", .array(JSONArray([.object(JSONObject([("name", .string("DrawTime")), ("func", .string("FadeInFunc"))]))]))),
        ]))]))
        let base = try await render640(chain.project, frames(190))
        let early = changed(try await render640(chain.project, frames(200 + 6)), base)
        let done = changed(try await render640(chain.project, frames(200 + 60)), base)
        print("callouts: keystroke \(changed(withKey, empty)) px; sketch \(early) px at 0.2 s, \(done) px at 2 s")
        #expect(done > 400, "sketch not drawn")
        #expect(early > 0 && early < done * 2 / 3, "draw-on ramp: \(early) px early vs \(done) complete")

        try bundle.saveWithBackup()
        let reopened = try ProjectBundle(url: bundle.directory)
        #expect(reopened.project.serialized() == chain.project.serialized())
        #expect(try await render640(reopened.project, frames(260)) == (try await render640(chain.project, frames(260))))
        #expect(try await render640(reopened.project, frames(45)) == withKey)

        try chain.undoAll()
        #expect(chain.project.serialized() == original)
    }
}
