import CoreGraphics
import Foundation
import MediaEngine
import Metal
import RenderEngine
import TSCProjKit
import TestGenKit
import Testing

/// Harness plumbing that runs without references.
@Suite struct GoldenHarnessTests {
    @Test func frameTicksAreExact() {
        #expect(Golden.ticks(frame: 0, fps: 30, editRate: 705_600_000) == 0)
        #expect(Golden.ticks(frame: 45, fps: 30, editRate: 705_600_000) == 45 * 23_520_000)
        #expect(Golden.ticks(frame: 7, fps: 60, editRate: 705_600_000) == 7 * 11_760_000)
    }

    @Test func failureArtefactsAreWritten() throws {
        let a = texture(64, 48), b = addNoise(a, sigma: 10, seed: 3)
        let dir = try Golden.writeArtefacts(case: "qa-selftest-\(UUID().uuidString)", frame: 12, rendered: a,
                                            reference: b, ssim: Metrics.ssim(a, b))
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(files == ["frame-00012-diff4x.png", "frame-00012-reference.png", "frame-00012-rendered.png",
                          "frame-00012-ssim.png"])
    }

    /// `GOLDEN_CALIBRATE` record: minimum SSIM/PSNR and a PSNR floor 1 dB under the worst frame.
    @Test func calibrationRecordAndFile() throws {
        let scores = [FrameScore(frame: 0, ssim: 0.99, psnr: 41.3, foregroundSSIM: nil, passed: true),
                      FrameScore(frame: 9, ssim: 0.98, psnr: 38.74, foregroundSSIM: 0.97, passed: true)]
        let cal = try #require(Golden.calibration(case: "qa-cal", scores: scores))
        #expect(cal.frames == 2 && cal.minSSIM == 0.98 && cal.minPSNR == 38.74)
        #expect(cal.suggestedPsnrMin == 37.5)
        #expect(Golden.calibration(case: "none", scores: []) == nil)
        // Identical frames (PSNR ∞) give no floor rather than an infinite one.
        let same = [FrameScore(frame: 0, ssim: 1, psnr: .infinity, foregroundSSIM: nil, passed: true)]
        #expect(Golden.calibration(case: "same", scores: same)?.suggestedPsnrMin == nil)

        let dir = try scratchDir("golden-cal")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try Golden.writeCalibration(cal, to: dir)
        #expect(file.lastPathComponent == "qa-cal.json")
        #expect(try JSONDecoder().decode(Golden.Calibration.self, from: Data(contentsOf: file)) == cal)
    }

    /// No psnrMin is set until real Camtasia references calibrate it (S3-QA-1 TODO hook).
    @Test func psnrMinStaysUnsetWithoutReferences() {
        #expect(TestGen.psnrMinByCase.isEmpty, "set psnrMin only from real reference data (scripts/golden.sh --calibrate)")
        #expect(TestGen.cases.allSatisfy { TestGen.psnrMin(for: $0.name) == nil })
    }

    /// A generated case without `reference.mp4` is skipped (nil), not failed: what every case
    /// does until the user's exports land.
    @Test @MainActor func caseWithoutReferenceIsSkipped() async throws {
        let dir = try scratchDir("golden-noref")
        defer { try? FileManager.default.removeItem(at: dir) }
        let media = try TestGen.makeMedia(in: dir.appendingPathComponent("_media"), scale: 0.25)
        let testCase = try #require(TestGen.cases.first { $0.name == "baseline" })
        let caseDir = try TestGen.write(testCase, media: media, to: dir)
        #expect(try await runGoldenCase(GoldenCase(name: testCase.name, directory: caseDir)) == nil)
    }
}

/// End-to-end check of `runGoldenCase` without Camtasia: WizRec's own frames as
/// `reference.mp4` pass; the same frames one frame late fail.
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct GoldenHarnessSelfTests {
    @Test @MainActor func ownRenderPassesAndOneFrameLateFails() async throws {
        let dir = try scratchDir("golden-self")
        defer { try? FileManager.default.removeItem(at: dir) }
        let media = try TestGen.makeMedia(in: dir.appendingPathComponent("_media"), scale: 0.25)
        let testCase = try #require(TestGen.cases.first { $0.name == "keyframes-linear" })
        let caseDir = try TestGen.write(testCase, media: media, to: dir)
        let golden = GoldenCase(name: testCase.name, directory: caseDir)
        let m = try golden.manifest()
        let bundle = try ProjectBundle(url: golden.url(m.project))
        let renderer = OfflineRenderer(scene: SceneModel(project: bundle.project, resolve: bundle.resolve), pool: MediaPool())

        /// Reference movie with WizRec's frame `n + offset` at each compared index (others black).
        func writeReference(offset: Int) async throws {
            var images: [Int: CGImage] = [:]
            for n in m.frames {
                images[n] = try await renderer.image(at: Golden.ticks(frame: n + offset, fps: m.fps, editRate: 705_600_000),
                                                     size: CGSize(width: m.width, height: m.height))
            }
            try MediaWriter.writeH264(to: golden.url(m.reference), width: m.width, height: m.height, fps: m.fps,
                                      frameCount: (m.frames.max() ?? 0) + 1, bitsPerSecond: 40_000_000) { n, ctx in
                if let img = images[n] { ctx.draw(img, in: CGRect(x: 0, y: 0, width: m.width, height: m.height)) }
            }
        }
        try await writeReference(offset: 0)
        let scores = try #require(try await runGoldenCase(golden))
        #expect(scores.count == m.frames.count)
        let failed = scores.filter { !$0.passed }.map(\.description)
        #expect(failed.isEmpty, "\(failed)")

        try await writeReference(offset: 1)
        await withKnownIssue("reference one frame late on purpose") {
            let late = try #require(try await runGoldenCase(golden))
            #expect(late.contains { !$0.passed })
        }
    }
}

/// Golden frames against the user's Camtasia exports. Skipped unless `REFS_DIR` is set;
/// cases without a `reference.mp4` yet are skipped individually (logged).
@Suite(.enabled(if: Golden.refsDir != nil, "set REFS_DIR to run golden-frame tests"))
struct GoldenFrameTests {
    @Test("REFS_DIR exists and holds cases")
    func refsDirHoldsCases() throws {
        let dir = try #require(Golden.refsDir)
        #expect(FileManager.default.fileExists(atPath: dir.path), "REFS_DIR \(dir.path) does not exist")
        #expect(!Golden.discover().isEmpty, "no <case>/golden.json under \(dir.path); run wizrec-testgen")
    }

    /// Rendered frame vs reference frame, SSIM ≥ the manifest's `ssimMin` (0.97 for effect-free cases).
    @Test("render matches reference", arguments: Golden.discover())
    @MainActor
    func renderMatchesReference(_ c: GoldenCase) async throws {
        _ = try await runGoldenCase(c)
    }

    /// Black-box check of the export itself (no renderer): where test card A fills the canvas,
    /// its barcode must show the source frame the time-mapping spec predicts.
    @Test("reference shows the predicted source frames", arguments: Golden.discover())
    func referenceShowsPredictedSourceFrames(_ c: GoldenCase) async throws {
        let m = try c.manifest()
        guard let expected = m.sourceFrames, !expected.isEmpty else { return }
        guard let ref = ReferenceFile.resolve(in: c.directory, declared: m.reference) else {
            print("golden \(m.caseName): no \(m.reference) yet, skipped")
            return
        }
        let pairs = expected.compactMap { k, v in Int(k).map { ($0, v) } }.sorted { $0.0 < $1.0 }
        let frames = try await MovieFrameReader.frames(ref, indices: pairs.map(\.0))
        let card = TestCard(width: m.width, height: m.height, label: "A")
        for (n, source) in pairs {
            let image = try #require(frames[n])
            let shown = card.decodeFrameNumber(image)
            #expect(shown == source, "\(m.caseName) frame \(n): barcode shows \(shown.map(String.init) ?? "nothing"), expected source frame \(source)")
        }
    }
}
