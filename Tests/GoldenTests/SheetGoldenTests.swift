import CoreGraphics
import Foundation
import MediaEngine
import Metal
import RenderEngine
import TestGenKit
import Testing
import TSCProjKit

/// Effect and callout sheets (`wizrec-testgen sheets`) against the user's Camtasia
/// references: `reference.png` (Export Frame at the playhead), `reference.mp4`
/// (movie sheets), or the `ProjectThumbnail` Camtasia saved into the project.
///
/// Layout: `$REFS_DIR/{effects,callouts}/<case>/sheet.json` (`SheetManifest`).
/// A sheet is skipped (logged) when it is a placeholder, has no reference yet, or
/// uses something RenderEngine does not draw yet (an effect outside
/// `Compositor.renderedEffects`, or an `.unsupported` layer such as callouts before M5).
/// Pass = whole-frame and every cell's colour SSIM (`Metrics.colorSSIM`: min of luma, R, G, B SSIM)
/// ≥ `ssimMin` (0.95, CLAUDE.md M4).
enum SheetGolden {
    static let groups = ["effects", "callouts", "research/cursor"]

    static func discover() -> [GoldenSheet] {
        guard let root = Golden.refsDir else { return [] }
        let fm = FileManager.default
        return groups.flatMap { group -> [GoldenSheet] in
            let dir = root.appendingPathComponent(group, isDirectory: true)
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            return names.filter { fm.fileExists(atPath: dir.appendingPathComponent("\($0)/sheet.json").path) }
                .map { GoldenSheet(name: "\(group)/\($0)", directory: dir.appendingPathComponent($0, isDirectory: true)) }
        }.sorted { $0.name < $1.name }
    }

    /// What a reference is, and the timeline time it shows.
    enum Reference {
        /// Export Frame PNG (any size; rendered at that size).
        case still(RGBAImage, ticks: Int64)
        /// Camtasia's saved thumbnail; compared against a canvas-size render box-averaged down.
        case thumbnail(RGBAImage, ticks: Int64)
        /// Movie frames by index.
        case movie([Int: RGBAImage], fps: Int)
    }

    /// Effect names and unsupported clip types anywhere in `plan` that RenderEngine does not draw.
    static func undrawn(_ plan: RenderPlan) -> Set<String> {
        var out = Set<String>()
        func visit(_ layer: Layer) {
            for e in layer.effects where !e.bypassed && !Compositor.renderedEffects.contains(e.name) { out.insert(e.name) }
            switch layer.content {
            case .unsupported(let type): out.insert(type)
            case .group(let children): children.forEach(visit)
            case .transition(_, let from, let to): [from, to].compactMap { $0 }.forEach(visit)
            default: break
            }
        }
        plan.layers.forEach(visit)
        return out
    }

    /// Cell rectangle scaled from canvas px to an image of `size`, as integer px.
    static func cellRect(_ cell: SheetCell, canvas: (Int, Int), image: (Int, Int)) -> (x: Int, y: Int, w: Int, h: Int) {
        let sx = Double(image.0) / Double(canvas.0), sy = Double(image.1) / Double(canvas.1)
        let r = cell.rect.count == 4 ? cell.rect : [0, 0, Double(canvas.0), Double(canvas.1)]
        let x = Int((r[0] * sx).rounded()), y = Int((r[1] * sy).rounded())
        return (x, y, Int(((r[0] + r[2]) * sx).rounded()) - x, Int(((r[1] + r[3]) * sy).rounded()) - y)
    }
}

/// One sheet directory under `REFS_DIR`.
struct GoldenSheet: Sendable, CustomTestStringConvertible {
    let name: String
    let directory: URL
    var testDescription: String { name }
    func manifest() throws -> SheetManifest { try SheetManifest.load(directory.appendingPathComponent("sheet.json")) }
    func url(_ relative: String) -> URL { directory.appendingPathComponent(relative) }
}

/// Score of one compared image: whole frame and per cell.
struct SheetScore: CustomStringConvertible {
    let label: String
    let whole: Double
    let cells: [(id: Int, ssim: Double)]
    let threshold: Double
    var failedCells: [Int] { cells.filter { $0.ssim < threshold }.map(\.id) }
    var passed: Bool { whole >= threshold && failedCells.isEmpty }
    var description: String {
        let c = cells.map { String(format: "%d:%.3f", $0.id, $0.ssim) }.joined(separator: " ")
        return String(format: "%@  SSIM %.4f  cells [%@]  %@", label, whole, c, passed ? "ok" : "FAIL")
    }
}

/// Picks the best available reference for `m`: movie for movie sheets, else PNG, else thumbnail.
@MainActor
func sheetReference(_ s: GoldenSheet, _ m: SheetManifest, bundle: ProjectBundle) async throws -> SheetGolden.Reference? {
    let fm = FileManager.default
    let editRate = bundle.project.timebase.editRate
    let ticks = DocPrefs.playhead(in: bundle.directory) ?? Golden.ticks(frame: m.playheadFrame, fps: m.fps, editRate: editRate)
    if let movie = m.referenceMovie, let frames = m.movieFrames, fm.fileExists(atPath: s.url(movie).path) {
        return .movie(try await MovieFrameReader.frames(s.url(movie), indices: frames), fps: m.fps)
    }
    if fm.fileExists(atPath: s.url(m.referenceImage).path) {
        guard let img = loadImage(s.url(m.referenceImage)) else {
            Issue.record("\(s.name): \(m.referenceImage) is not a readable image")
            return nil
        }
        return .still(img, ticks: ticks)
    }
    if let thumb = ProjectThumbnail.image(in: bundle.project) { return .thumbnail(thumb, ticks: ticks) }
    return nil
}

/// Renders and scores one sheet; nil when skipped (logged).
@MainActor
func runSheet(_ s: GoldenSheet) async throws -> [SheetScore]? {
    let m = try s.manifest()
    guard m.status == "ready", let projectPath = m.project else {
        print("sheet \(s.name): \(m.status), skipped")
        return nil
    }
    let bundle = try ProjectBundle(url: s.url(projectPath))
    #expect(bundle.missingMedia().isEmpty, "\(s.name): missing media \(bundle.missingMedia().map(\.src))")
    guard let reference = try await sheetReference(s, m, bundle: bundle) else {
        print("sheet \(s.name): no reference yet (reference.png, reference.mp4 or a Camtasia save), skipped")
        return nil
    }
    let scene = SceneModel(project: bundle.project, resolve: bundle.resolve)
    let editRate = bundle.project.timebase.editRate
    let probeTicks: Int64 = switch reference {
    case .still(_, let t), .thumbnail(_, let t): t
    case .movie: Golden.ticks(frame: m.playheadFrame, fps: m.fps, editRate: editRate)
    }
    let missing = SheetGolden.undrawn(scene.evaluate(at: probeTicks))
    guard missing.isEmpty else {
        print("sheet \(s.name): RenderEngine does not draw \(missing.sorted().joined(separator: ", ")) yet, skipped")
        return nil
    }
    let renderer = OfflineRenderer(scene: scene, pool: MediaPool())
    let canvas = (m.width, m.height)
    let bg = scene.evaluate(at: 0).background
    let bg8 = (UInt8((bg.r * 255).rounded()), UInt8((bg.g * 255).rounded()), UInt8((bg.b * 255).rounded()))

    func score(_ label: String, frame: Int, rendered: RGBAImage, reference ref: RGBAImage) throws -> SheetScore {
        let ref = ref.flattened(over: bg8)
        guard rendered.width == ref.width, rendered.height == ref.height else {
            Issue.record("\(s.name) \(label): rendered \(rendered.width)×\(rendered.height), reference \(ref.width)×\(ref.height)")
            return SheetScore(label: label, whole: 0, cells: [], threshold: m.ssimMin)
        }
        let whole = Metrics.ssim(rendered, ref)
        let cells = m.cells.map { cell -> (id: Int, ssim: Double) in
            let r = SheetGolden.cellRect(cell, canvas: canvas, image: (ref.width, ref.height))
            let a = rendered.cropped(x: r.x, y: r.y, width: r.w, height: r.h)
            let b = ref.cropped(x: r.x, y: r.y, width: r.w, height: r.h)
            return (cell.id, a.width > 11 && a.height > 11 ? Metrics.colorSSIM(a, b) : 1)
        }
        let result = SheetScore(label: label, whole: Metrics.colorSSIM(rendered, ref), cells: cells, threshold: m.ssimMin)
        print("sheet \(s.name): \(result)")
        if !result.passed || Golden.dumpAll {
            let dir = try Golden.writeArtefacts(case: s.name.replacingOccurrences(of: "/", with: "-"), frame: frame,
                                                rendered: rendered, reference: ref, ssim: whole)
            if !result.passed {
                let notes = m.cells.filter { result.failedCells.contains($0.id) }
                    .map { "cell \($0.id) (\($0.settings))" }.joined(separator: "; ")
                Issue.record("\(s.name) \(label): SSIM \(String(format: "%.4f", result.whole)) / failing cells: \(notes.isEmpty ? "none" : notes) (min \(m.ssimMin)); artefacts in \(dir.path)")
            }
        }
        return result
    }

    switch reference {
    case .still(let ref, let ticks):
        let cg = try await renderer.image(at: ticks, size: CGSize(width: ref.width, height: ref.height))
        let frame = Int(ticks * Int64(m.fps) / editRate)
        return [try score("frame \(frame) (reference.png)", frame: frame, rendered: RGBAImage(cg), reference: ref)]
    case .thumbnail(let ref, let ticks):
        let frame = Int(ticks * Int64(m.fps) / editRate)
        let rendered: RGBAImage
        if let k = ProjectThumbnail.factor(canvas: canvas, thumbnail: (ref.width, ref.height)) {
            let cg = try await renderer.image(at: ticks, size: CGSize(width: m.width, height: m.height))
            rendered = RGBAImage(cg).boxDownsampled(by: k)
        } else {
            rendered = RGBAImage(try await renderer.image(at: ticks, size: CGSize(width: ref.width, height: ref.height)))
        }
        return [try score("frame \(frame) (ProjectThumbnail \(ref.width)×\(ref.height))", frame: frame, rendered: rendered,
                          reference: ref)]
    case .movie(let frames, let fps):
        var out: [SheetScore] = []
        for n in (m.movieFrames ?? []).sorted() {
            guard let ref = frames[n] else { continue }
            let cg = try await renderer.image(at: Golden.ticks(frame: n, fps: fps, editRate: editRate),
                                              size: CGSize(width: ref.width, height: ref.height))
            out.append(try score("frame \(n) (reference.mp4)", frame: n, rendered: RGBAImage(cg), reference: ref))
        }
        return out
    }
}

/// Harness plumbing that runs without references.
@Suite struct SheetHarnessTests {
    @Test func cellRectsScaleToThumbnails() {
        let cell = SheetCell(id: 1, rect: [480, 360, 480, 360], settings: "", answers: "")
        let r = SheetGolden.cellRect(cell, canvas: (1920, 1080), image: (640, 360))
        #expect(r.x == 160 && r.y == 120 && r.w == 160 && r.h == 120)
        let full = SheetGolden.cellRect(cell, canvas: (1920, 1080), image: (1920, 1080))
        #expect(full.x == 480 && full.w == 480)
    }

    @Test func thumbnailFactor() {
        #expect(ProjectThumbnail.factor(canvas: (1920, 1080), thumbnail: (640, 360)) == 3)
        #expect(ProjectThumbnail.factor(canvas: (1280, 720), thumbnail: (640, 360)) == 2)
        #expect(ProjectThumbnail.factor(canvas: (1920, 1080), thumbnail: (600, 360)) == nil)
    }

    @Test func boxDownsampleAveragesBlocks() {
        var px = [UInt8](repeating: 0, count: 6 * 3 * 4)
        for i in 0..<(6 * 3) { px[4 * i] = i % 2 == 0 ? 0 : 255; px[4 * i + 3] = 255 }  // alternating columns
        let img = RGBAImage(width: 6, height: 3, pixels: px).boxDownsampled(by: 3)
        #expect(img.width == 2 && img.height == 1)
        #expect(img.pixel(0, 0).r == 85 && img.pixel(1, 0).r == 170)  // (0+255+0)/3, (255+0+255)/3
    }

    @Test func flattenOverBackground() {
        let img = RGBAImage(width: 1, height: 1, pixels: [255, 0, 0, 128]).flattened(over: (255, 255, 255))
        #expect(img.pixel(0, 0) == (255, 127, 127, 255))
    }

    /// A Camtasia-style thumbnail and playhead round-trip through the extractor.
    @Test func thumbnailAndPlayheadExtraction() throws {
        let dir = try scratchDir("thumb")
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("t.png")
        try MediaWriter.writePNG(to: png, width: 64, height: 36) { ctx in
            ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        }
        let b64 = try Data(contentsOf: png).base64EncodedString()
        let project = try Project(data: Data(#"{"metadata":{"ProjectThumbnail":"\#(b64)"},"x":1.50}"#.utf8))
        let img = try #require(ProjectThumbnail.image(in: project))
        #expect(img.width == 64 && img.height == 36 && img.pixel(10, 10) == (255, 0, 0, 255))
        #expect(ProjectThumbnail.image(in: try Project(data: Data(#"{"metadata":{}}"#.utf8))) == nil)

        try DocPrefs.write(playhead: 705_600_000, to: dir)
        #expect(DocPrefs.playhead(in: dir) == 705_600_000)
        #expect(DocPrefs.playhead(in: dir.appendingPathComponent("nope")) == nil)
    }

    /// The demo bundle's real thumbnail, when the user's project is present (read-only).
    @Test func demoThumbnailIfPresent() throws {
        let demo = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/demo project.cmproj")
        guard FileManager.default.fileExists(atPath: demo.path) else { return }
        let bundle = try ProjectBundle(url: demo)
        let img = try #require(ProjectThumbnail.image(in: bundle.project))
        #expect(ProjectThumbnail.factor(canvas: (Int(bundle.project.width), Int(bundle.project.height)),
                                        thumbnail: (img.width, img.height)) == 3)
        #expect(DocPrefs.playhead(in: demo) == 8_537_760_000)
    }
}

/// Golden sheets. Skipped unless `REFS_DIR` is set.
@Suite(.enabled(if: Golden.refsDir != nil, "set REFS_DIR to run golden-sheet tests"))
struct SheetGoldenTests {
    @Test("sheet render matches Camtasia reference", arguments: SheetGolden.discover())
    @MainActor
    func sheetMatchesReference(_ s: GoldenSheet) async throws {
        _ = try await runSheet(s)
    }
}

/// `GOLDEN_PREVIEW=1`: generates every ready sheet (full-size media, temp dir) and writes
/// WizRec's render at the playhead (or each movie frame) to `$GOLDEN_OUT/preview/`, so a
/// sheet can be checked by eye before the user opens it in Camtasia.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GOLDEN_PREVIEW"] == "1", "set GOLDEN_PREVIEW=1"))
struct SheetPreviewTests {
    @Test @MainActor func renderPreviews() async throws {
        let dir = try scratchDir("sheet-preview")
        defer { try? FileManager.default.removeItem(at: dir) }
        let media = try TestGen.makeSheetMedia(in: dir.appendingPathComponent("_sheet-media"))
        let out = Golden.outputDir.appendingPathComponent("preview", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for sheet in TestGen.sheets where !sheet.isPlaceholder {
            let caseDir = try TestGen.write(sheet, media: media, to: dir)
            let bundle = try ProjectBundle(url: caseDir.appendingPathComponent("\(sheet.name).cmproj"))
            let scene = SceneModel(project: bundle.project, resolve: bundle.resolve)
            let renderer = OfflineRenderer(scene: scene, pool: MediaPool())
            for n in sheet.movieFrames ?? [sheet.playheadFrame] {
                let cg = try await renderer.image(at: Golden.ticks(frame: n, fps: 30, editRate: 705_600_000),
                                                  size: CGSize(width: 1920, height: 1080))
                let file = out.appendingPathComponent(String(format: "%@-%03d.png", sheet.name, n))
                try MediaWriter.writePNG(cg, to: file)
            }
            let undrawn = SheetGolden.undrawn(scene.evaluate(at: Golden.ticks(frame: sheet.playheadFrame, fps: 30, editRate: 705_600_000)))
            print("preview \(sheet.name): \(undrawn.isEmpty ? "all drawn" : "not drawn yet: \(undrawn.sorted())")")
        }
        print("previews in \(out.path)")
    }
}

/// End-to-end check of the sheet harness without Camtasia: WizRec's own render used as
/// `reference.png`, then as a `ProjectThumbnail`, must pass; a damaged cell must fail.
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct SheetHarnessSelfTests {
    @MainActor func makeSheet(_ name: String) async throws -> (dir: URL, sheet: GoldenSheet, ref: RGBAImage) {
        let dir = try scratchDir("sheet-self")
        let media = try TestGen.makeSheetMedia(in: dir.appendingPathComponent("_m"))
        let sheet = try #require(TestGen.sheets.first { $0.name == name })
        let caseDir = try TestGen.write(sheet, media: media, to: dir)
        let bundle = try ProjectBundle(url: caseDir.appendingPathComponent("\(name).cmproj"))
        let renderer = OfflineRenderer(scene: SceneModel(project: bundle.project, resolve: bundle.resolve), pool: MediaPool())
        let cg = try await renderer.image(at: Int64(sheet.playheadFrame) * 23_520_000, size: CGSize(width: 1920, height: 1080))
        return (dir, GoldenSheet(name: "effects/\(name)", directory: caseDir), RGBAImage(cg))
    }

    @Test @MainActor func ownRenderPassesAsPNGAndThumbnail() async throws {
        let (dir, sheet, ref) = try await makeSheet("ef2-roundcorners")
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = sheet.url("reference.png")
        try MediaWriter.writePNG(try #require(ref.cgImage()), to: png)
        let still = try #require(try await runSheet(sheet))
        #expect(still.count == 1 && still[0].passed && still[0].whole > 0.999)

        // Same render as a Camtasia-style 640×360 thumbnail inside the project.
        try FileManager.default.removeItem(at: png)
        let thumbFile = dir.appendingPathComponent("thumb.png")
        try MediaWriter.writePNG(try #require(ref.boxDownsampled(by: 3).cgImage()), to: thumbFile)
        let bundleURL = sheet.url("ef2-roundcorners.cmproj")
        let bundle = try ProjectBundle(url: bundleURL)
        bundle.project.root["metadata"]?.object?["ProjectThumbnail"] = .string(try Data(contentsOf: thumbFile).base64EncodedString())
        try bundle.saveWithBackup()
        let thumb = try #require(try await runSheet(sheet))
        #expect(thumb.count == 1 && thumb[0].passed && thumb[0].whole > 0.99)
    }

    @Test @MainActor func damagedCellFails() async throws {
        let (dir, sheet, ref) = try await makeSheet("ef2-roundcorners")
        defer { try? FileManager.default.removeItem(at: dir) }
        var bad = ref
        for y in 0..<360 { for x in 480..<960 { bad.pixels[4 * (y * 1920 + x)] = 0 } }  // cell 2: red off (luma SSIM alone misses it)
        try MediaWriter.writePNG(try #require(bad.cgImage()), to: sheet.url("reference.png"))
        await withKnownIssue("cell 2 was damaged on purpose") {
            let scores = try #require(try await runSheet(sheet))
            #expect(scores[0].failedCells == [2])
        }
    }
}
