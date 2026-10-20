import Foundation
import TimelineEngine
import TSCProjKit

/// One cell of a sheet: a region of the canvas holding one clip variant.
public struct SheetCell: Codable, Sendable, Equatable {
    /// 1-based cell number, as in the spec tables.
    public var id: Int
    /// Cell rectangle in canvas px, top-left origin, y down: `[x, y, width, height]`.
    public var rect: [Double]
    /// Media and parameter settings, for humans.
    public var settings: String
    /// What the cell answers (from the spec).
    public var answers: String

    public init(id: Int, rect: [Double], settings: String, answers: String) {
        self.id = id; self.rect = rect; self.settings = settings; self.answers = answers
    }
}

/// `sheet.json`: what the effect/callout golden harness needs for one sheet.
///
/// Layout of `$REFS_DIR/<group>/<case>/`:
/// ```
/// sheet.json        this manifest (written by `wizrec-testgen sheets`)
/// <case>.cmproj/    the project; Camtasia's Save adds metadata.ProjectThumbnail + docPrefs
/// reference.png     the user's Export Frame at the playhead (full canvas size)
/// reference.mp4     only for movie sheets (EF6); a ProRes reference.mov is preferred
/// ```
public struct SheetManifest: Codable, Sendable, Equatable {
    public var caseName: String
    /// `effects` or `callouts`.
    public var group: String
    public var summary: String
    /// `ready`, or `after-EF0` for placeholders whose parameter names are still unknown.
    public var status: String
    /// Project bundle, relative to the case directory (nil for placeholders).
    public var project: String?
    /// Effect names used (`DropShadow` …), or `Callout`. The harness skips a sheet
    /// until RenderEngine draws all of them.
    public var requires: [String]
    /// Still reference (Export Frame PNG), relative.
    public var referenceImage: String
    /// Movie reference (relative) for sheets that need motion; nil for stills.
    public var referenceMovie: String?
    /// Frames of `referenceMovie` to compare.
    public var movieFrames: [Int]?
    /// Frame the playhead is parked on (docPrefs), at `fps`.
    public var playheadFrame: Int
    public var fps: Int
    /// Canvas size, px.
    public var width: Int
    public var height: Int
    /// Minimum colour SSIM, per cell and for the whole frame (CLAUDE.md M4: 0.95; per
    /// sheet from `TestGen.sheetThresholds`).
    public var ssimMin: Double
    /// Optional whole-frame PSNR floor, dB (RGB); enforced only against `psnrReference`.
    public var psnrMin: Double?
    /// Reference file name `psnrMin` was calibrated on; nil: any reference.
    public var psnrReference: String?
    public var cells: [SheetCell]
    /// What to check by eye in Camtasia.
    public var checklist: String
    public var generator: String

    enum CodingKeys: String, CodingKey {
        case caseName = "case", group, summary, status, project, requires, referenceImage, referenceMovie,
             movieFrames, playheadFrame, fps, width, height, ssimMin, psnrMin, psnrReference, cells, checklist,
             generator
    }

    public static func load(_ url: URL) throws -> SheetManifest {
        try JSONDecoder().decode(SheetManifest.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try e.encode(self).write(to: url, options: .atomic)
    }
}

/// A clip placed on its own track (sheets put one clip per track, bottom to top), plus
/// the effects TimelineEngine's `AddEffect` adds to it in order.
public struct PlacedClip {
    public var clip: JSONObject
    public var effects: [JSONObject]
    public init(_ clip: JSONObject, _ effects: [JSONObject] = []) { self.clip = clip; self.effects = effects }
}

/// One effect or callout sheet (`docs/specs/effects/*.md`, `docs/specs/callouts.md` §7).
public struct SheetCase: Sendable {
    public let name: String
    public let group: String
    public let summary: String
    public let status: String
    public let uses: [SheetMediaID]
    public let requires: [String]
    /// Timeline length, frames at 30 fps.
    public let durationFrames: Int
    public let playheadFrame: Int
    public let movieFrames: [Int]?
    public let cells: [SheetCell]
    public let checklist: String
    let build: (@Sendable (ProjectBuilder, [SheetMediaID: ProjectBuilder.Source]) -> [PlacedClip])?

    public var isPlaceholder: Bool { build == nil }
}

// MARK: Layout

/// A uniform grid on the 1920×1080 canvas. Cell `i` (0-based) runs left to right, top to bottom.
struct Grid {
    var cols: Int, rows: Int
    var cellW: Double { 1920 / Double(cols) }
    var cellH: Double { 1080 / Double(rows) }
    /// Cell centre in project coordinates (px from canvas centre, +y up).
    func centre(_ i: Int) -> (x: Double, y: Double) {
        let c = i % cols, r = i / cols
        return (-960 + cellW * (Double(c) + 0.5), 540 - cellH * (Double(r) + 0.5))
    }
    /// Cell rectangle, top-left origin, y down.
    func rect(_ i: Int) -> [Double] {
        let c = i % cols, r = i / cols
        return [cellW * Double(c), cellH * Double(r), cellW, cellH]
    }
}

private func c(_ v: Double) -> ParamSpec { .constant(v) }

/// Transform parameters for a clip centred at `p` with uniform `scale` and `rotation` (radians).
private func at(_ p: (x: Double, y: Double), scale: Double, rotation: Double? = nil) -> [String: ParamSpec] {
    var out: [String: ParamSpec] = ["translation0": c(p.x), "translation1": c(p.y), "scale0": c(scale), "scale1": c(scale)]
    if let rotation { out["rotation2"] = c(rotation) }
    return out
}

extension TestGen {
    /// Still-sheet timing: 3 s clips, playhead at 1 s.
    static let sheetFrames = 90, sheetPlayhead = 30

    /// The effect sheets EF1–EF9 and callout sheets CO1–CO2.
    public static let sheets: [SheetCase] = [ef1, ef2, ef3, ef4, ef5, ef6, ef7, ef8, ef9, co1, co2]

    // MARK: EF1 DropShadow

    static let ef1: SheetCase = {
        let g = Grid(cols: 4, rows: 3)
        // (media, scale, angle, offset, blur, opacity, rotation, colour, colour alpha, enabled, answers)
        typealias Row = (SheetMediaID, Double, Double, Double, Double, Double, Double?, (Double, Double, Double), Double, Int, String)
        let rows: [Row] = [
            (.grey, 0.5, 0, 40, 0, 1, nil, (0, 0, 0), 1, 1, "+x direction, hard edge, offset units"),
            (.grey, 0.5, .pi / 2, 40, 0, 1, nil, (0, 0, 0), 1, 1, "angle sense (up or down)"),
            (.grey, 0.25, 0, 40, 0, 1, nil, (0, 0, 0), 1, 1, "offset in canvas px or layer px (vs cell 1)"),
            (.grey, 0.5, 0, 0, 40, 1, nil, (0, 0, 0), 1, 1, "blur kernel profile"),
            (.grey, 0.25, 0, 0, 40, 1, nil, (0, 0, 0), 1, 1, "blur units (vs cell 4)"),
            (.grey, 0.5, 0, 0, 0, 1, nil, (0, 0, 0), 1, 1, "does a zero shadow still show?"),
            (.disc, 0.5, 7 * .pi / 4, 30, 10, 0.6, nil, (0, 0, 0), 1, 1, "alpha silhouette; opacity"),
            (.grey, 0.5, 0, 40, 0, 1, .pi / 4, (0, 0, 0), 1, 1, "does the shadow rotate with the layer?"),
            (.grey, 0.5, 3 * .pi / 2, 30, 0, 1, nil, (1, 0, 0), 0.5, 1, "how colour alpha combines with opacity"),
            (.grey, 0.5, 0, 40, 0, 1, nil, (0, 0, 0), 1, 0, "enabled flag"),
        ]
        let cells = rows.enumerated().map { i, r in
            SheetCell(id: i + 1, rect: g.rect(i),
                      settings: "\(r.0.specName) scale \(r.1)\(r.6.map { ", rotation2 \($0)" } ?? ""); angle \(r.2), offset \(r.3), blur \(r.4), opacity \(r.5), colour (\(r.7.0), \(r.7.1), \(r.7.2)), color-alpha \(r.8), enabled \(r.9)",
                      answers: r.10)
        }
        return SheetCase(
            name: "ef1-dropshadow", group: "effects",
            summary: "EF1 DropShadow sheet: 10 cells (4×3 grid of 480×360) on white; angle, offset, blur, units, silhouette, rotation, colour alpha, enabled.",
            status: "ready", uses: [.grey, .disc], requires: ["DropShadow"], durationFrames: sheetFrames,
            playheadFrame: sheetPlayhead, movieFrames: nil, cells: cells,
            checklist: "Ten grey squares (one disc, one rotated) with black shadows (one red). Cell 6 and cell 10 may show no shadow.",
            build: { b, m in
                rows.enumerated().map { i, r in
                    PlacedClip(b.image(m[r.0]!, start: 0, duration: f(Int64(sheetFrames)), params: at(g.centre(i), scale: r.1, rotation: r.6)),
                               [EffectJSON.dropShadow(angle: r.2, offset: r.3, blur: r.4, opacity: r.5, color: r.7,
                                                      colorAlpha: r.8, enabled: r.9)])
                }
            })
    }()

    // MARK: EF2 RoundCorners

    static let ef2: SheetCase = {
        let g = Grid(cols: 4, rows: 3)
        let rows: [(Double, Double, (Double, Double, Double, Double), String)] = [
            (0.5, 80, (1, 1, 1, 1), "basic shape; 40 canvas px radius if units are layer px"),
            (0.5, 80, (1, 0, 0, 0), "which corner is top-left"),
            (0.5, 80, (0.5, 1, 1, 1), "is a fractional flag a radius multiplier?"),
            (0.5, 400, (1, 1, 1, 1), "clamp behaviour (circle?)"),
            (0.25, 80, (1, 1, 1, 1), "units (vs cell 1)"),
        ]
        let cells = rows.enumerated().map { i, r in
            SheetCell(id: i + 1, rect: g.rect(i),
                      settings: "M-grey scale \(r.0); radius \(r.1), flags tl \(r.2.0) tr \(r.2.1) bl \(r.2.2) br \(r.2.3)",
                      answers: r.3)
        }
        return SheetCase(
            name: "ef2-roundcorners", group: "effects",
            summary: "EF2 RoundCorners sheet: 5 grey squares; radius units, corner naming, fractional flags, clamping.",
            status: "ready", uses: [.grey], requires: ["RoundCorners"], durationFrames: sheetFrames,
            playheadFrame: sheetPlayhead, movieFrames: nil, cells: cells,
            checklist: "Five grey squares with rounded corners; cell 2 has one rounded corner, cell 4 looks like a circle or a squircle.",
            build: { b, m in
                rows.enumerated().map { i, r in
                    PlacedClip(b.image(m[.grey]!, start: 0, duration: f(Int64(sheetFrames)), params: at(g.centre(i), scale: r.0)),
                               [EffectJSON.roundCorners(radius: r.1, corners: r.2)])
                }
            })
    }()

    // MARK: EF3 Mask

    static let ef3: SheetCase = {
        let g = Grid(cols: 4, rows: 3)
        let rows: [(String, String)] = [
            ("shape 0", "ellipse confirmation"),
            ("shape 1", "shape enum 1"),
            ("shape 2", "shape enum 2"),
            ("shape 1, cornerRadius 100", "corner radius units"),
            ("shape 1, positionX 300, positionY 200, rotation 0.5", "position and rotation signs"),
            ("shape 0, then DropShadow offset 40, blur 0, angle 0", "does the shadow follow the mask?"),
            ("shape 0, blend 0.1", "feather, positive"),
            ("shape 0, blend −0.1", "feather, negative"),
            ("shape 0, opacity 0.5", "outside opacity"),
            ("shape 0, invert 1", "invert"),
        ]
        let cells = rows.enumerated().map { i, r in
            SheetCell(id: i + 1, rect: g.rect(i),
                      settings: "M-card scale 0.25; mask w = h = 600 layer px, \(r.0)", answers: r.1)
        }
        return SheetCase(
            name: "ef3-mask", group: "effects",
            summary: "EF3 Mask sheet: 10 test cards (480×270) with 600×600 masks; shape enum, corner radius, position/rotation, feather, outside opacity, invert, shadow after mask.",
            status: "ready", uses: [.card], requires: ["DropShadow", "Mask"], durationFrames: sheetFrames,
            playheadFrame: sheetPlayhead, movieFrames: nil, cells: cells,
            checklist: "Ten small test cards, each cut to a shape (circle, rectangles, …). Cell 9 shows the card faintly outside the circle; cell 10 has a hole.",
            build: { b, m in
                rows.enumerated().map { i, r in
                    PlacedClip(b.image(m[.card]!, start: 0, duration: f(Int64(sheetFrames)), params: at(g.centre(i), scale: 0.25)), ef3Effects(i))
                }
            })
    }()

    /// EF3 cell `i` (0-based) effects, in the order of the spec table.
    static func ef3Effects(_ i: Int) -> [JSONObject] {
        switch i {
        case 0: [EffectJSON.mask(shape: 0)]
        case 1: [EffectJSON.mask(shape: 1)]
        case 2: [EffectJSON.mask(shape: 2)]
        case 3: [EffectJSON.mask(shape: 1, cornerRadius: 100)]
        case 4: [EffectJSON.mask(shape: 1, positionX: 300, positionY: 200, rotation: 0.5)]
        case 5: [EffectJSON.mask(shape: 0), EffectJSON.dropShadow(angle: 0, offset: 40, blur: 0)]
        case 6: [EffectJSON.mask(shape: 0, blend: 0.1)]
        case 7: [EffectJSON.mask(shape: 0, blend: -0.1)]
        case 8: [EffectJSON.mask(shape: 0, opacity: 0.5)]
        default: [EffectJSON.mask(shape: 0, invert: 1)]
        }
    }

    // MARK: EF4 ColorAdjustment

    static let ef4: SheetCase = {
        let g = Grid(cols: 3, rows: 3)
        let rows: [((Double, Double, Double)?, String)] = [
            (nil, "reference (no effect)"),
            ((0.5, 0, 0), "brightness curve"), ((-0.5, 0, 0), "brightness sign"),
            ((0, 0.5, 0), "contrast curve"), ((0, -0.5, 0), "contrast sign"),
            ((0, 4.0, 0), "high contrast (the vlog value)"),
            ((0, 0, -1), "saturation lower end"), ((0, 0, 1), "saturation upper end"),
            ((0.64, 3.98, 0), "replays the vlog values"),
        ]
        let cells = rows.enumerated().map { i, r in
            SheetCell(id: i + 1, rect: g.rect(i),
                      settings: "M-card scale 0.33; " + (r.0.map { "brightness \($0.0), contrast \($0.1), saturation \($0.2)" } ?? "no effect"),
                      answers: r.1)
        }
        return SheetCase(
            name: "ef4-coloradjust", group: "effects",
            summary: "EF4 ColorAdjustment sheet: 3×3 test cards; brightness, contrast and saturation curves and signs; cell 1 is the untouched reference.",
            status: "ready", uses: [.card], requires: ["ColorAdjustment"], durationFrames: sheetFrames,
            playheadFrame: sheetPlayhead, movieFrames: nil, cells: cells,
            checklist: "Nine test cards; the top-left one is unchanged, the others are brighter/darker, more/less contrasty, grey or oversaturated.",
            build: { b, m in
                rows.enumerated().map { i, r in
                    PlacedClip(b.image(m[.card]!, start: 0, duration: f(Int64(sheetFrames)), params: at(g.centre(i), scale: 0.33)),
                               r.0.map { [EffectJSON.colorAdjustment(brightness: $0.0, contrast: $0.1, saturation: $0.2)] } ?? [])
                }
            })
    }()

    // MARK: EF5 BlendModeEffect

    static let ef5: SheetCase = {
        let g = Grid(cols: 6, rows: 4)
        let cells = (0..<24).map { i in
            SheetCell(id: i + 1, rect: g.rect(i), settings: "M-swatch scale 1 over M-grad; BlendModeEffect mode \(i), intensity 1",
                      answers: "blend curve of mode \(i) against the ramp")
        }
        return SheetCase(
            name: "ef5-blendmode", group: "effects",
            summary: "EF5 BlendModeEffect sheet: full-canvas black→white ramp under 24 swatches (6×4 grid) with mode 0…23, intensity 1.",
            status: "ready", uses: [.grad, .swatch], requires: ["BlendModeEffect"], durationFrames: sheetFrames,
            playheadFrame: sheetPlayhead, movieFrames: nil, cells: cells,
            checklist: "A horizontal black→white ramp with 24 small swatches; each swatch is blended differently. Open one swatch's Properties and note which blend-mode name modes 0, 1, 12 and 23 show.",
            build: { b, m in
                [PlacedClip(b.image(m[.grad]!, start: 0, duration: f(Int64(sheetFrames))))]
                    + (0..<24).map { i in
                        PlacedClip(b.image(m[.swatch]!, start: 0, duration: f(Int64(sheetFrames)), params: at(g.centre(i), scale: 1)),
                                   [EffectJSON.blendMode(mode: i)])
                    }
            })
    }()

    // MARK: EF6 MotionBlur (movie)

    static let ef6: SheetCase = {
        let rowsY: [Double] = [400, 200, 0, -200, -400]
        let intensities: [Double?] = [nil, 0.5, 1, 2]
        var cells = intensities.enumerated().map { i, k in
            SheetCell(id: i + 1, rect: [0, 540 - rowsY[i] - 100, 1920, 200],
                      settings: "M-grey scale 0.25, x −800→+800 linear over frames 0–30; " + (k.map { "MotionBlur intensity \($0)" } ?? "no effect"),
                      answers: k == nil ? "unblurred reference row" : "streak length / 53.33 px = shutter fraction at intensity \(k!)")
        }
        cells.append(SheetCell(id: 5, rect: [0, 540 - rowsY[4] - 100, 1920, 200],
                               settings: "M-grey scale 0.25 at x 0, rotation2 0→2π linear over frames 0–30; MotionBlur intensity 1",
                               answers: "does rotation blur?"))
        return SheetCase(
            name: "ef6-motionblur", group: "effects",
            summary: "EF6 MotionBlur movie: 100-px squares moving 53.33 px/frame (rows A–D, intensity none/0.5/1/2) and one spinning square (E); export ef6 MP4.",
            status: "ready", uses: [.grey], requires: ["MotionBlur"], durationFrames: 60,
            playheadFrame: 15, movieFrames: [0, 5, 10, 15, 20, 25, 29, 30, 45], cells: cells,
            checklist: "Four squares slide left→right in the first second (top row sharp, lower rows increasingly smeared); the bottom square spins once. Everything is still after 1 s.",
            build: { b, m in
                var placed = intensities.enumerated().map { i, k in
                    PlacedClip(b.image(m[.grey]!, start: 0, duration: f(60), params: [
                        "translation0": .animated(initial: -800, [KeyframeSpec(time: 0, endTime: f(30), value: 800, interp: "linr")]),
                        "translation1": c(rowsY[i]), "scale0": c(0.25), "scale1": c(0.25),
                    ]), k.map { [EffectJSON.motionBlur(intensity: $0)] } ?? [])
                }
                placed.append(PlacedClip(b.image(m[.grey]!, start: 0, duration: f(60), params: [
                    "translation1": c(rowsY[4]), "scale0": c(0.25), "scale1": c(0.25),
                    "rotation2": .animated(initial: 0, [KeyframeSpec(time: 0, endTime: f(30), value: 2 * .pi, interp: "linr")]),
                ]), [EffectJSON.motionBlur(intensity: 1)]))
                return placed
            })
    }()

    // MARK: EF7 MediaMatte

    static let ef7: SheetCase = {
        // Columns: matteMode 1, 2, 3, 4, 0, and mode 4 at intensity 0.5. Row 1 mattes with M-disc
        // (alpha), row 2 with M-grad (luminance). Row 3, column 1: the reach test.
        let cols: [(Int, Double)] = [(1, 1), (2, 1), (3, 1), (4, 1), (0, 1), (4, 0.5)]
        let rowY: [Double] = [360, 0, -360]
        @Sendable func colX(_ i: Int) -> Double { -960 + 320 * (Double(i) + 0.5) }
        func rect(_ col: Int, _ row: Int) -> [Double] { [320 * Double(col), 360 * Double(row), 320, 360] }
        var cells: [SheetCell] = []
        for (row, matte) in [SheetMediaID.disc, .grad].enumerated() {
            for (i, cfg) in cols.enumerated() {
                cells.append(SheetCell(id: row * 6 + i + 1, rect: rect(i, row),
                                       settings: "M-card (scale 1/6) under \(matte.specName) with MediaMatte matteMode \(cfg.0), intensity \(cfg.1)",
                                       answers: "what matteMode \(cfg.0) does with an \(matte == .disc ? "alpha" : "luminance") matte" + (cfg.1 < 1 ? "; intensity 0.5" : "")))
            }
        }
        cells.append(SheetCell(id: 13, rect: rect(0, 2),
                               settings: "M-grey (scale 0.6, two tracks below the matte) + M-card (scale 1/6) + M-disc with MediaMatte matteMode 4",
                               answers: "does the matte reach past the track directly below? (grey bands above/below the card)"))
        return SheetCase(
            name: "ef7-mediamatte", group: "effects",
            summary: "EF7 MediaMatte sheet: test cards under disc (row 1) and ramp (row 2) mattes, matteMode 1, 2, 3, 4, 0 and intensity 0.5; row 3 tests the matte's reach.",
            status: "ready", uses: [.card, .disc, .grad, .grey], requires: ["MediaMatte"], durationFrames: sheetFrames,
            playheadFrame: sheetPlayhead, movieFrames: nil, cells: cells,
            checklist: "Twelve small test cards cut by a circle or faded by a ramp in different ways, plus one card over a grey square at bottom left. Note the matte-mode name Properties shows for modes 0–4.",
            build: { b, m in
                var placed: [PlacedClip] = []
                let sixth = 1.0 / 6
                for (row, matte) in [SheetMediaID.disc, .grad].enumerated() {
                    for (i, cfg) in cols.enumerated() {
                        let p = (x: colX(i), y: rowY[row])
                        placed.append(PlacedClip(b.image(m[.card]!, start: 0, duration: f(Int64(sheetFrames)), params: at(p, scale: sixth))))
                        placed.append(PlacedClip(b.image(m[matte]!, start: 0, duration: f(Int64(sheetFrames)),
                                                         params: at(p, scale: matte == .disc ? 0.45 : sixth)),
                                                 [EffectJSON.mediaMatte(mode: cfg.0, intensity: cfg.1)]))
                    }
                }
                let p = (x: colX(0), y: rowY[2])
                placed.append(PlacedClip(b.image(m[.grey]!, start: 0, duration: f(Int64(sheetFrames)), params: at(p, scale: 0.6))))
                placed.append(PlacedClip(b.image(m[.card]!, start: 0, duration: f(Int64(sheetFrames)), params: at(p, scale: sixth))))
                placed.append(PlacedClip(b.image(m[.disc]!, start: 0, duration: f(Int64(sheetFrames)), params: at(p, scale: 0.45)),
                                         [EffectJSON.mediaMatte(mode: 4)]))
                return placed
            })
    }()

    // MARK: EF8 / EF9 placeholders (need EF0's parameter names)

    static let ef8: SheetCase = {
        let g = Grid(cols: 4, rows: 3)
        let rows = [("M-grey scale 0.5, thickness 20", "basic border"), ("M-grey scale 0.25, thickness 20", "units"),
                    ("M-disc scale 0.5, thickness 20", "silhouette or box"),
                    ("M-grey scale 0.5 + RoundCorners radius 80, thickness 20", "follows the rounding?"),
                    ("M-grey scale 0.5, colour (0, 0, 1), alpha 0.5", "colour and alpha")]
        return SheetCase(
            name: "ef8-border", group: "effects",
            summary: "EF8 Border sheet — placeholder: generated after EF0 gives Border's parameter names.",
            status: "after-EF0", uses: [], requires: ["Border"], durationFrames: sheetFrames, playheadFrame: sheetPlayhead,
            movieFrames: nil,
            cells: rows.enumerated().map { SheetCell(id: $0 + 1, rect: g.rect($0), settings: $1.0, answers: $1.1) },
            checklist: "Not generated yet (after EF0).", build: nil)
    }()

    static let ef9: SheetCase = {
        let rows = [("M-card scale 0.33, upper half, defaults", "default look"),
                    ("same, opacity at its maximum", "opacity range"), ("same, distance/gap non-zero", "gap"),
                    ("same, rotation2 0.3", "does the reflection rotate with the layer?")]
        return SheetCase(
            name: "ef9-reflection", group: "effects",
            summary: "EF9 Reflection sheet — placeholder: generated after EF0 gives Reflection's parameter names.",
            status: "after-EF0", uses: [], requires: ["Reflection"], durationFrames: sheetFrames, playheadFrame: sheetPlayhead,
            movieFrames: nil,
            cells: rows.enumerated().map { SheetCell(id: $0 + 1, rect: [480 * Double($0), 0, 480, 1080], settings: $1.0, answers: $1.1) },
            checklist: "Not generated yet (after EF0).", build: nil)
    }()

    // MARK: CO1 / CO2 callouts

    /// The `remix` shape ids of callouts.md §3, in table order.
    public static let calloutShapes = [
        "shape-rectangle", "shape-ellipse", "shape-star", "shape-octagon", "shape-triangle", "text", "text-rectangle",
        "speech-bubble", "speech-bubble2", "thought-bubble", "thought-bubble2", "text-arrow", "text-arrow2", "arrow",
    ]

    static let co1: SheetCase = {
        let g = Grid(cols: 4, rows: 5)
        let specs: [(String, String)] = calloutShapes.map { ($0, "basic") }
            + ["urban", "abstract", "bold"].map { ("shape-rectangle", $0) }
            + ["urban", "abstract", "bold"].map { ("speech-bubble", $0) }
        @Sendable func tail(_ shape: String) -> (Double, Double)? {
            if shape.contains("bubble") { return (-60, -100) }
            if shape.hasPrefix("text-arrow") { return (0, -20) }  // preset value [obs]
            return nil
        }
        let text = CalloutDef.Text("Ag Wy 123")
        let cells = specs.enumerated().map { i, s in
            SheetCell(id: i + 1, rect: g.rect(i),
                      settings: s.0 == "arrow" ? "arrow, style basic, tail (200, 0), stroke 6 #3366CC, anchor none, tail cap arrow"
                          : "\(s.0), style \(s.1), 240×160, fill #3366CC, stroke 6 black"
                            + (tail(s.0).map { ", tail (\($0.0), \($0.1))" } ?? "")
                            + (s.0.hasPrefix("text") ? ", text \"Ag Wy 123\" Montserrat 48" : ""),
                      answers: s.1 == "basic" ? "geometry of \(s.0)" : "does style \(s.1) change \(s.0)'s geometry?")
        }
        return SheetCase(
            name: "co1-shapes", group: "callouts",
            summary: "CO1 callout shape sheet: every remix shape id (basic style) plus shape-rectangle and speech-bubble in urban/abstract/bold, 4×5 grid.",
            status: "ready", uses: [], requires: ["Callout"], durationFrames: sheetFrames, playheadFrame: sheetPlayhead,
            movieFrames: nil, cells: cells,
            checklist: "Twenty blue callouts in a 4×5 grid: rectangle, ellipse, star, octagon, triangle, text, text box, 4 bubbles, 2 text arrows, an arrow, then 3 restyled rectangles and 3 restyled bubbles. Note any cell that looks empty or that Camtasia changed (text size!).",
            build: { b, _ in
                specs.enumerated().map { i, s in
                    let p = g.centre(i)
                    if s.0 == "arrow" {
                        return PlacedClip(b.callout(CalloutDef.arrow(tail: (200, 0)), start: 0, duration: f(Int64(sheetFrames)),
                                                    params: ["translation0": c(p.x - 100), "translation1": c(p.y)]))
                    }
                    let def = CalloutDef.shape(s.0, style: s.1, tail: tail(s.0), text: s.0.hasPrefix("text") ? text : nil)
                    return PlacedClip(b.callout(def, start: 0, duration: f(Int64(sheetFrames)),
                                                params: ["translation0": c(p.x), "translation1": c(p.y)]))
                }
            })
    }()

    static let co2: SheetCase = {
        let tails: [(Double, Double)] = [(0, -200), (200, 0), (-150, 150)]
        let anchors = ["arrow", "circle", "diamond"]
        let dashes = ["dash", "dot", "dashdot", "dashdotdot"]
        var cells: [SheetCell] = []
        for (i, t) in tails.enumerated() {
            cells.append(SheetCell(id: i + 1, rect: [640 * Double(i), 0, 640, 360],
                                   settings: "speech-bubble 240×160 at (\(-640 + 640 * i), 300), tail (\(t.0), \(t.1))",
                                   answers: "tail coordinate frame and sign"))
        }
        for (i, a) in anchors.enumerated() {
            cells.append(SheetCell(id: 4 + i, rect: [640 * Double(i), 360, 640, 360],
                                   settings: "arrow from (\(-790 + 640 * i), 0), tail (300, 0), anchor \(a), tail cap arrow, stroke 6",
                                   answers: "anchor cap \(a) size vs stroke width; which end is the anchor"))
        }
        for (i, d) in dashes.enumerated() {
            cells.append(SheetCell(id: 7 + i, rect: [480 * Double(i), 720, 480, 360],
                                   settings: "shape-rectangle 240×160, no fill, black stroke 6, stroke-style \(d)",
                                   answers: "dash pattern \(d) lengths"))
        }
        return SheetCase(
            name: "co2-tails", group: "callouts",
            summary: "CO2 callout tails and strokes: 3 speech-bubble tails, 3 arrow anchors, 4 dash styles.",
            status: "ready", uses: [], requires: ["Callout"], durationFrames: sheetFrames, playheadFrame: sheetPlayhead,
            movieFrames: nil, cells: cells,
            checklist: "Top row: three bubbles whose tails point down, right and up-left. Middle: three arrows with different start caps. Bottom: four outlined rectangles, dashed/dotted.",
            build: { b, _ in
                var placed: [PlacedClip] = []
                for (i, t) in tails.enumerated() {
                    placed.append(PlacedClip(b.callout(CalloutDef.shape("speech-bubble", tail: t), start: 0, duration: f(Int64(sheetFrames)),
                                                       params: ["translation0": c(Double(-640 + 640 * i)), "translation1": c(300)])))
                }
                for (i, a) in anchors.enumerated() {
                    placed.append(PlacedClip(b.callout(CalloutDef.arrow(tail: (300, 0), anchor: a), start: 0, duration: f(Int64(sheetFrames)),
                                                       params: ["translation0": c(Double(-790 + 640 * i)), "translation1": c(0)])))
                }
                for (i, d) in dashes.enumerated() {
                    placed.append(PlacedClip(b.callout(CalloutDef.shape("shape-rectangle", fill: (0.2, 0.4, 0.8, 0), strokeStyle: d),
                                                       start: 0, duration: f(Int64(sheetFrames)),
                                                       params: ["translation0": c(-720 + 480 * Double(i)), "translation1": c(-360)])))
                }
                return placed
            })
    }()

    // MARK: Writing

    /// Builds `sheet` into `<outDir>/<group>/<name>/`: the `.cmproj` (media hard-linked or
    /// copied from `media`), `docPrefs` with the playhead parked, and `sheet.json`.
    /// Placeholders get only `sheet.json` and a note. Replaces an existing bundle; never
    /// touches `reference.*`. Effects are added through TimelineEngine's `AddEffect`.
    @MainActor @discardableResult
    public static func write(_ sheet: SheetCase, media: [SheetMediaID: URL], to outDir: URL) throws -> URL {
        let fm = FileManager.default
        let caseDir = outDir.appendingPathComponent("\(sheet.group)/\(sheet.name)", isDirectory: true)
        try fm.createDirectory(at: caseDir, withIntermediateDirectories: true)
        let threshold = TestGen.sheetThreshold(for: "\(sheet.group)/\(sheet.name)")
        var manifest = SheetManifest(
            caseName: sheet.name, group: sheet.group, summary: sheet.summary, status: sheet.status,
            project: sheet.isPlaceholder ? nil : "\(sheet.name).cmproj", requires: sheet.requires,
            referenceImage: "reference.png", referenceMovie: sheet.movieFrames == nil ? nil : "reference.mp4",
            movieFrames: sheet.movieFrames, playheadFrame: sheet.playheadFrame, fps: 30, width: 1920, height: 1080,
            ssimMin: threshold.ssimMin, psnrMin: threshold.psnr?.dB, psnrReference: threshold.psnr?.reference,
            cells: sheet.cells, checklist: sheet.checklist, generator: version)
        guard let build = sheet.build else {
            manifest.project = nil
            try manifest.write(to: caseDir.appendingPathComponent("sheet.json"))
            try Data("Placeholder: \(sheet.summary)\nRegenerate with `wizrec-testgen sheets --case \(sheet.name)` once EF0 (ef0-defaults.cmproj) gives the parameter names.\n".utf8)
                .write(to: caseDir.appendingPathComponent("PLACEHOLDER-after-EF0.txt"), options: .atomic)
            return caseDir
        }
        let bundle = caseDir.appendingPathComponent("\(sheet.name).cmproj", isDirectory: true)
        try? fm.removeItem(at: bundle)
        let stamp = String(format: "%.6f", Date().timeIntervalSince1970)
        let mediaDir = bundle.appendingPathComponent("media/\(stamp)", isDirectory: true)
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        let b = ProjectBuilder(title: sheet.name)
        b.background = [255, 255, 255, 255]
        var sources: [SheetMediaID: ProjectBuilder.Source] = [:]
        for id in sheet.uses {
            guard let srcURL = media[id] else { throw MediaWriterError.setup("no sheet media \(id.rawValue)") }
            let dst = mediaDir.appendingPathComponent(id.rawValue)
            do { try fm.linkItem(at: srcURL, to: dst) } catch { try fm.copyItem(at: srcURL, to: dst) }
            let mod = (try? fm.attributesOfItem(atPath: dst.path)[.modificationDate] as? Date) ?? Date()
            sources[id] = b.addImageSource(src: "./media/\(stamp)/\(id.rawValue)", width: id.size.width,
                                           height: id.size.height, modified: mod)
        }
        let placed = build(b, sources)
        b.tracks = placed.map { [$0.clip] }
        let project = b.build()
        for p in placed {
            guard let id = p.clip["id"]?.int else { continue }
            for e in p.effects { try AddEffect(clipID: id, effectJSON: EffectJSON.string(e)).apply(to: project) }
        }
        try project.serialized().write(to: bundle.appendingPathComponent("project.tscproj"), options: .atomic)
        try DocPrefs.write(playhead: f(Int64(sheet.playheadFrame)), to: bundle)
        try manifest.write(to: caseDir.appendingPathComponent("sheet.json"))
        return caseDir
    }
}
