import Foundation
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
        let ref = c.url(m.reference)
        guard FileManager.default.fileExists(atPath: ref.path) else {
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
