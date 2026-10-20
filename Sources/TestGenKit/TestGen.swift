import Foundation
import TSCProjKit

/// `golden.json`: what the golden harness compares for one case.
///
/// Layout of `$REFS_DIR/<case>/`:
/// ```
/// golden.json          this manifest (written by wizrec-testgen)
/// <case>.cmproj/       the project, with its media under media/<ts>/
/// reference.mp4        the user's Camtasia export (1920×1080, 30 fps)
/// reference.mov        optional ProRes export of the same, preferred when present
///                      (`ReferenceFile.resolve`)
/// ```
public struct GoldenManifest: Codable, Sendable, Equatable {
    /// Case name (`"case"` in JSON).
    public var caseName: String
    public var summary: String
    /// Project bundle path, relative to the case directory.
    public var project: String
    /// Reference export path, relative to the case directory.
    public var reference: String
    /// Export frame rate, fps; frame n is timeline time n / fps.
    public var fps: Int
    /// Export size, px.
    public var width: Int
    public var height: Int
    /// Number of frames the export must contain.
    public var durationFrames: Int
    /// Frames to compare.
    public var frames: [Int]
    /// Minimum mean SSIM per frame (luma BT.709, 11×11 Gaussian σ 1.5).
    public var ssimMin: Double
    /// Optional minimum PSNR per frame, dB (RGB).
    public var psnrMin: Double?
    /// Reference file name `psnrMin` was calibrated on (`reference.mov` …): the floor is
    /// enforced only when the harness compares against that file. nil: any reference.
    public var psnrReference: String?
    /// Frame (as a string) → what a correct render shows.
    public var expectations: [String: String]
    /// Timeline frame (as a string) → source frame of clip A the export must show
    /// (cases where A fills the canvas untransformed; checked by decoding its barcode).
    public var sourceFrames: [String: Int]?
    /// `wizrec-testgen` version that wrote the case.
    public var generator: String

    enum CodingKeys: String, CodingKey {
        case caseName = "case", summary, project, reference, fps, width, height, durationFrames, frames, ssimMin,
             psnrMin, psnrReference, expectations, sourceFrames, generator
    }

    public init(caseName: String, summary: String, project: String, reference: String, fps: Int, width: Int,
                height: Int, durationFrames: Int, frames: [Int], ssimMin: Double, psnrMin: Double?,
                psnrReference: String? = nil, expectations: [String: String], sourceFrames: [String: Int]? = nil,
                generator: String) {
        self.caseName = caseName; self.summary = summary; self.project = project; self.reference = reference
        self.fps = fps; self.width = width; self.height = height; self.durationFrames = durationFrames
        self.frames = frames; self.ssimMin = ssimMin; self.psnrMin = psnrMin; self.psnrReference = psnrReference
        self.expectations = expectations
        self.sourceFrames = sourceFrames; self.generator = generator
    }

    public static func load(_ url: URL) throws -> GoldenManifest {
        try JSONDecoder().decode(GoldenManifest.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try e.encode(self).write(to: url, options: .atomic)
    }
}

/// A PSNR floor calibrated on one reference file.
public struct PSNRFloor: Sendable, Equatable {
    /// Minimum PSNR, dB (RGB).
    public var dB: Double
    /// Reference file it was measured on (`reference.mov`, `reference.mp4`, `reference.png`).
    /// Camtasia's H.264 exports are not bit-reproducible, so a floor measured on a ProRes
    /// file never gates an MP4 comparison.
    public var reference: String
    public init(dB: Double, reference: String) { self.dB = dB; self.reference = reference }
}

/// Thresholds for one effect/callout sheet (default: colour SSIM 0.95, no PSNR floor).
public struct SheetThreshold: Sendable, Equatable {
    /// Minimum colour SSIM, whole frame and per cell.
    public var ssimMin: Double
    /// Optional whole-frame PSNR floor.
    public var psnr: PSNRFloor?
    public init(ssimMin: Double = 0.95, psnr: PSNRFloor? = nil) { self.ssimMin = ssimMin; self.psnr = psnr }
}

/// Which reference file the golden harness compares against.
public enum ReferenceFile {
    /// The file to compare for a declared reference. A sibling `.mov` (ProRes: decodes the
    /// same on every run) wins over a declared `.mp4` unless `prefer == "mp4"`
    /// (env `GOLDEN_PREFER=mp4`). Falls back to whichever exists; nil when neither does.
    public static func resolve(in directory: URL, declared: String,
                               prefer: String? = ProcessInfo.processInfo.environment["GOLDEN_PREFER"]) -> URL? {
        let main = directory.appendingPathComponent(declared)
        var candidates = [main]
        if main.pathExtension.lowercased() == "mp4" {
            let mov = main.deletingPathExtension().appendingPathExtension("mov")
            candidates = prefer == "mp4" ? [main, mov] : [mov, main]
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Whether a floor calibrated on the file named `calibratedOn` gates a comparison
    /// against `used` (nil `calibratedOn`: any file).
    public static func floorApplies(calibratedOn: String?, used: URL) -> Bool {
        guard let calibratedOn else { return true }
        return calibratedOn == used.lastPathComponent
    }
}

/// Generates the golden test projects and their synthetic media.
public enum TestGen {
    public static let version = "0.1.0"

    /// Per-case PSNR floor (dB) written into `golden.json`, or `nil` for SSIM-only gating.
    ///
    /// TODO(S3-QA-1): fill from real data only. When the user's Camtasia references land,
    /// run `scripts/golden.sh --calibrate`, review `$GOLDEN_OUT/calibration/*.json`
    /// (`suggestedPsnrMin` = lowest PSNR − 1 dB), copy the values here, then rewrite the
    /// manifests with `swift run wizrec-testgen --force` (keeps `reference.mp4`).
    /// Never set these from WizRec-rendered stand-ins. See docs/testing/golden-rerun.md.
    /// `scripts/golden.sh --calibrate` prints paste-ready entries.
    public static let psnrMinByCase: [String: PSNRFloor] = [:]

    /// `psnrMinByCase[name]?.dB`; `nil` until calibrated.
    public static func psnrMin(for name: String) -> Double? { psnrMinByCase[name]?.dB }

    /// Per-sheet thresholds keyed `<group>/<case>` (`effects/ef2-roundcorners`); absent
    /// sheets get `SheetThreshold()`. Same rule as `psnrMinByCase`: real reference data only.
    public static let sheetThresholds: [String: SheetThreshold] = [:]

    /// `sheetThresholds[key]`, or the default.
    public static func sheetThreshold(for key: String) -> SheetThreshold { sheetThresholds[key] ?? SheetThreshold() }

    /// Default output: next to the repo, never inside it.
    public static var defaultOutputDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("WorkDir/vibe_coding/camtasia_rea_refs", isDirectory: true)
    }

    /// Generated media files and what they contain.
    public struct MediaSet: Sendable {
        public var directory: URL
        public var movies: [MediaID: MediaWriter.MovieInfo]
        /// Image sizes, px.
        public var images: [MediaID: (width: Int, height: Int)]
        public func url(_ id: MediaID) -> URL { directory.appendingPathComponent(id.rawValue) }
    }

    /// Writes every `MediaID` into `directory`. `scale` shrinks pixel sizes (tests use 0.1);
    /// frame counts and rates never change, so case timing is the same at any scale.
    public static func makeMedia(in directory: URL, scale: Double = 1) throws -> MediaSet {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func px(_ v: Int) -> Int { max(16, Int((Double(v) * scale / 2).rounded()) * 2) }
        var set = MediaSet(directory: directory, movies: [:], images: [:])
        for (id, w, h, label, palette) in [
            (MediaID.clipA, 1920, 1080, "A", TestCard.Palette.classic),
            (MediaID.clipB, 1280, 720, "B", TestCard.Palette.reversed),
        ] {
            let card = TestCard(width: px(w), height: px(h), label: label, palette: palette)
            set.movies[id] = try MediaWriter.writeH264(
                to: set.url(id), width: card.width, height: card.height, fps: 30, frameCount: 300,
                bitsPerSecond: scale >= 1 ? 16_000_000 : nil
            ) { n, ctx in card.draw(frame: n, fps: 30, in: ctx) }
        }
        let cw = px(1600), ch = px(900)
        try MediaWriter.writePNG(to: set.url(.card), width: cw, height: ch) { TestImages.card(width: cw, height: ch, in: $0) }
        set.images[.card] = (cw, ch)
        let ms = px(200)
        try MediaWriter.writePNG(to: set.url(.marker), width: ms, height: ms) { TestImages.marker(size: ms, in: $0) }
        set.images[.marker] = (ms, ms)
        return set
    }

    /// `makeMedia` for async callers: the encodes run on a private thread while the caller is
    /// suspended (see `MediaWriter.offMain`), so a `@MainActor` test keeps the main thread free.
    public static func makeMedia(in directory: URL, scale: Double = 1) async throws -> MediaSet {
        try await MediaWriter.offMain { try makeMedia(in: directory, scale: scale) }
    }

    /// Builds `testCase` into `<outDir>/<name>/`: the `.cmproj` (media hard-linked, or copied,
    /// from `media`) and `golden.json`. Replaces an existing bundle; never touches `reference.mp4`.
    @discardableResult
    public static func write(_ testCase: TestCase, media: MediaSet, to outDir: URL) throws -> URL {
        let fm = FileManager.default
        let caseDir = outDir.appendingPathComponent(testCase.name, isDirectory: true)
        let bundle = caseDir.appendingPathComponent("\(testCase.name).cmproj", isDirectory: true)
        try? fm.removeItem(at: bundle)
        let stamp = String(format: "%.6f", Date().timeIntervalSince1970)
        let mediaDir = bundle.appendingPathComponent("media/\(stamp)", isDirectory: true)
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        let b = ProjectBuilder(title: testCase.name)
        var sources: [MediaID: ProjectBuilder.Source] = [:]
        for id in testCase.uses {
            let dst = mediaDir.appendingPathComponent(id.rawValue)
            do { try fm.linkItem(at: media.url(id), to: dst) } catch { try fm.copyItem(at: media.url(id), to: dst) }
            let src = "./media/\(stamp)/\(id.rawValue)"
            let mod = (try? fm.attributesOfItem(atPath: dst.path)[.modificationDate] as? Date) ?? Date()
            if let movie = media.movies[id] {
                sources[id] = b.addVideoSource(src: src, movie: movie, modified: mod)
            } else if let size = media.images[id] {
                sources[id] = b.addImageSource(src: src, width: size.width, height: size.height, modified: mod)
            }
        }
        testCase.build(b, sources)
        let project = b.build()
        try project.serialized().write(to: bundle.appendingPathComponent("project.tscproj"), options: .atomic)

        let manifest = GoldenManifest(
            caseName: testCase.name, summary: testCase.summary, project: "\(testCase.name).cmproj",
            reference: "reference.mp4", fps: 30, width: 1920, height: 1080,
            durationFrames: testCase.durationFrames, frames: testCase.frames, ssimMin: 0.97, psnrMin: TestGen.psnrMin(for: testCase.name),
            psnrReference: TestGen.psnrMinByCase[testCase.name]?.reference,
            expectations: Dictionary(uniqueKeysWithValues: testCase.expectations.map { ("\($0.key)", $0.value) }),
            sourceFrames: testCase.sourceFrames.isEmpty ? nil
                : Dictionary(uniqueKeysWithValues: testCase.sourceFrames.map { ("\($0.key)", $0.value) }),
            generator: version)
        try manifest.write(to: caseDir.appendingPathComponent("golden.json"))
        return caseDir
    }
}
