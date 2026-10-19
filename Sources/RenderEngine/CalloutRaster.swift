import CoreGraphics
import CoreText
import Foundation
import Metal

/// WizRec's own vector geometry for callout shapes (`docs/specs/callouts.md` §3–§4). Every outline
/// here is drawn from simple geometric rules; none is taken from TechSmith artwork. Exact looks wait
/// on experiments CO1/CO2; every proportion sits in `Spec`.
/// Coordinates: callout px, origin at the box centre, +y up (CoreGraphics' native orientation).
enum CalloutGeometry {
    enum Spec {
        /// Body corner radius of `speech-bubble` / `text-arrow2`, × the shorter side.
        static let bubbleCornerFraction = 0.18
        /// Width of a tail's base, × the shorter side.
        static let tailBaseFraction = 0.3
        /// Star: points and inner/outer radius ratio [?: 5 assumed, callouts.md §3].
        static let starPoints = 5
        static let starInnerRatio = 0.4
        /// Octagon corner cut, × the side (regular octagon: 1 − 1/√2 ≈ 0.293).
        static let octagonCut = 1 - 1 / 2.0.squareRoot()
        /// Thought-bubble trail: number of circles toward the tail tip.
        static let thoughtTrail = 3
        /// Dash patterns in multiples of the stroke width [?: CO2].
        static let dashes: [String: [Double]] = [
            "dash": [3, 2], "dot": [1, 1.5], "dashdot": [3, 1.5, 1, 1.5], "dashdotdot": [3, 1.5, 1, 1.5, 1, 1.5],
        ]
        /// Arrow head length and half-width, × stroke width (minimum 6 px).
        static let arrowHeadLength = 3.5
        static let arrowHeadHalfWidth = 2.0
    }

    static func box(_ c: CalloutContent) -> CGRect {
        CGRect(x: -c.size.width / 2, y: -c.size.height / 2, width: c.size.width, height: c.size.height)
    }

    /// The filled/stroked outline, or nil for text-only callouts and arrows (stroked separately).
    static func body(_ c: CalloutContent) -> CGPath? {
        let b = box(c)
        guard b.width > 0, b.height > 0 else { return nil }
        let short = min(b.width, b.height)
        switch c.shape {
        case "text", "arrow", "": return nil
        case "shape-ellipse": return CGPath(ellipseIn: b, transform: nil)
        case "shape-star": return star(b)
        case "shape-octagon": return octagon(b)
        case "shape-triangle":
            let p = CGMutablePath()
            p.move(to: CGPoint(x: b.midX, y: b.maxY))
            p.addLine(to: CGPoint(x: b.maxX, y: b.minY)); p.addLine(to: CGPoint(x: b.minX, y: b.minY))
            p.closeSubpath()
            return p
        case "speech-bubble":
            return withTail(rounded(b, short * Spec.bubbleCornerFraction), b, c.tail, base: short * Spec.tailBaseFraction)
        case "speech-bubble2":
            return withTail(CGPath(ellipseIn: b, transform: nil), b, c.tail, base: short * Spec.tailBaseFraction)
        case "thought-bubble": return thought(cloud(b), b, c.tail)
        case "thought-bubble2": return thought(CGPath(ellipseIn: b, transform: nil), b, c.tail)
        case "text-arrow":
            return withTail(CGPath(rect: b, transform: nil), b, c.tail, base: short * 0.6)
        case "text-arrow2":
            return withTail(rounded(b, short * Spec.bubbleCornerFraction), b, c.tail, base: short * 0.6)
        default:
            // shape-rectangle, text-rectangle and unknown ids: a (rounded) box.
            return rounded(b, c.cornerRadius)
        }
    }

    static func rounded(_ b: CGRect, _ r: Double) -> CGPath {
        let r = min(max(r, 0), min(b.width, b.height) / 2)
        return r > 0 ? CGPath(roundedRect: b, cornerWidth: r, cornerHeight: r, transform: nil) : CGPath(rect: b, transform: nil)
    }

    static func star(_ b: CGRect) -> CGPath {
        let p = CGMutablePath()
        let n = Spec.starPoints
        for i in 0..<(2 * n) {
            let a = Double.pi / 2 + Double(i) * Double.pi / Double(n)
            let k = i % 2 == 0 ? 1 : Spec.starInnerRatio
            let pt = CGPoint(x: b.midX + cos(a) * b.width / 2 * k, y: b.midY + sin(a) * b.height / 2 * k)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }

    static func octagon(_ b: CGRect) -> CGPath {
        let cx = b.width * Spec.octagonCut, cy = b.height * Spec.octagonCut
        let pts = [CGPoint(x: b.minX + cx, y: b.minY), CGPoint(x: b.maxX - cx, y: b.minY),
                   CGPoint(x: b.maxX, y: b.minY + cy), CGPoint(x: b.maxX, y: b.maxY - cy),
                   CGPoint(x: b.maxX - cx, y: b.maxY), CGPoint(x: b.minX + cx, y: b.maxY),
                   CGPoint(x: b.minX, y: b.maxY - cy), CGPoint(x: b.minX, y: b.minY + cy)]
        let p = CGMutablePath()
        p.addLines(between: pts)
        p.closeSubpath()
        return p
    }

    /// A body joined with a triangular tail from the box centre region to `tip`, so the outline is
    /// continuous [callouts.md §6]. No tail when the tip lies inside the box.
    static func withTail(_ body: CGPath, _ b: CGRect, _ tip: CGPoint, base: Double) -> CGPath {
        guard !b.contains(tip) else { return body }
        let dir = CGPoint(x: tip.x - b.midX, y: tip.y - b.midY)
        let len = (dir.x * dir.x + dir.y * dir.y).squareRoot()
        guard len > 0 else { return body }
        let n = CGPoint(x: -dir.y / len, y: dir.x / len)
        let h = base / 2
        let tri = CGMutablePath()
        tri.move(to: CGPoint(x: b.midX + n.x * h, y: b.midY + n.y * h))
        tri.addLine(to: tip)
        tri.addLine(to: CGPoint(x: b.midX - n.x * h, y: b.midY - n.y * h))
        tri.closeSubpath()
        return body.union(tri)
    }

    /// Cloud outline: circles along an inner ellipse, merged.
    static func cloud(_ b: CGRect) -> CGPath {
        var p: CGPath = CGPath(ellipseIn: b.insetBy(dx: b.width * 0.12, dy: b.height * 0.12), transform: nil)
        let n = 10
        let r = min(b.width, b.height) * 0.2
        for i in 0..<n {
            let a = Double(i) / Double(n) * 2 * Double.pi
            let c = CGPoint(x: b.midX + cos(a) * (b.width / 2 - r), y: b.midY + sin(a) * (b.height / 2 - r))
            p = p.union(CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil))
        }
        return p
    }

    /// Body plus a trail of shrinking circles toward `tip` (separate subpaths).
    static func thought(_ body: CGPath, _ b: CGRect, _ tip: CGPoint) -> CGPath {
        guard !b.contains(tip) else { return body }
        let p = CGMutablePath()
        p.addPath(body)
        let short = min(b.width, b.height)
        // Start just outside the body along the centre → tip line.
        let start = CGPoint(x: b.midX + (tip.x - b.midX) * 0.55, y: b.midY + (tip.y - b.midY) * 0.55)
        let k = Spec.thoughtTrail
        for i in 0..<k {
            let f = Double(i + 1) / Double(k)
            let c = CGPoint(x: start.x + (tip.x - start.x) * f, y: start.y + (tip.y - start.y) * f)
            let r = short * 0.09 * (1 - 0.25 * Double(i))
            p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        return p
    }

    /// Arrow callout: shaft from the anchor (0, 0) to the tail point, with caps.
    static func arrow(_ c: CalloutContent) -> (shaft: CGPath, caps: CGPath) {
        let w = max(c.strokeWidth, 1)
        let tip = c.tail
        let len = (tip.x * tip.x + tip.y * tip.y).squareRoot()
        let shaft = CGMutablePath(), caps = CGMutablePath()
        guard len > 0 else { return (shaft, caps) }
        let u = CGPoint(x: tip.x / len, y: tip.y / len)
        let headL = max(w * Spec.arrowHeadLength, 6), headW = max(w * Spec.arrowHeadHalfWidth, 4)
        func cap(_ kind: String, at p: CGPoint, dir d: CGPoint) -> Double {
            // Returns how far the shaft must stop short of `p`.
            let nn = CGPoint(x: -d.y, y: d.x)
            switch kind {
            case "arrow", "fletching":
                let back = CGPoint(x: p.x - d.x * headL, y: p.y - d.y * headL)
                caps.move(to: p)
                caps.addLine(to: CGPoint(x: back.x + nn.x * headW, y: back.y + nn.y * headW))
                caps.addLine(to: CGPoint(x: back.x - nn.x * headW, y: back.y - nn.y * headW))
                caps.closeSubpath()
                return headL * 0.8
            case "diamond":
                let m = CGPoint(x: p.x - d.x * headL / 2, y: p.y - d.y * headL / 2)
                caps.move(to: p)
                caps.addLine(to: CGPoint(x: m.x + nn.x * headW, y: m.y + nn.y * headW))
                caps.addLine(to: CGPoint(x: p.x - d.x * headL, y: p.y - d.y * headL))
                caps.addLine(to: CGPoint(x: m.x - nn.x * headW, y: m.y - nn.y * headW))
                caps.closeSubpath()
                return headL / 2
            case "circle", "rounded":
                caps.addEllipse(in: CGRect(x: p.x - headW, y: p.y - headW, width: 2 * headW, height: 2 * headW))
                return 0
            case "square", "base":
                let h = headW
                caps.addLines(between: [CGPoint(x: p.x + (d.x + nn.x) * h, y: p.y + (d.y + nn.y) * h),
                                        CGPoint(x: p.x + (d.x - nn.x) * h, y: p.y + (d.y - nn.y) * h),
                                        CGPoint(x: p.x + (-d.x - nn.x) * h, y: p.y + (-d.y - nn.y) * h),
                                        CGPoint(x: p.x + (-d.x + nn.x) * h, y: p.y + (-d.y + nn.y) * h)])
                caps.closeSubpath()
                return 0
            default:
                return 0
            }
        }
        let endInset = cap(c.tailCap, at: tip, dir: u)
        let startInset = cap(c.anchorCap, at: .zero, dir: CGPoint(x: -u.x, y: -u.y))
        shaft.move(to: CGPoint(x: u.x * startInset, y: u.y * startInset))
        shaft.addLine(to: CGPoint(x: tip.x - u.x * endInset, y: tip.y - u.y * endInset))
        return (shaft, caps)
    }

    /// Everything the callout draws, callout px: box, tail and stroke.
    static func bounds(_ c: CalloutContent) -> CGRect {
        var pad = c.strokeWidth / 2 + 2 + c.textStrokeWidth
        if let dc = c.dynamicCaption { pad += DynamicCaptionText.overhang(dc.style, fontSize: c.fontSize) }
        if c.shape == "arrow" {
            let w = max(c.strokeWidth, 1)
            let head = max(max(w * Spec.arrowHeadLength, 6), max(w * Spec.arrowHeadHalfWidth, 4)) + pad
            return CGRect(x: min(0, c.tail.x), y: min(0, c.tail.y), width: abs(c.tail.x), height: abs(c.tail.y))
                .insetBy(dx: -head, dy: -head)
        }
        var r = box(c)
        if let b = body(c) { r = r.union(b.boundingBoxOfPath) }
        return r.insetBy(dx: -pad, dy: -pad)
    }
}

/// Draws callouts into bitmaps with CoreGraphics and Core Text. Not thread-safe (owned by the compositor).
final class CalloutRasterizer {
    private struct Entry { var content: CalloutContent; var scale: Double; var texture: any MTLTexture; var rect: CGRect }
    private var cache: [Entry] = []
    static let cacheSize = 24
    /// Largest texture side, px.
    static let maxSide = 4096.0

    /// Texture of `c` at `scale` texture px per callout px, and the callout-px rect it covers.
    func texture(_ c: CalloutContent, scale: Double, device: any MTLDevice) -> (texture: any MTLTexture, rect: CGRect)? {
        let rect = CalloutGeometry.bounds(c)
        guard rect.width > 0, rect.height > 0, rect.width.isFinite, rect.height.isFinite else { return nil }
        // Quantise the scale so playback zooms don't re-rasterise every frame.
        let q = pow(2, (log2(max(scale, 1e-3)) * 8).rounded(.up) / 8)
        let s = min(q, Self.maxSide / rect.width, Self.maxSide / rect.height)
        if let i = cache.firstIndex(where: { $0.content == c && $0.scale == s }) {
            let e = cache.remove(at: i)
            cache.append(e)
            return (e.texture, e.rect)
        }
        guard let img = Self.draw(c, rect: rect, scale: s), let tex = CompositorCore.makeTexture(img, device: device)
        else { return nil }
        cache.append(Entry(content: c, scale: s, texture: tex, rect: rect))
        if cache.count > Self.cacheSize { cache.removeFirst() }
        return (tex, rect)
    }

    static func draw(_ c: CalloutContent, rect: CGRect, scale s: Double) -> CGImage? {
        let w = max(Int((rect.width * s).rounded(.up)), 1), h = max(Int((rect.height * s).rounded(.up)), 1)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: Double(w) / rect.width, y: Double(h) / rect.height)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        ctx.setShouldAntialias(true)
        func cg(_ c: RGBA) -> CGColor { CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }
        func applyDash() {
            if let pattern = CalloutGeometry.Spec.dashes[c.strokeStyle] {
                ctx.setLineDash(phase: 0, lengths: pattern.map { $0 * max(c.strokeWidth, 1) })
                ctx.setLineCap(c.strokeStyle == "dot" ? .round : .butt)
            }
        }
        switch c.kind {
        case "remix", "":
            if c.shape == "arrow" {
                let a = CalloutGeometry.arrow(c)
                ctx.setStrokeColor(cg(c.stroke)); ctx.setLineWidth(max(c.strokeWidth, 1)); ctx.setLineJoin(.round)
                applyDash()
                ctx.addPath(a.shaft); ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
                ctx.setFillColor(cg(c.stroke)); ctx.addPath(a.caps); ctx.fillPath()
            } else if let body = CalloutGeometry.body(c) {
                if c.fill.a > 0 { ctx.setFillColor(cg(c.fill)); ctx.addPath(body); ctx.fillPath() }
                if c.strokeWidth > 0, c.stroke.a > 0 {
                    ctx.setStrokeColor(cg(c.stroke)); ctx.setLineWidth(c.strokeWidth); ctx.setLineJoin(.round)
                    applyDash()
                    ctx.addPath(body); ctx.strokePath()
                    ctx.setLineDash(phase: 0, lengths: [])
                }
            }
        case "TypeWinHighlighter":
            // Translucent fill over the box [callouts.md §3; blend mode ?].
            ctx.setFillColor(cg(c.fill)); ctx.fill(CalloutGeometry.box(c))
        default:
            break
        }
        if c.dynamicCaption != nil {
            DynamicCaptionText.draw(c, in: ctx)
        } else if !c.text.isEmpty {
            CalloutText.draw(c, in: ctx)
        }
        return ctx.makeImage()
    }
}

/// Core Text layout of a callout's text [callouts.md §5].
enum CalloutText {
    enum Spec {
        /// Inner padding of the text box, callout px [?].
        static let padding = 0.0
    }

    static func weight(_ name: String) -> Int {
        switch name.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "") {
        case "thin", "hairline": 100
        case "extralight", "ultralight": 200
        case "light": 300
        case "medium": 500
        case "semibold", "demibold": 600
        case "bold": 700
        case "extrabold", "ultrabold", "heavy": 800
        case "black": 900
        default: 400
        }
    }

    /// CSS weight → Core Text weight trait (−1…1).
    static func trait(_ w: Int) -> Double {
        switch w {
        case ..<150: -0.8
        case ..<250: -0.6
        case ..<350: -0.4
        case ..<450: 0
        case ..<550: 0.23
        case ..<650: 0.3
        case ..<750: 0.4
        case ..<850: 0.56
        default: 0.62
        }
    }

    static func font(family: String, size: Double, weight: Int, italic: Bool) -> CTFont {
        var traits: [CFString: Any] = [kCTFontWeightTrait: trait(weight)]
        if italic { traits[kCTFontSymbolicTrait] = CTFontSymbolicTraits.traitItalic.rawValue }
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family,
                                                         kCTFontTraitsAttribute: traits] as CFDictionary)
        return CTFontCreateWithFontDescriptor(desc, max(size, 1), nil)
    }

    static func attributed(_ c: CalloutContent, fill: Bool, strokeWidth: Double) -> NSAttributedString {
        let text = c.text as NSString
        let s = NSMutableAttributedString(string: c.text)
        let all = NSRange(location: 0, length: text.length)
        let baseWeight = weight(c.fontWeight)
        // Per-character resolved attributes: base, then runs in order.
        var sizes = [Double](repeating: c.fontSize, count: text.length)
        var names = [String](repeating: c.fontName, count: text.length)
        var weights = [Int](repeating: baseWeight, count: text.length)
        var italics = [Bool](repeating: false, count: text.length)
        for r in c.runs {
            let lo = max(r.range.lowerBound, 0), hi = min(r.range.upperBound, text.length)
            guard lo < hi else { continue }
            for i in lo..<hi {
                if let v = r.fontSize { sizes[i] = v }
                if let v = r.fontName { names[i] = v }
                if let v = r.fontWeight { weights[i] = v }
                if let v = r.italic { italics[i] = v }
            }
        }
        // Coalesce equal font attributes into ranges.
        var i = 0
        while i < text.length {
            var j = i + 1
            while j < text.length, sizes[j] == sizes[i], names[j] == names[i], weights[j] == weights[i],
                  italics[j] == italics[i] { j += 1 }
            s.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String),
                           value: font(family: names[i], size: sizes[i], weight: weights[i], italic: italics[i]),
                           range: NSRange(location: i, length: j - i))
            i = j
        }
        func cg(_ c: RGBA) -> CGColor { CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }
        let fg = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        s.addAttribute(fg, value: cg(fill ? c.textColor : c.textStrokeColor), range: all)
        if fill {
            for r in c.runs {
                let range = NSIntersectionRange(NSRange(location: r.range.lowerBound, length: r.range.count), all)
                guard range.length > 0 else { continue }
                if let col = r.color { s.addAttribute(fg, value: cg(col), range: range) }
                if r.underline == true {
                    s.addAttribute(NSAttributedString.Key(kCTUnderlineStyleAttributeName as String),
                                   value: CTUnderlineStyle.single.rawValue, range: range)
                }
            }
        } else {
            // Stroke-only pass: Core Text stroke width is a percentage of the font size.
            for k in 0..<text.length where sizes[k] > 0 {
                s.addAttribute(NSAttributedString.Key(kCTStrokeWidthAttributeName as String),
                               value: strokeWidth / sizes[k] * 100, range: NSRange(location: k, length: 1))
            }
        }
        if c.tracking != 0 {
            s.addAttribute(NSAttributedString.Key(kCTKernAttributeName as String), value: c.tracking, range: all)
        }
        for r in c.runs {
            guard let k = r.kerning else { continue }
            let range = NSIntersectionRange(NSRange(location: r.range.lowerBound, length: r.range.count), all)
            if range.length > 0 { s.addAttribute(NSAttributedString.Key(kCTKernAttributeName as String), value: k, range: range) }
        }
        var align: CTTextAlignment = switch c.horizontalAlignment {
        case "left": .left
        case "right": .right
        case "justified", "justify": .justified
        default: .center
        }
        var spacing = CGFloat(c.lineSpacing)
        let style = withUnsafeBytes(of: &align) { a in
            withUnsafeBytes(of: &spacing) { sp in
                let settings = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: a.baseAddress!),
                    CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size,
                                            value: sp.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        s.addAttribute(NSAttributedString.Key(kCTParagraphStyleAttributeName as String), value: style, range: all)
        return s
    }

    /// Draws the text into `ctx` (callout px, +y up). Text stroke is drawn first at twice the width, so the
    /// fill on top leaves an outside outline of `textStrokeWidth` [inf; alignment enum ?].
    static func draw(_ c: CalloutContent, in ctx: CGContext) {
        let box = CalloutGeometry.box(c).insetBy(dx: Spec.padding, dy: Spec.padding)
        guard box.width > 0, box.height > 0 else { return }
        let fillText = attributed(c, fill: true, strokeWidth: 0)
        let setter = CTFramesetterCreateWithAttributedString(fillText)
        let constraint = CGSize(width: c.wordWrap ? box.width : .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil, constraint, nil)
        let fw = c.wordWrap ? box.width : max(box.width, fit.width.rounded(.up))
        let fh = fit.height.rounded(.up) + 1
        let y: Double = switch c.verticalAlignment {
        case "top": box.maxY - fh
        case "bottom": box.minY
        default: box.midY - fh / 2
        }
        let frameRect = CGRect(x: box.midX - fw / 2, y: y, width: fw, height: fh)
        let path = CGPath(rect: frameRect, transform: nil)
        if c.textStrokeWidth > 0, c.textStrokeColor.a > 0 {
            let strokeSetter = CTFramesetterCreateWithAttributedString(attributed(c, fill: false, strokeWidth: 2 * c.textStrokeWidth))
            ctx.setLineJoin(.round)
            CTFrameDraw(CTFramesetterCreateFrame(strokeSetter, CFRange(location: 0, length: 0), path, nil), ctx)
        }
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), ctx)
    }
}
