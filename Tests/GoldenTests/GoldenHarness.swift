import CoreGraphics
import Foundation
import MediaEngine
import RenderEngine
import TestGenKit
import Testing
import TSCProjKit

/// Golden-frame harness: renders a case with `OfflineRenderer` and compares it
/// with the user's Camtasia export of the same project.
///
/// `REFS_DIR` layout (written by `wizrec-testgen`, default
/// `~/WorkDir/vibe_coding/camtasia_rea_refs/`, outside the repo):
/// ```
/// $REFS_DIR/<case>/golden.json      GoldenManifest: frames, thresholds
/// $REFS_DIR/<case>/<case>.cmproj/   the project and its synthetic media
/// $REFS_DIR/<case>/reference.mp4    the user's export (1920×1080, 30 fps)
/// ```
/// Environment:
/// - `REFS_DIR`: enables the golden tests (they skip without it).
/// - `GOLDEN_OUT`: where failure artefacts go (default `$TMPDIR/WizRecGolden`).
/// - `GOLDEN_DUMP=1`: write artefacts for every compared frame, not just failures.
enum Golden {
    static var refsDir: URL? {
        guard let p = ProcessInfo.processInfo.environment["REFS_DIR"], !p.isEmpty else { return nil }
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
    }

    static var outputDir: URL {
        if let p = ProcessInfo.processInfo.environment["GOLDEN_OUT"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("WizRecGolden", isDirectory: true)
    }

    static var dumpAll: Bool { ProcessInfo.processInfo.environment["GOLDEN_DUMP"] == "1" }

    /// Every `<case>/golden.json` under `REFS_DIR`, by name; empty without `REFS_DIR`.
    static func discover() -> [GoldenCase] {
        guard let root = refsDir,
              let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return dirs.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("golden.json").path) }
            .map { GoldenCase(name: $0.lastPathComponent, directory: $0) }
            .sorted { $0.name < $1.name }
    }

    /// Timeline ticks of export frame `n` at `fps` (frame n is shown at n / fps s).
    static func ticks(frame n: Int, fps: Int, editRate: Int64) -> Int64 {
        Int64(n) * editRate / Int64(fps)
    }

    /// Writes rendered / reference / diff / SSIM-map PNGs for one frame; returns the directory.
    @discardableResult
    static func writeArtefacts(case name: String, frame n: Int, rendered: RGBAImage, reference: RGBAImage,
                               ssim: Metrics.SSIMResult?) throws -> URL {
        let dir = outputDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tag = String(format: "%05d", n)
        func save(_ img: RGBAImage, _ suffix: String) throws {
            guard let cg = img.cgImage() else { return }
            try MediaWriter.writePNG(cg, to: dir.appendingPathComponent("frame-\(tag)-\(suffix).png"))
        }
        try save(rendered, "rendered")
        try save(reference, "reference")
        if rendered.width == reference.width, rendered.height == reference.height {
            try save(Metrics.difference(rendered, reference), "diff4x")
        }
        if let ssim { try save(Metrics.mapImage(ssim), "ssim") }
        return dir
    }
}

/// One case directory under `REFS_DIR`.
struct GoldenCase: Sendable, CustomTestStringConvertible {
    let name: String
    let directory: URL
    var testDescription: String { name }

    func manifest() throws -> GoldenManifest {
        try GoldenManifest.load(directory.appendingPathComponent("golden.json"))
    }

    func url(_ relative: String) -> URL { directory.appendingPathComponent(relative) }
}

/// Result of comparing one frame.
struct FrameScore: CustomStringConvertible {
    let frame: Int
    let ssim: Double
    let psnr: Double
    let passed: Bool
    var description: String {
        String(format: "frame %4d  SSIM %.4f  PSNR %6.2f dB  %@", frame, ssim, psnr, passed ? "ok" : "FAIL")
    }
}

/// Renders the case's frames and scores them against the reference.
/// Returns `nil` (and logs) when the case has no reference export yet.
@MainActor
func runGoldenCase(_ c: GoldenCase) async throws -> [FrameScore]? {
    let m = try c.manifest()
    let refURL = c.url(m.reference)
    guard FileManager.default.fileExists(atPath: refURL.path) else {
        print("golden \(m.caseName): no \(m.reference) yet, skipped")
        return nil
    }
    let info = try await MovieFrameReader.info(refURL)
    #expect(info.width == m.width && info.height == m.height,
            "\(m.caseName): reference is \(info.width)×\(info.height), expected \(m.width)×\(m.height)")
    #expect(abs(info.fps - Double(m.fps)) < 0.01, "\(m.caseName): reference is \(info.fps) fps, expected \(m.fps)")

    let bundle = try ProjectBundle(url: c.url(m.project))
    #expect(bundle.missingMedia().isEmpty, "\(m.caseName): missing media \(bundle.missingMedia().map(\.src))")
    let scene = SceneModel(project: bundle.project, resolve: bundle.resolve)
    let renderer = OfflineRenderer(scene: scene, pool: MediaPool())
    let editRate = bundle.project.timebase.editRate
    let references = try await MovieFrameReader.frames(refURL, indices: m.frames)

    var scores: [FrameScore] = []
    for n in m.frames {
        guard let reference = references[n] else { continue }
        let ticks = Golden.ticks(frame: n, fps: m.fps, editRate: editRate)
        let cg = try await renderer.image(at: ticks, size: CGSize(width: reference.width, height: reference.height))
        let rendered = RGBAImage(cg)
        guard rendered.width == reference.width, rendered.height == reference.height else {
            let dir = try Golden.writeArtefacts(case: m.caseName, frame: n, rendered: rendered, reference: reference,
                                                ssim: nil)
            Issue.record("\(m.caseName) frame \(n): rendered \(rendered.width)×\(rendered.height), reference \(reference.width)×\(reference.height); artefacts in \(dir.path)")
            continue
        }
        let ssim = Metrics.ssim(rendered, reference)
        let psnr = Metrics.psnr(rendered, reference)
        let passed = ssim.mean >= m.ssimMin && psnr >= (m.psnrMin ?? -.infinity)
        let score = FrameScore(frame: n, ssim: ssim.mean, psnr: psnr, passed: passed)
        scores.append(score)
        print("golden \(m.caseName): \(score)")
        if !passed || Golden.dumpAll {
            let dir = try Golden.writeArtefacts(case: m.caseName, frame: n, rendered: rendered, reference: reference,
                                                ssim: ssim)
            if !passed {
                let expect = m.expectations["\(n)"].map { " (expected: \($0))" } ?? ""
                Issue.record("\(m.caseName) frame \(n): SSIM \(String(format: "%.4f", ssim.mean)) < \(m.ssimMin) or PSNR \(String(format: "%.2f", psnr)) < \(m.psnrMin ?? 0)\(expect); artefacts in \(dir.path)")
            }
        }
    }
    return scores
}
