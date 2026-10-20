import CoreGraphics
import Foundation
import os

// CO3 callout kinds (`docs/specs/callouts.md` §3.1): Sketch Motion strokes from the callout's own SVG
// (`xmlContent`, the user's project content: parsed and drawn in place, never stored), and the
// Keystroke key cap (WizRec's own drawing).

enum CalloutKinds {
    /// Sketch Motion kinds [obs].
    static let sketch: Set<String> = ["TypeWinSVG", "MacSVG"]
    static let keystroke = "MacKey"
    /// Key text size as a fraction of the box height [WizRec].
    static let keystrokeFontFraction = 0.45

    /// Key cap colours per `keyStyle` (0–4; their looks are [?]) [WizRec]: even = light key, odd = dark.
    static func keyColors(_ style: Int) -> (cap: RGBA, edge: RGBA, text: RGBA) {
        style % 2 == 0
            ? (RGBA(0.96, 0.96, 0.97, 1), RGBA(0.62, 0.63, 0.66, 1), RGBA(0.1, 0.1, 0.12, 1))
            : (RGBA(0.16, 0.17, 0.19, 1), RGBA(0.05, 0.05, 0.06, 1), RGBA(0.96, 0.96, 0.97, 1))
    }

    /// Draws the key cap filling the box (rounded by `cornerRadius`, default 6).
    static func drawKey(_ c: CalloutContent, in ctx: CGContext) {
        guard c.showKeyBackground else { return }
        let box = CalloutGeometry.box(c).insetBy(dx: 1, dy: 1)
        guard box.width > 0, box.height > 0 else { return }
        let r = min(max(c.cornerRadius, 0), min(box.width, box.height) / 2)
        let path = CGPath(roundedRect: box, cornerWidth: r, cornerHeight: r, transform: nil)
        let colors = keyColors(c.keyStyle)
        ctx.setFillColor(CGColor(srgbRed: colors.cap.r, green: colors.cap.g, blue: colors.cap.b, alpha: colors.cap.a))
        ctx.addPath(path); ctx.fillPath()
        ctx.setStrokeColor(CGColor(srgbRed: colors.edge.r, green: colors.edge.g, blue: colors.edge.b, alpha: colors.edge.a))
        ctx.setLineWidth(2); ctx.addPath(path); ctx.strokePath()
    }

    /// Strokes the sketch: paths in document order, each drawn up to the overall fraction
    /// `drawProgress` of the total stroke length [inf: draw-on reveals the strokes in order].
    /// The SVG `viewBox` is fitted into the box (centred, aspect kept); `stroke` / `strokeWidth`
    /// (callout px) replace the document's own styling [obs keys; inf look].
    static func drawSketch(_ c: CalloutContent, in ctx: CGContext) {
        guard let svg = c.svg, let doc = SketchSVG.parsed(svg), c.strokeWidth > 0, c.drawProgress > 0 else { return }
        let box = CalloutGeometry.box(c)
        let vb = doc.viewBox.width > 0 && doc.viewBox.height > 0 ? doc.viewBox : doc.bounds
        guard vb.width > 0, vb.height > 0, box.width > 0, box.height > 0 else { return }
        let s = min(box.width / vb.width, box.height / vb.height)
        // SVG y down → callout y up, centred in the box.
        let t = CGAffineTransform(translationX: box.midX, y: box.midY).scaledBy(x: s, y: -s)
            .translatedBy(x: -vb.midX, y: -vb.midY)
        var budget = doc.length * Conventions.clamp01(c.drawProgress)
        ctx.setStrokeColor(CGColor(srgbRed: c.stroke.r, green: c.stroke.g, blue: c.stroke.b, alpha: c.stroke.a))
        ctx.setLineWidth(c.strokeWidth); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        for poly in doc.polylines where budget > 0 {
            guard let first = poly.first else { continue }
            ctx.move(to: first.applying(t))
            for i in 1..<max(poly.count, 1) where i < poly.count {
                let a = poly[i - 1], b = poly[i]
                let d = hypot(b.x - a.x, b.y - a.y)
                if d <= budget {
                    ctx.addLine(to: b.applying(t)); budget -= d
                } else {
                    let f = d > 0 ? budget / d : 0
                    ctx.addLine(to: CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f).applying(t))
                    budget = 0
                    break
                }
            }
            ctx.strokePath()
        }
    }
}

/// The stroke geometry of an SVG document: flattened polylines in document order (SVG units, y down).
/// Supports `path` (M L H V C S Q T A Z, absolute and relative; arcs drawn as straight segments
/// [WizRec]), `line`, `polyline`, `polygon`, `rect`, `circle` and `ellipse`. `transform` attributes are
/// not applied [WizRec].
struct SketchSVG: Sendable {
    var viewBox: CGRect
    var polylines: [[CGPoint]]
    /// Total polyline length, SVG units.
    var length: Double
    var bounds: CGRect

    /// Segments per curve when flattening.
    static let curveSteps = 16

    // Parsed documents by content, small LRU. Sendable: guarded by the lock.
    private static let cache = OSAllocatedUnfairLock(initialState: [(key: String, doc: SketchSVG?)]())
    private static let cacheSize = 8

    /// The parsed document for `text` (cached; nil when it is not usable SVG).
    static func parsed(_ text: String) -> SketchSVG? {
        if let hit = cache.withLock({ c in c.first { $0.key == text } }) { return hit.doc }
        let doc = parse(text)
        cache.withLock { c in
            c.append((text, doc))
            if c.count > cacheSize { c.removeFirst() }
        }
        return doc
    }

    static func parse(_ text: String) -> SketchSVG? {
        let delegate = Collector()
        let parser = XMLParser(data: Data(text.utf8))
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() || !delegate.polylines.isEmpty else { return nil }
        let polys = delegate.polylines.filter { $0.count > 1 }
        guard !polys.isEmpty else { return nil }
        var length = 0.0
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for p in polys {
            for (i, q) in p.enumerated() {
                minX = min(minX, q.x); minY = min(minY, q.y); maxX = max(maxX, q.x); maxY = max(maxY, q.y)
                if i > 0 { length += hypot(q.x - p[i - 1].x, q.y - p[i - 1].y) }
            }
        }
        return SketchSVG(viewBox: delegate.viewBox, polylines: polys, length: length,
                         bounds: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var viewBox = CGRect.zero
        var polylines: [[CGPoint]] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String] = [:]) {
            func num(_ k: String) -> Double { Double(a[k]?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0 }
            switch name.lowercased() {
            case "svg":
                let v = SketchSVG.numbers(a["viewBox"] ?? "")
                if v.count == 4 { viewBox = CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) }
                else if num("width") > 0, num("height") > 0 { viewBox = CGRect(x: 0, y: 0, width: num("width"), height: num("height")) }
            case "path":
                polylines += SketchSVG.path(a["d"] ?? "")
            case "line":
                polylines.append([CGPoint(x: num("x1"), y: num("y1")), CGPoint(x: num("x2"), y: num("y2"))])
            case "polyline", "polygon":
                let v = SketchSVG.numbers(a["points"] ?? "")
                var pts = stride(from: 0, to: v.count - 1, by: 2).map { CGPoint(x: v[$0], y: v[$0 + 1]) }
                if name.lowercased() == "polygon", let f = pts.first { pts.append(f) }
                polylines.append(pts)
            case "rect":
                let r = CGRect(x: num("x"), y: num("y"), width: num("width"), height: num("height"))
                polylines.append([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY),
                                  CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY)])
            case "circle", "ellipse":
                let rx = name.lowercased() == "circle" ? num("r") : num("rx"), ry = name.lowercased() == "circle" ? num("r") : num("ry")
                let n = 4 * SketchSVG.curveSteps
                polylines.append((0...n).map { i in
                    let t = Double(i) / Double(n) * 2 * .pi
                    return CGPoint(x: num("cx") + rx * cos(t), y: num("cy") + ry * sin(t))
                })
            default:
                break
            }
        }
    }

    /// SVG number syntax: optional sign, digits with an optional fraction (or a leading-dot fraction),
    /// optional exponent. Adjacent numbers need no separator (`"1-2.5.5"` = 1, −2.5, 0.5).
    private static let numberPattern = try? NSRegularExpression(pattern: #"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?"#)

    /// All numbers in `s`, in order.
    static func numbers(_ s: String) -> [Double] {
        guard let re = numberPattern else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { Double(ns.substring(with: $0.range)) }
    }

    /// Flattens an SVG path `d` into polylines (one per subpath).
    static func path(_ d: String) -> [[CGPoint]] {
        // Split into (command, numbers) groups.
        var groups: [(Character, [Double])] = []
        var buf = ""
        var cmd: Character?
        for ch in d {
            if "MmLlHhVvCcSsQqTtAaZz".contains(ch) {
                if let c = cmd { groups.append((c, numbers(buf))) }
                cmd = ch; buf = ""
            } else {
                buf.append(ch)
            }
        }
        if let c = cmd { groups.append((c, numbers(buf))) }

        var out: [[CGPoint]] = []
        var cur: [CGPoint] = []
        var p = CGPoint.zero, start = CGPoint.zero
        var lastCtrl: CGPoint?, lastCmd: Character = " "
        func line(_ q: CGPoint) { if cur.isEmpty { cur.append(p) }; cur.append(q); p = q }
        func cubic(_ c1: CGPoint, _ c2: CGPoint, _ e: CGPoint) {
            let p0 = p
            for i in 1...curveSteps {
                let t = Double(i) / Double(curveSteps), u = 1 - t
                let x = u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * e.x
                let y = u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * e.y
                line(CGPoint(x: x, y: y))
            }
            p = e
        }
        func quad(_ c: CGPoint, _ e: CGPoint) {
            let p0 = p
            for i in 1...curveSteps {
                let t = Double(i) / Double(curveSteps), u = 1 - t
                line(CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * e.x, y: u * u * p0.y + 2 * u * t * c.y + t * t * e.y))
            }
            p = e
        }
        func endSubpath() { if cur.count > 1 { out.append(cur) }; cur = [] }
        for (c, v) in groups {
            let rel = c.isLowercase
            func pt(_ i: Int) -> CGPoint {
                let q = CGPoint(x: v[i], y: v[i + 1])
                return rel ? CGPoint(x: p.x + q.x, y: p.y + q.y) : q
            }
            switch c.uppercased().first ?? " " {
            case "M":
                var i = 0
                while i + 1 < v.count {
                    if i == 0 { endSubpath(); p = pt(0); start = p; cur = [p] } else { line(pt(i)) }
                    i += 2
                }
                lastCtrl = nil
            case "L":
                var i = 0
                while i + 1 < v.count { line(pt(i)); i += 2 }
                lastCtrl = nil
            case "H":
                for x in v { line(CGPoint(x: rel ? p.x + x : x, y: p.y)) }
                lastCtrl = nil
            case "V":
                for y in v { line(CGPoint(x: p.x, y: rel ? p.y + y : y)) }
                lastCtrl = nil
            case "C":
                var i = 0
                while i + 5 < v.count {
                    let c1 = pt(i), c2 = pt(i + 2), e = pt(i + 4)
                    cubic(c1, c2, e); lastCtrl = c2; i += 6
                }
            case "S":
                var i = 0
                while i + 3 < v.count {
                    let c1 = (lastCmd == "C" || lastCmd == "S") ? lastCtrl.map { CGPoint(x: 2 * p.x - $0.x, y: 2 * p.y - $0.y) } ?? p : p
                    let c2 = pt(i), e = pt(i + 2)
                    cubic(c1, c2, e); lastCtrl = c2; i += 4
                }
            case "Q":
                var i = 0
                while i + 3 < v.count {
                    let q = pt(i), e = pt(i + 2)
                    quad(q, e); lastCtrl = q; i += 4
                }
            case "T":
                var i = 0
                while i + 1 < v.count {
                    let q = (lastCmd == "Q" || lastCmd == "T") ? lastCtrl.map { CGPoint(x: 2 * p.x - $0.x, y: 2 * p.y - $0.y) } ?? p : p
                    let e = pt(i)
                    quad(q, e); lastCtrl = q; i += 2
                }
            case "A":
                var i = 0
                while i + 6 < v.count {
                    let e = rel ? CGPoint(x: p.x + v[i + 5], y: p.y + v[i + 6]) : CGPoint(x: v[i + 5], y: v[i + 6])
                    line(e); i += 7
                }
                lastCtrl = nil
            case "Z":
                line(start); endSubpath(); cur = [start]; p = start
                lastCtrl = nil
            default:
                break
            }
            lastCmd = Character(c.uppercased())
        }
        endSubpath()
        return out
    }
}
