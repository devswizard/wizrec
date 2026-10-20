import CoreGraphics
import Foundation
import MediaEngine
import Metal
import RenderEngine
import TestGenKit
import Testing
import TSCProjKit

/// Reference-file selection (ProRes `.mov` over H.264 `.mp4`), PSNR floors tied to the file
/// they were calibrated on, per-sheet thresholds and calibration output. No references needed.
@Suite struct ReferenceFileTests {
    @Test func movIsPreferredOverMP4() throws {
        let dir = try scratchDir("ref-pick")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ReferenceFile.resolve(in: dir, declared: "reference.mp4", prefer: nil) == nil)

        try Data().write(to: dir.appendingPathComponent("reference.mp4"))
        #expect(ReferenceFile.resolve(in: dir, declared: "reference.mp4", prefer: nil)?.lastPathComponent == "reference.mp4")

        try Data().write(to: dir.appendingPathComponent("reference.mov"))
        #expect(ReferenceFile.resolve(in: dir, declared: "reference.mp4", prefer: nil)?.lastPathComponent == "reference.mov")
        #expect(ReferenceFile.resolve(in: dir, declared: "reference.mp4", prefer: "mp4")?.lastPathComponent == "reference.mp4")

        // Only a .mov: used even with GOLDEN_PREFER=mp4.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("reference.mp4"))
        #expect(ReferenceFile.resolve(in: dir, declared: "reference.mp4", prefer: "mp4")?.lastPathComponent == "reference.mov")

        // Non-movie declarations are taken literally.
        #expect(ReferenceFile.resolve(in: dir, declared: "reference.png", prefer: nil) == nil)
    }

    @Test func psnrFloorAppliesOnlyToItsFile() {
        let mov = URL(fileURLWithPath: "/x/reference.mov"), mp4 = URL(fileURLWithPath: "/x/reference.mp4")
        #expect(ReferenceFile.floorApplies(calibratedOn: nil, used: mp4))
        #expect(ReferenceFile.floorApplies(calibratedOn: "reference.mov", used: mov))
        #expect(!ReferenceFile.floorApplies(calibratedOn: "reference.mov", used: mp4))
    }

    /// Old manifests (no `psnrReference`, sheets without `psnrMin`) still decode.
    @Test func manifestsWithoutNewKeysDecode() throws {
        let golden = #"{"case":"c","summary":"","project":"c.cmproj","reference":"reference.mp4","fps":30,"width":1920,"height":1080,"durationFrames":1,"frames":[0],"ssimMin":0.97,"expectations":{},"generator":"0.1.0"}"#
        let g = try JSONDecoder().decode(GoldenManifest.self, from: Data(golden.utf8))
        #expect(g.psnrMin == nil && g.psnrReference == nil)
        let sheet = #"{"case":"s","group":"effects","summary":"","status":"ready","requires":[],"referenceImage":"reference.png","playheadFrame":0,"fps":30,"width":1920,"height":1080,"ssimMin":0.95,"cells":[],"checklist":"","generator":"0.1.0"}"#
        let s = try JSONDecoder().decode(SheetManifest.self, from: Data(sheet.utf8))
        #expect(s.psnrMin == nil && s.psnrReference == nil && s.ssimMin == 0.95)
    }

    /// No sheet threshold is set until real references calibrate it; defaults are M4's 0.95.
    @Test func sheetThresholdsStayDefaultWithoutReferences() {
        #expect(TestGen.sheetThresholds.isEmpty, "set sheet thresholds only from real reference data")
        #expect(TestGen.sheetThreshold(for: "effects/ef2-roundcorners") == SheetThreshold(ssimMin: 0.95, psnr: nil))
    }

    @Test func calibrationPrintsPasteReadySwift() {
        let scores = [FrameScore(frame: 0, ssim: 0.99, psnr: 44.2, passed: true),
                      FrameScore(frame: 3, ssim: 0.985, psnr: 42.74, passed: true)]
        let cal = Golden.calibration(case: "translate", scores: scores, reference: "reference.mov")
        #expect(cal?.suggestedPsnrMin == 41.5)
        #expect(cal?.swift == #""translate": PSNRFloor(dB: 41.5, reference: "reference.mov"),"#)
        #expect(Golden.calibration(case: "translate", scores: scores)?.swift == nil)

        let sheet = [SheetScore(label: "a", whole: 0.97, cells: [(1, 0.96), (2, 0.99)], threshold: 0.95, psnr: 33.2),
                     SheetScore(label: "b", whole: 0.98, cells: [(1, 0.955)], threshold: 0.95, psnr: 31.9)]
        let sc = Golden.sheetCalibration(sheet: "effects/ef6-motionblur", scores: sheet, reference: "reference.mov")
        #expect(sc?.caseName == "effects-ef6-motionblur" && sc?.minSSIM == 0.97 && sc?.minCellSSIM == 0.955)
        #expect(sc?.minPSNR == 31.9 && sc?.suggestedPsnrMin == 30.5)
        #expect(sc?.swift == #""effects/ef6-motionblur": SheetThreshold(psnr: PSNRFloor(dB: 30.5, reference: "reference.mov")),"#)
        #expect(Golden.sheetCalibration(sheet: "x/y", scores: [], reference: nil) == nil)
    }

    @Test func sheetPSNRFloorGates() {
        let ok = SheetScore(label: "", whole: 0.99, cells: [], threshold: 0.95, psnr: 40, psnrFloor: 38)
        let low = SheetScore(label: "", whole: 0.99, cells: [], threshold: 0.95, psnr: 37, psnrFloor: 38)
        let none = SheetScore(label: "", whole: 0.99, cells: [], threshold: 0.95, psnr: 10)
        #expect(ok.passed && !low.passed && none.passed)
    }

    /// The ProRes stand-in writer produces a `.mov` the frame reader decodes at full fidelity.
    @Test func proResWriterRoundTrips() async throws {
        let dir = try scratchDir("prores")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("reference.mov")
        let card = TestCard(width: 320, height: 180, label: "A")
        try await MediaWriter.writeProRes(to: url, width: 320, height: 180, fps: 30, frameCount: 6) { n, ctx in
            card.draw(frame: n, fps: 30, in: ctx)
        }
        let info = try await MovieFrameReader.info(url)
        #expect(info.width == 320 && info.height == 180 && abs(info.fps - 30) < 0.01)
        let frames = try await MovieFrameReader.frames(url, indices: [0, 5])
        let five = try #require(frames[5])
        #expect(card.decodeFrameNumber(five) == 5)
    }
}

/// `runGoldenCase` / `runSheet` against ProRes references: WizRec's own render as
/// `reference.mov` passes, and wins over a deliberately wrong `reference.mp4` beside it.
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct ProResReferenceSelfTests {
    @Test @MainActor func goldenCasePrefersMovAndIgnoresForeignFloor() async throws {
        let dir = try scratchDir("golden-mov")
        defer { try? FileManager.default.removeItem(at: dir) }
        let media = try await TestGen.makeMedia(in: dir.appendingPathComponent("_media"), scale: 0.25)
        let testCase = try #require(TestGen.cases.first { $0.name == "keyframes-linear" })
        let caseDir = try TestGen.write(testCase, media: media, to: dir)
        let golden = GoldenCase(name: testCase.name, directory: caseDir)
        // Half size keeps the encodes quick; the harness renders at the reference's size.
        var m = try golden.manifest()
        (m.width, m.height) = (960, 540)
        m.psnrMin = 99; m.psnrReference = "reference.mp4"  // impossible floor, but for the other file
        try m.write(to: golden.url("golden.json"))
        let bundle = try ProjectBundle(url: golden.url(m.project))
        let renderer = OfflineRenderer(scene: SceneModel(project: bundle.project, resolve: bundle.resolve), pool: MediaPool())
        var images: [Int: CGImage] = [:]
        for n in m.frames {
            images[n] = try await renderer.image(at: Golden.ticks(frame: n, fps: m.fps, editRate: 705_600_000),
                                                     size: CGSize(width: m.width, height: m.height))
        }
        let count = (m.frames.max() ?? 0) + 1
        let rendered = images, (w, h) = (m.width, m.height)
        try await MediaWriter.writeProRes(to: golden.url("reference.mov"), width: w, height: h, fps: m.fps,
                                          frameCount: count) { n, ctx in
            if let img = rendered[n] { ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)) }
        }
        // A wrong MP4 (all black) next to it: must be ignored.
        try await MediaWriter.writeH264(to: golden.url("reference.mp4"), width: w, height: h, fps: m.fps,
                                        frameCount: count) { _, _ in }
        let scores = try #require(try await runGoldenCase(golden))
        #expect(scores.count == m.frames.count)
        #expect(scores.allSatisfy { $0.passed }, "\(scores.filter { !$0.passed }.map(\.description))")
        // ProRes keeps PSNR far above what H.264 at 40 Mbit/s gives on the same frames.
        let minPSNR = scores.map(\.psnr).min() ?? 0
        #expect(minPSNR > 40, "ProRes reference PSNR \(minPSNR) dB")
        print(String(format: "golden mov self-test: min SSIM %.4f, min PSNR %.2f dB",
                     scores.map(\.ssim).min() ?? 0, minPSNR))

        // The same floor, now calibrated on the .mov, is enforced and fails.
        m.psnrReference = "reference.mov"
        m.frames = [0, 45]  // two frames keep the known-issue count small
        try m.write(to: golden.url("golden.json"))
        await withKnownIssue("psnrMin 99 dB on the compared file on purpose") {
            let gated = try #require(try await runGoldenCase(golden))
            #expect(gated.allSatisfy { $0.passed })
        }
    }

    @Test @MainActor func movieSheetUsesMov() async throws {
        let dir = try scratchDir("sheet-mov")
        defer { try? FileManager.default.removeItem(at: dir) }
        let media = try TestGen.makeSheetMedia(in: dir.appendingPathComponent("_m"))
        let sheet = try #require(TestGen.sheets.first { $0.name == "ef6-motionblur" })
        let frames = try #require(sheet.movieFrames)
        let caseDir = try TestGen.write(sheet, media: media, to: dir)
        let golden = GoldenSheet(name: "effects/ef6-motionblur", directory: caseDir)
        let bundle = try ProjectBundle(url: caseDir.appendingPathComponent("ef6-motionblur.cmproj"))
        let renderer = OfflineRenderer(scene: SceneModel(project: bundle.project, resolve: bundle.resolve), pool: MediaPool())
        let (w, h) = (960, 540)
        var images: [Int: CGImage] = [:]
        for n in frames {
            images[n] = try await renderer.image(at: Int64(n) * 23_520_000, size: CGSize(width: w, height: h))
        }
        let rendered = images
        try await MediaWriter.writeProRes(to: golden.url("reference.mov"), width: w, height: h, fps: 30,
                                          frameCount: (frames.max() ?? 0) + 1) { n, ctx in
            if let img = rendered[n] { ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)) }
        }
        let scores = try #require(try await runSheet(golden))
        #expect(scores.count == frames.count)
        #expect(scores.allSatisfy { $0.label.contains("reference.mov") })
        #expect(scores.allSatisfy { $0.passed }, "\(scores.filter { !$0.passed }.map(\.description))")
        #expect(scores.allSatisfy { ($0.psnr ?? 0) > 35 }, "\(scores.map(\.description))")
    }
}
