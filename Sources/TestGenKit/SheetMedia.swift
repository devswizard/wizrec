import CoreGraphics
import Foundation

/// Still media for the effect and callout sheets (`docs/specs/effects/README.md` §3).
/// All of it is drawn here from scratch: original, synthetic, no third-party content.
public enum SheetMediaID: String, Sendable, CaseIterable {
    /// M-grey: 400×400 opaque solid mid-grey `#808080`.
    case grey = "M-grey-400.png"
    /// M-disc: 400×400, an opaque white disc of diameter 300 on a transparent background.
    case disc = "M-disc-400.png"
    /// M-card: 1920×1080 colour-bar / grey-ramp test card (frame 0 of test card A).
    case card = "M-card-1920x1080.png"
    /// M-grad: 1920×1080 horizontal black→white ramp, x = 0 black, x = 1919 white.
    case grad = "M-grad-1920x1080.png"
    /// M-swatch: 200×200 patch: 8 colour bars (rows 0–99), an 8-step grey ramp
    /// (rows 100–149) and a 50 %-alpha red band (rows 150–199). The "200×200 M-card
    /// crop or 50 % red square" of the blend sheet (EF5) in one image.
    case swatch = "M-swatch-200.png"

    /// Native size, px.
    public var size: (width: Int, height: Int) {
        switch self {
        case .grey, .disc: (400, 400)
        case .card, .grad: (1920, 1080)
        case .swatch: (200, 200)
        }
    }

    /// Spec name (`M-grey` …).
    public var specName: String {
        switch self {
        case .grey: "M-grey"
        case .disc: "M-disc"
        case .card: "M-card"
        case .grad: "M-grad"
        case .swatch: "M-swatch"
        }
    }
}

extension TestGen {
    /// The 8 colour bars of `M-swatch`, left to right (sRGB 0–255).
    public static let swatchBars: [(UInt8, UInt8, UInt8)] = [
        (255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
        (255, 0, 255), (255, 0, 0), (0, 0, 255), (0, 0, 0),
    ]

    /// Writes every `SheetMediaID` into `directory`. `scale` shrinks pixel sizes (tests);
    /// the projects always describe the native sizes, so only use `scale` < 1 for structure tests.
    public static func makeSheetMedia(in directory: URL, scale: Double = 1) throws -> [SheetMediaID: URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var out: [SheetMediaID: URL] = [:]
        for id in SheetMediaID.allCases {
            let url = directory.appendingPathComponent(id.rawValue)
            let w = max(8, Int((Double(id.size.width) * scale).rounded()))
            let h = max(8, Int((Double(id.size.height) * scale).rounded()))
            try MediaWriter.writePNG(to: url, width: w, height: h) { ctx in draw(id, width: w, height: h, in: ctx) }
            out[id] = url
        }
        return out
    }

    /// Draws one sheet image (bottom-left origin context, as `MediaWriter.writePNG` provides).
    static func draw(_ id: SheetMediaID, width w: Int, height h: Int, in ctx: CGContext) {
        let W = CGFloat(w), H = CGFloat(h)
        func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: CGFloat = 1) {
            ctx.setFillColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
        }
        switch id {
        case .grey:
            rgb(128, 128, 128)
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        case .disc:
            ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))
            rgb(255, 255, 255)
            let d = W * 0.75
            ctx.fillEllipse(in: CGRect(x: (W - d) / 2, y: (H - d) / 2, width: d, height: d))
        case .card:
            TestCard(width: w, height: h, label: "A").draw(frame: 0, fps: 30, in: ctx)
        case .grad:
            for x in 0..<w {
                let v = w > 1 ? UInt8((255 * Double(x) / Double(w - 1)).rounded()) : 0
                rgb(v, v, v)
                ctx.fill(CGRect(x: CGFloat(x), y: 0, width: 1, height: H))
            }
        case .swatch:
            ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))
            // Top-down rows in a bottom-left context: row band [y0, y1) from the top → y = H − y1.
            func band(_ y0: CGFloat, _ y1: CGFloat) -> (CGFloat, CGFloat) { (H - y1 * H / 200, (y1 - y0) * H / 200) }
            let (barY, barH) = band(0, 100)
            for (i, c) in swatchBars.enumerated() {
                rgb(c.0, c.1, c.2)
                ctx.fill(CGRect(x: CGFloat(i) * W / 8, y: barY, width: W / 8, height: barH))
            }
            let (rampY, rampH) = band(100, 150)
            for i in 0..<8 {
                let v = UInt8((255 * Double(i) / 7).rounded())
                rgb(v, v, v)
                ctx.fill(CGRect(x: CGFloat(i) * W / 8, y: rampY, width: W / 8, height: rampH))
            }
            let (redY, redH) = band(150, 200)
            rgb(255, 0, 0, 0.5)
            ctx.fill(CGRect(x: 0, y: redY, width: W, height: redH))
        }
    }
}
