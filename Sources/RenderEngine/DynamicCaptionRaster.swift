import CaptionLayout
import CoreGraphics
import CoreText
import Foundation

/// WizRec's drawing of a dynamic caption (`CalloutContent.dynamicCaption`) from the
/// `dynamic-caption-*` style keys (`docs/specs/captions.md` §3–§4). Written from the key names and
/// sample values only; the exact look waits on experiment CA2, and every proportion sits in `Spec`.
/// Coordinates: callout px, origin at the box centre, +y up.
///
/// - Size: the base `font.size`, shrunk until the block fits the box (`resize-behavior` [?]).
/// - Words: past at `past-word-opacity`, future at `future-word-opacity`; the current word in
///   `current-word-color` with an outline widened by `current-word-stroke-extra-width` in
///   `current-word-stroke-color`, scaled by `1 + current-word-extra-scale`, with a glow of
///   `current-word-glow-radius`. Over `word-easing-duration` the previous word eases out as the
///   current one eases in.
/// - Boxes: `word-rectangle-*` behind the current word (padded by `extra-size` × font size, sliding
///   from the previous word over `transition-time`), `background-fill-color` behind the block.
/// - Block transition: any non-empty `block-transition-name` fades the block in [WizRec rule].
extension RGBA {
    init(_ c: CaptionColor) { self.init(c.r, c.g, c.b, c.a) }
}

enum DynamicCaptionText {
    enum Spec {
        /// Block background padding around the words, × font size.
        static let backgroundPadding = 0.25
        /// Shrink-to-fit passes.
        static let fitPasses = 8
    }

    /// Room past the box the caption may draw into (outline, glow, scale, boxes), callout px.
    static func overhang(_ s: DynamicCaptionStyle, fontSize: Double) -> Double {
        s.currentWordStrokeExtraWidth + 2 * s.currentWordGlowRadius
            + (max(s.wordRectangleExtraSize, Spec.backgroundPadding) + s.currentWordExtraScale) * fontSize
    }

    static func mix(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
        RGBA(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
    }
    static func mix(_ a: RGBA, _ b: CaptionColor, _ t: Double) -> RGBA { mix(a, RGBA(b), t) }

    private static func cg(_ c: RGBA) -> CGColor { CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }
    private static func cg(_ c: CaptionColor) -> CGColor { cg(RGBA(c)) }
    private static let fgKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
    private static let strokeKey = NSAttributedString.Key(kCTStrokeWidthAttributeName as String)

    /// `c` at font size `size` (run sizes dropped).
    static func sized(_ c: CalloutContent, _ size: Double) -> CalloutContent {
        var x = c
        x.fontSize = size
        x.runs = c.runs.map { var r = $0; r.fontSize = nil; return r }
        return x
    }

    /// The content at its fitted size and the frame rect its text is laid out in.
    static func fit(_ c: CalloutContent, box: CGRect) -> (content: CalloutContent, rect: CGRect) {
        var size = max(c.fontSize, 1)
        var cc = sized(c, size)
        var fitSize = CGSize.zero
        for _ in 0..<Spec.fitPasses {
            cc = sized(c, size)
            let setter = CTFramesetterCreateWithAttributedString(CalloutText.attributed(cc, fill: true, strokeWidth: 0))
            fitSize = CTFramesetterSuggestFrameSizeWithConstraints(
                setter, CFRange(location: 0, length: 0), nil, CGSize(width: box.width, height: .greatestFiniteMagnitude), nil)
            guard fitSize.height > box.height, size > 2 else { break }
            size = max(1, size * min(0.95, box.height / fitSize.height))
        }
        let fh = fitSize.height.rounded(.up) + 1
        let y: Double = switch c.verticalAlignment {
        case "top": box.maxY - fh
        case "bottom": box.minY
        default: box.midY - fh / 2
        }
        return (cc, CGRect(x: box.minX, y: y, width: box.width, height: fh))
    }

    /// Box and baseline of UTF-16 `range` in `frame` (laid out in `rect`), callout px.
    static func wordBox(_ range: Range<Int>, frame: CTFrame, rect: CGRect) -> (box: CGRect, baseline: Double)? {
        let lines = (CTFrameGetLines(frame) as? [CTLine]) ?? []
        guard !lines.isEmpty else { return nil }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (i, line) in lines.enumerated() {
            let r = CTLineGetStringRange(line)
            guard range.lowerBound >= r.location, range.lowerBound < r.location + r.length else { continue }
            let x0 = CTLineGetOffsetForStringIndex(line, range.lowerBound, nil)
            let x1 = CTLineGetOffsetForStringIndex(line, min(range.upperBound, r.location + r.length), nil)
            var asc: CGFloat = 0, desc: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &asc, &desc, nil)
            let base = rect.minY + origins[i].y
            return (CGRect(x: rect.minX + origins[i].x + x0, y: base - desc, width: x1 - x0, height: asc + desc), base)
        }
        return nil
    }

    static func draw(_ c: CalloutContent, in ctx: CGContext) {
        guard let dc = c.dynamicCaption, let f = dc.frame, !f.text.isEmpty, !f.words.isEmpty else { return }
        let s = dc.style
        let box = CalloutGeometry.box(c)
        guard box.width > 0, box.height > 0 else { return }
        let (cc, rect) = fit(c, box: box)
        let size = cc.fontSize
        let path = CGPath(rect: rect, transform: nil)
        let fill = NSMutableAttributedString(attributedString: CalloutText.attributed(cc, fill: true, strokeWidth: 0))
        let layoutFrame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(fill),
                                                   CFRange(location: 0, length: 0), path, nil)
        let boxes = f.words.map { wordBox($0.range, frame: layoutFrame, rect: rect) }

        // Per-word state: colour, outline (extra width and colour), scale.
        let base = cc.runs.first?.color ?? cc.textColor
        let lit = s.currentWordEnabled
        func stateColor(_ st: DynamicCaptionFrame.WordState) -> RGBA {
            var col = base
            col.a *= st == .past ? s.pastWordOpacity : st == .future ? s.futureWordOpacity : 1
            return col
        }
        /// 0–1 highlight amount of word `i`.
        func amount(_ i: Int) -> Double {
            guard lit else { return 0 }
            if i == f.currentWord { return f.highlightProgress }
            if i == f.previousWord { return 1 - f.highlightProgress }
            return 0
        }
        func color(_ i: Int) -> RGBA {
            let a = amount(i)
            let rest = stateColor(i == f.currentWord ? .future : f.words[i].state)
            return a > 0 ? mix(rest, s.currentWordColor, a) : stateColor(f.words[i].state)
        }
        func scale(_ i: Int) -> Double { 1 + s.currentWordExtraScale * amount(i) }
        func opacity(_ i: Int) -> Double { base.a > 0 ? color(i).a / base.a : 0 }
        let hasOutline = c.textStrokeWidth > 0 && c.textStrokeColor.a > 0
        func outline(_ i: Int) -> (width: Double, color: RGBA)? {
            let a = amount(i), extra = s.currentWordStrokeExtraWidth * a
            let w = (hasOutline ? c.textStrokeWidth : 0) + extra
            guard w > 0 else { return nil }
            var col = hasOutline ? (a > 0 ? mix(c.textStrokeColor, s.currentWordStrokeColor, a) : c.textStrokeColor)
                                 : RGBA(s.currentWordStrokeColor)
            col.a *= min(1, max(opacity(i), a))
            return (w, col)
        }
        let scaled = Set(f.words.indices.filter { scale($0) != 1 && boxes[$0] != nil })
        let clear = RGBA(0, 0, 0, 0)

        // Outline pass: Core Text strokes at 2× so the fill on top leaves an outside outline.
        let stroke = NSMutableAttributedString(attributedString: CalloutText.attributed(cc, fill: false, strokeWidth: 0))
        stroke.addAttribute(fgKey, value: cg(clear), range: NSRange(location: 0, length: stroke.length))
        var anyOutline = false
        for i in f.words.indices where !scaled.contains(i) {
            let r = NSRange(location: f.words[i].range.lowerBound, length: f.words[i].range.count)
            fill.addAttribute(fgKey, value: cg(color(i)), range: r)
            if let o = outline(i) {
                anyOutline = true
                stroke.addAttribute(fgKey, value: cg(o.color), range: r)
                stroke.addAttribute(strokeKey, value: 2 * o.width / size * 100, range: r)
            }
        }
        for i in scaled {
            fill.addAttribute(fgKey, value: cg(clear),
                              range: NSRange(location: f.words[i].range.lowerBound, length: f.words[i].range.count))
        }

        ctx.saveGState()
        if f.blockProgress < 1 { ctx.setAlpha(max(0, f.blockProgress)) }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        // Block background.
        if s.backgroundFillColor.a > 0, let all = boxes.compactMap({ $0?.box }).reduce(nil, { (u: CGRect?, b) in u?.union(b) ?? b }) {
            let r = all.insetBy(dx: -Spec.backgroundPadding * size, dy: -Spec.backgroundPadding * size)
            let rad = min(s.backgroundCornerRadius, r.height / 2, r.width / 2)
            ctx.setFillColor(cg(s.backgroundFillColor))
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)); ctx.fillPath()
        }

        // Word box: slides from the previous word to the current one.
        if lit, s.wordRectangleColor.a > 0, let ci = f.currentWord, let cur = boxes[ci]?.box {
            func scaledBox(_ i: Int, _ b: CGRect) -> CGRect {
                let k = scale(i)
                return CGRect(x: b.midX - b.width * k / 2, y: b.midY - b.height * k / 2, width: b.width * k, height: b.height * k)
            }
            var r = scaledBox(ci, cur)
            if let pi = f.previousWord, f.rectangleProgress < 1, let prev = boxes[pi]?.box {
                let p = scaledBox(pi, prev), t = f.rectangleProgress
                r = CGRect(x: p.minX + (r.minX - p.minX) * t, y: p.minY + (r.minY - p.minY) * t,
                           width: p.width + (r.width - p.width) * t, height: p.height + (r.height - p.height) * t)
            }
            r = r.insetBy(dx: -s.wordRectangleExtraSize * size, dy: -s.wordRectangleExtraSize * size)
            let rad = min(s.wordRectangleCornerRadius, r.height / 2, r.width / 2)
            ctx.setFillColor(cg(s.wordRectangleColor))
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)); ctx.fillPath()
        }

        // Glow of the current word (unscaled words only; scaled ones glow in their own pass).
        if lit, s.currentWordGlowRadius > 0, let ci = f.currentWord, !scaled.contains(ci) {
            let glow = NSMutableAttributedString(attributedString: fill)
            glow.addAttribute(fgKey, value: cg(clear), range: NSRange(location: 0, length: glow.length))
            glow.addAttribute(fgKey, value: cg(color(ci)),
                              range: NSRange(location: f.words[ci].range.lowerBound, length: f.words[ci].range.count))
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: s.currentWordGlowRadius, color: cg(s.currentWordColor))
            CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(glow), CFRange(location: 0, length: 0), path, nil), ctx)
            ctx.restoreGState()
        }

        ctx.setLineJoin(.round)
        if anyOutline {
            CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(stroke), CFRange(location: 0, length: 0), path, nil), ctx)
        }
        CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(fill), CFRange(location: 0, length: 0), path, nil), ctx)

        // Scaled words, each about its own centre.
        for i in scaled.sorted() {
            guard let b = boxes[i] else { continue }
            let r = NSRange(location: f.words[i].range.lowerBound, length: f.words[i].range.count)
            let word = NSMutableAttributedString(attributedString: CalloutText.attributed(cc, fill: true, strokeWidth: 0)
                .attributedSubstring(from: r))
            let all = NSRange(location: 0, length: word.length)
            word.removeAttribute(NSAttributedString.Key(kCTParagraphStyleAttributeName as String), range: all)
            ctx.saveGState()
            let k = scale(i)
            ctx.translateBy(x: b.box.midX, y: b.box.midY)
            ctx.scaleBy(x: k, y: k)
            ctx.translateBy(x: -b.box.midX, y: -b.box.midY)
            func line(_ col: RGBA, stroke w: Double?) {
                let a = NSMutableAttributedString(attributedString: word)
                a.addAttribute(fgKey, value: cg(col), range: all)
                if let w { a.addAttribute(strokeKey, value: 2 * w / size * 100, range: all) }
                ctx.textPosition = CGPoint(x: b.box.minX, y: b.baseline)
                CTLineDraw(CTLineCreateWithAttributedString(a), ctx)
            }
            if lit, s.currentWordGlowRadius > 0, i == f.currentWord {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: s.currentWordGlowRadius * k, color: cg(s.currentWordColor))
                line(color(i), stroke: nil)
                ctx.restoreGState()
            }
            if let o = outline(i) { line(o.color, stroke: o.width) }
            line(color(i), stroke: nil)
            ctx.restoreGState()
        }

        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}
