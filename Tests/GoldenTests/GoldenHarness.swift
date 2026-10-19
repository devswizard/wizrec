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
/// - `GOLDEN_CALIBRATE=1`: write `$GOLDEN_OUT/calibration/<case>.json` with the minimum
///   SSIM/PSNR seen, the input for `TestGen.psnrMin(for:)` once real references exist.
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

    static var calibrate: Bool { ProcessInfo.processInfo.environment["GOLDEN_CALIBRATE"] == "1" }

    /// Per-case calibration record (`GOLDEN_CALIBRATE=1`). `suggestedPsnrMin` is the lowest
    /// PSNR over the compared frames minus a 1 dB margin, floored to 0.5 dB; dB.
    struct Calibration: Codable, Equatable {
        var caseName: String
        var frames: Int
        var minSSIM: Double
        var minPSNR: Double
        var suggestedPsnrMin: Double?
    }

    /// Builds the calibration record from scores; `nil` when no frame was compared.
    static func calibration(case name: String, scores: [FrameScore]) -> Calibration? {
        guard let minSSIM = scores.map(\.ssim).min(), let minPSNR = scores.map(\.psnr).min() else { return nil }
        let suggested = minPSNR.isFinite ? ((minPSNR - 1) * 2).rounded(.down) / 2 : nil
        return Calibration(caseName: name, frames: scores.count, minSSIM: minSSIM, minPSNR: minPSNR,
                           suggestedPsnrMin: suggested)
    }

    /// Writes `<dir>/calibration/<case>.json`; returns the file.
    @discardableResult
    static func writeCalibration(_ c: Calibration, to dir: URL = outputDir) throws -> URL {
        let out = dir.appendingPathComponent("calibration", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let file = out.appendingPathComponent("\(c.caseName).json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        try enc.encode(c).write(to: file, options: .atomic)
        return file
    }

    /// Allowed marker-centroid distance, px: 2 px at 1920 wide, scaled with the frame.
    static func markerTolerance(width: Int) -> Double { max(1, 2 * Double(width) / 1920) }

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
    /// Luma SSIM over the foreground box (`SheetGolden.foregroundBox`); nil when the frame is all background.
    var foregroundSSIM: Double? = nil
    let passed: Bool
    var description: String {
        String(format: "frame %4d  SSIM %.4f  fg %@  PSNR %6.2f dB  %@", frame, ssim,
               foregroundSSIM.map { String(format: "%.4f", $0) } ?? "–", psnr, passed ? "ok" : "FAIL")
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
    let bg = scene.evaluate(at: 0).background
    let bg8 = (UInt8((bg.r * 255).rounded()), UInt8((bg.g * 255).rounded()), UInt8((bg.b * 255).rounded()))

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
        // A small clip moving over the background barely dents whole-frame SSIM when it is a
        // frame off (see SheetGolden.foregroundBox), so the foreground box must pass too.
        var fg: Double?
        if let b = SheetGolden.foregroundBox(rendered, reference, background: bg8), b.w > 11, b.h > 11,
           b.w * b.h < rendered.width * rendered.height * 9 / 10 {
            fg = Metrics.ssim(rendered.cropped(x: b.x, y: b.y, width: b.w, height: b.h),
                              reference.cropped(x: b.x, y: b.y, width: b.w, height: b.h)).mean
        }
        // Marker cases: the magenta marker must sit where the reference has it (whole-frame
        // SSIM stays ≥ 0.996 with the marker one frame / 27 px off; the centroid does not).
        var markerOff: Double?
        if let a = MarkerTracker.centroid(rendered), a.pixels >= 100 {
            // Search the reference only near the rendered marker (±3 marker sizes).
            let r = Int(3 * Double(a.pixels).squareRoot()), cx = Int(a.x), cy = Int(a.y)
            let win = (cx - r, cy - r, cx + r, cy + r)
            if let a2 = MarkerTracker.centroid(rendered, window: win),
               let b = MarkerTracker.centroid(reference, window: win), b.pixels >= a2.pixels / 4 {
                markerOff = hypot(a2.x - b.x, a2.y - b.y)
            } else {
                markerOff = .infinity  // marker missing near where WizRec draws it
            }
        }
        let markerOK = (markerOff ?? 0) <= Golden.markerTolerance(width: rendered.width)
        if let markerOff, !markerOK {
            print(String(format: "golden %@ frame %d: marker %.1f px off", m.caseName, n, markerOff))
        }
        let passed = ssim.mean >= m.ssimMin && (fg ?? 1) >= m.ssimMin && markerOK
            && psnr >= (m.psnrMin ?? -.infinity)
        let score = FrameScore(frame: n, ssim: ssim.mean, psnr: psnr, foregroundSSIM: fg, passed: passed)
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
    if Golden.calibrate, let cal = Golden.calibration(case: m.caseName, scores: scores) {
        let file = try Golden.writeCalibration(cal)
        print("golden \(m.caseName): calibration → \(file.path)")
    }
    return scores
}
