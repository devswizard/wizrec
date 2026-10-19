import CoreGraphics
import CoreText
import Foundation

/// Original synthetic test-card artwork for generated test media.
///
/// Every frame shows colour bars, a grid, four coloured corner markers
/// (red top-left, green top-right, blue bottom-left, yellow bottom-right), a
/// large label with the frame number, a moving bar, and a machine-readable
/// binary barcode of the frame number along the bottom edge. The barcode lets
/// tests and humans tell exactly which source frame ended up on screen.
public struct TestCard: Sendable {
    /// Frame size, px.
    public var width: Int
    public var height: Int
    /// Short clip label drawn in the centre, e.g. `"A"`.
    public var label: String
    /// Bar palette; clips use different palettes so they are easy to tell apart.
    public var palette: Palette

    public enum Palette: Sendable {
        /// Classic 75 % bars: white, yellow, cyan, green, magenta, red, blue, black.
        case classic
        /// Same colours, reversed and on a warmer background.
        case reversed
    }

    public init(width: Int, height: Int, label: String, palette: Palette = .classic) {
        self.width = width; self.height = height; self.label = label; self.palette = palette
    }

    /// Bits in the frame-number barcode (MSB first).
    public static let barcodeBits = 16

    /// Draws frame `n` (0-based) of a clip running at `fps` into `ctx`, which must be `width`×`height`.
    public func draw(frame n: Int, fps: Int, in ctx: CGContext) {
        let w = CGFloat(width), h = CGFloat(height)
        // Helper: rectangles given in top-left-origin coordinates.
        func r(_ x: CGFloat, _ yTop: CGFloat, _ rw: CGFloat, _ rh: CGFloat) -> CGRect {
            CGRect(x: x, y: h - yTop - rh, width: rw, height: rh)
        }
        func fill(_ rect: CGRect, _ c: (CGFloat, CGFloat, CGFloat)) {
            ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            ctx.fill(rect)
        }

        // Background.
        fill(r(0, 0, w, h), palette == .classic ? (0.12, 0.12, 0.14) : (0.20, 0.13, 0.10))

        // Colour bars, top 55 %.
        var bars: [(CGFloat, CGFloat, CGFloat)] = [
            (0.75, 0.75, 0.75), (0.75, 0.75, 0), (0, 0.75, 0.75), (0, 0.75, 0),
            (0.75, 0, 0.75), (0.75, 0, 0), (0, 0, 0.75), (0.05, 0.05, 0.05),
        ]
        if palette == .reversed { bars.reverse() }
        let barH = (h * 0.55).rounded()
        let barW = w / CGFloat(bars.count)
        for (i, c) in bars.enumerated() {
            fill(r((CGFloat(i) * barW).rounded(), 0, barW.rounded() + 1, barH), c)
        }

        // Grey ramp under the bars: 16 steps black → white.
        let rampH = (h * 0.08).rounded()
        for i in 0..<16 {
            let v = CGFloat(i) / 15
            fill(r((CGFloat(i) * w / 16).rounded(), barH, (w / 16).rounded() + 1, rampH), (v, v, v))
        }

        // Grid every 1/16 of the width, 2 px lines.
        ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        let step = w / 16
        let line = max(1, (w / 960).rounded())
        var x: CGFloat = step
        while x < w { ctx.fill(r(x.rounded(), 0, line, h)); x += step }
        var y: CGFloat = step
        while y < h { ctx.fill(r(0, y.rounded(), w, line)); y += step }

        // Moving bar: crosses the frame once every 4 seconds.
        let period = max(1, fps * 4)
        let mx = (CGFloat(n % period) / CGFloat(period) * w).rounded()
        fill(r(mx, 0, max(4, (w / 240).rounded()), barH), (1, 1, 1))

        // Corner markers with a white rim.
        let m = (h / 10).rounded()
        let rim = max(1, (m / 16).rounded())
        let corners: [(CGFloat, CGFloat, (CGFloat, CGFloat, CGFloat))] = [
            (0, 0, (0.9, 0.1, 0.1)), (w - m, 0, (0.1, 0.8, 0.1)),
            (0, h - m, (0.1, 0.2, 0.9)), (w - m, h - m, (0.95, 0.85, 0.1)),
        ]
        for (cx, cy, c) in corners {
            fill(r(cx, cy, m, m), (1, 1, 1))
            fill(r(cx + rim, cy + rim, m - 2 * rim, m - 2 * rim), c)
        }

        // Centre panel with label and frame number.
        let panelW = (w * 0.5).rounded(), panelH = (h * 0.22).rounded()
        let panel = r(((w - panelW) / 2).rounded(), ((h - panelH) / 2).rounded(), panelW, panelH)
        fill(panel, (0.02, 0.02, 0.02))
        let seconds = Double(n) / Double(max(fps, 1))
        let text = "\(label)  \(String(format: "%04d", n))  \(String(format: "%06.3f", seconds))s"
        drawText(text, centredIn: panel, fontSize: panelH * 0.45, in: ctx)

        // Barcode along the bottom between the corner markers:
        // [white guard][black guard][16 data bits][black guard][white guard].
        let cells = TestCard.barcodeBits + 4
        let cellW = ((w - 2 * m) / CGFloat(cells)).rounded(.down)
        let codeH = (h * 0.07).rounded()
        let codeTop = h - codeH
        let codeX0 = ((w - cellW * CGFloat(cells)) / 2).rounded()
        for i in 0..<cells {
            let on: Bool
            switch i {
            case 0, cells - 1: on = true
            case 1, cells - 2: on = false
            default: on = (n >> (TestCard.barcodeBits - 1 - (i - 2))) & 1 == 1
            }
            fill(r(codeX0 + CGFloat(i) * cellW, codeTop, cellW, codeH), on ? (1, 1, 1) : (0, 0, 0))
        }
    }

    /// Reads the frame number back from an untransformed, full-frame image of this card.
    /// Returns `nil` when the guard cells don't match (frame is transformed, cropped or covered).
    public func decodeFrameNumber(_ image: RGBAImage) -> Int? {
        let iw = image.width, ih = image.height
        guard iw > 0, ih > 0 else { return nil }
        let rgba = image.pixels
        let sx = Double(iw) / Double(width), sy = Double(ih) / Double(height)
        let w = Double(width), h = Double(height)
        let m = (h / 10).rounded()
        let cells = TestCard.barcodeBits + 4
        let cellW = ((w - 2 * m) / Double(cells)).rounded(.down)
        let codeH = (h * 0.07).rounded()
        let codeX0 = ((w - cellW * Double(cells)) / 2).rounded()
        let cy = h - codeH / 2
        func bright(_ i: Int) -> Bool {
            let px = min(iw - 1, Int((codeX0 + (Double(i) + 0.5) * cellW) * sx))
            let py = min(ih - 1, Int(cy * sy))
            let o = (py * iw + px) * 4
            let y = 0.2126 * Double(rgba[o]) + 0.7152 * Double(rgba[o + 1]) + 0.0722 * Double(rgba[o + 2])
            return y > 128
        }
        guard bright(0), !bright(1), !bright(cells - 2), bright(cells - 1) else { return nil }
        var v = 0
        for b in 0..<TestCard.barcodeBits { v = (v << 1) | (bright(b + 2) ? 1 : 0) }
        return v
    }

    private func drawText(_ s: String, centredIn rect: CGRect, fontSize: CGFloat, in ctx: CGContext) {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: white] as CFDictionary
        guard let str = CFAttributedStringCreate(nil, s as CFString, attrs) else { return }
        let lineRef = CTLineCreateWithAttributedString(str)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        var tw = CGFloat(CTLineGetTypographicBounds(lineRef, &ascent, &descent, &leading))
        var scale: CGFloat = 1
        if tw > rect.width * 0.95 { scale = rect.width * 0.95 / tw; tw *= scale }
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: rect.midX - tw / 2, y: rect.midY - (ascent - descent) * scale / 2)
        ctx.scaleBy(x: scale, y: scale)
        ctx.textPosition = .zero
        CTLineDraw(lineRef, ctx)
        ctx.restoreGState()
    }
}

/// Still images for image-clip cases.
public enum TestImages {
    /// A solid magenta square with a white cross and black rim: easy to locate (centroid) in renders.
    public static func marker(size: Int, in ctx: CGContext) {
        let s = CGFloat(size)
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        let rim = max(2, (s / 25).rounded())
        ctx.setFillColor(red: 0.95, green: 0.1, blue: 0.85, alpha: 1)
        ctx.fill(CGRect(x: rim, y: rim, width: s - 2 * rim, height: s - 2 * rim))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        let t = max(2, (s / 20).rounded())
        ctx.fill(CGRect(x: ((s - t) / 2).rounded(), y: rim, width: t, height: s - 2 * rim))
        ctx.fill(CGRect(x: rim, y: ((s - t) / 2).rounded(), width: s - 2 * rim, height: t))
    }

    /// A still test card (`TestCard` with label `IMG`) overlaid with a checkerboard band,
    /// so source-crop edges are visible on every side.
    public static func card(width: Int, height: Int, in ctx: CGContext) {
        TestCard(width: width, height: height, label: "IMG", palette: .reversed).draw(frame: 0, fps: 30, in: ctx)
        let sq = CGFloat(height) / 18
        let top = CGFloat(height) * 0.30
        var i = 0
        var x: CGFloat = 0
        while x < CGFloat(width) {
            for row in 0..<2 {
                let on = (i + row) % 2 == 0
                ctx.setFillColor(red: on ? 1 : 0, green: on ? 1 : 0, blue: on ? 1 : 0, alpha: 1)
                ctx.fill(CGRect(x: x, y: top + CGFloat(row) * sq, width: sq, height: sq))
            }
            x += sq; i += 1
        }
    }
}
