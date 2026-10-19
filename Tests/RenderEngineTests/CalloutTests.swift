import CoreGraphics
import Foundation
import ImageIO
import Testing
import TSCProjKit
@testable import RenderEngine

private let s = P.rate

private func calloutClip(_ def: [String: Any], id: Int = 60, parameters: [String: Any] = [:]) -> [String: Any] {
    P.clip("Callout", id: id, start: 0, duration: 2 * s, parameters: parameters, extra: ["def": def])
}

private func content(_ def: [String: Any], at t: Int64 = 0) throws -> CalloutContent {
    let scene = P.scene(try P.project(tracks: [P.track(0, [calloutClip(def)])]))
    guard case .callout(let c) = scene.evaluate(at: t).layers.first?.content else {
        throw CocoaError(.featureUnsupported)
    }
    return c
}

@Suite struct CalloutModelTests {
    @Test func readsTheDef() throws {
        let c = try content([
            "kind": "remix", "shape": "speech-bubble2", "style": "basic", "width": 332.8, "height": 182.3,
            "fill-color-red": 1.0, "fill-color-green": 0.5, "fill-color-blue": 0.0, "fill-color-opacity": 0.75,
            "stroke-color-red": 0.0, "stroke-color-green": 0.0, "stroke-color-blue": 1.0, "stroke-color-opacity": 1.0,
            "stroke-width": 6.0, "stroke-style": "dash", "tail-x": -168.5, "tail-y": -185.5,
            "text": "Héllo", "horizontal-alignment": "left", "vertical-alignment": "top", "word-wrap": 1.0,
            "font": ["name": "Helvetica Neue", "weight": "Bold", "size": 96.0,
                     "color-red": 0.2, "color-green": 0.4, "color-blue": 0.6],
            "textAttributes": ["type": "textAttributeList", "keyframes": [
                ["time": 0, "endTime": 0, "duration": 0, "value": [
                    ["name": "fontSize", "rangeStart": 0, "rangeEnd": 5, "value": 39.0, "valueType": "double"],
                    ["name": "fgColor", "rangeStart": 1, "rangeEnd": 2, "value": "(255,0,0,255)", "valueType": "color"],
                    ["name": "fontWeight", "rangeStart": 0, "rangeEnd": 5, "value": 700, "valueType": "int"],
                ]],
            ]],
        ])
        #expect(c.kind == "remix" && c.shape == "speech-bubble2")
        #expect(c.size == CGSize(width: 332.8, height: 182.3))
        #expect(c.fill == RGBA(1, 0.5, 0, 0.75) && c.stroke == RGBA(0, 0, 1, 1))
        #expect(c.strokeWidth == 6 && c.strokeStyle == "dash")
        #expect(c.tail == CGPoint(x: -168.5, y: -185.5))
        #expect(c.fontName == "Helvetica Neue" && c.fontSize == 96 && c.textColor == RGBA(0.2, 0.4, 0.6, 1))
        #expect(c.horizontalAlignment == "left" && c.verticalAlignment == "top")
        #expect(c.runs.count == 3)
        #expect(c.runs[0].fontSize == 39 && c.runs[0].range == 0..<5)
        #expect(c.runs[1].color == RGBA(1, 0, 0, 1))
        #expect(c.runs[2].fontWeight == 700)
    }

    @Test func arrowTailIsAnimatable() throws {
        let def: [String: Any] = [
            "kind": "remix", "shape": "arrow", "stroke-width": 8.0, "shape-anchor": "circle", "shape-tail": "arrow",
            "tail-x": P.keyframed(100, [(time: 0, end: s, value: 300)]),
            "tail-y": ["type": "double", "defaultValue": 0.0, "interp": "eioe"],
        ]
        #expect(try content(def, at: 0).tail == CGPoint(x: 100, y: 0))
        #expect(try content(def, at: s / 2).tail.x == 200)
        #expect(try content(def, at: s).anchorCap == "circle")
    }

    @Test func presetHexColours() {
        #expect(SCallout.hexColor("FF0000") == RGBA(1, 0, 0, 1))
        #expect(SCallout.hexColor("00000000") == RGBA(0, 0, 0, 0))
        #expect(SCallout.parenColor("(0,255,0,128)") == RGBA(0, 1, 0, 128.0 / 255))
    }
}

private let canvas = CGSize(width: 192, height: 108)

private func render(_ c: CalloutContent, transform: CGAffineTransform = .identity, w: Int = 192, h: Int = 108)
    throws -> GPUTest.Image {
    let l = Layer(clipID: 1, content: .callout(c), size: c.size, transform: transform)
    return try GPUTest.render(RenderPlan(time: 0, canvasSize: CGSize(width: w, height: h), background: RGBA(1, 1, 1),
                                         layers: [l]), w, h)
}

@Suite(.enabled(if: hasGPU)) struct CalloutRenderTests {
    @Test func rectangleFillAndStroke() throws {
        let c = CalloutContent(shape: "shape-rectangle", size: CGSize(width: 100, height: 60), fill: RGBA(1, 0, 0, 1),
                               stroke: RGBA(0, 0, 1, 1), strokeWidth: 4)
        let img = try render(c)
        #expect(img.at(96, 54) == .red)
        #expect(img.at(46, 54).near(.blue, 3))      // left edge, stroke centred on it
        #expect(img.at(40, 54) == .white)
    }

    @Test func ellipseLeavesCornersEmpty() throws {
        let c = CalloutContent(shape: "shape-ellipse", size: CGSize(width: 100, height: 60), fill: RGBA(0, 1, 0, 1))
        let img = try render(c)
        #expect(img.at(96, 54) == .green && img.at(48, 26) == .white)
    }

    @Test func speechBubbleTailReachesItsTip() throws {
        // Box 80×40 centred; tip 30 px below the box's bottom-left quarter (+y up → lower on screen).
        let c = CalloutContent(shape: "speech-bubble", size: CGSize(width: 80, height: 40), fill: RGBA(0, 0, 1, 1),
                               tail: CGPoint(x: -20, y: -50))
        let img = try render(c)
        #expect(img.at(96, 54) == .blue)
        #expect(img.at(82, 88) == .blue)               // on the tail, below the box (bottom 74)
        #expect(img.at(116, 100) == .white)
    }

    @Test func arrowDrawsShaftAndHead() throws {
        let c = CalloutContent(shape: "arrow", size: .zero, stroke: RGBA(0, 0, 0, 1), strokeWidth: 4,
                               tail: CGPoint(x: 60, y: 0), anchorCap: "none", tailCap: "arrow")
        let img = try render(c)
        #expect(img.at(110, 54).near(.black, 3))   // shaft
        #expect(img.at(152, 54).near(.black, 30))  // head near the tip (156)
        #expect(img.at(110, 64) == .white)
        #expect(img.at(80, 54) == .white)          // behind the anchor
    }

    @Test func textIsDrawnInsideTheBox() throws {
        let c = CalloutContent(shape: "text", size: CGSize(width: 160, height: 80), text: "WWW", fontName: "Helvetica",
                               fontSize: 40, textColor: RGBA(0, 0, 0, 1))
        let img = try render(c)
        var dark = 0, outside = 0
        for y in 0..<108 {
            for x in 0..<192 where img.at(x, y).r < 128 {
                if x >= 16 && x < 176 && y >= 14 && y < 94 { dark += 1 } else { outside += 1 }
            }
        }
        #expect(dark > 300)
        #expect(outside == 0)
        // Runs override the base size: tiny text has far fewer dark pixels.
        var small = c
        small.runs = [CalloutTextRun(range: 0..<3, fontSize: 10)]
        let img2 = try render(small)
        var dark2 = 0
        for y in 0..<108 { for x in 0..<192 where img2.at(x, y).r < 128 { dark2 += 1 } }
        #expect(dark2 > 0 && dark2 < dark / 4)
    }

    @Test func calloutScalesWithItsTransformSharply() throws {
        // 10× scale renders from a 10× raster, not an upscaled 1× bitmap: edges stay sharp.
        let c = CalloutContent(shape: "shape-rectangle", size: CGSize(width: 10, height: 6), fill: RGBA(1, 0, 0, 1))
        let img = try render(c, transform: CGAffineTransform(scaleX: 10, y: 10))
        // Edge at x = 46: at most one transitional pixel each side.
        #expect(img.at(47, 54) == .red && img.at(44, 54) == .white && img.at(45, 54).near(.white, 40))
    }

    /// Writes a contact sheet of every shape for eyeballing when WIZREC_RENDER_OUT is set.
    @Test func contactSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["WIZREC_RENDER_OUT"] else { return }
        let shapes = ["shape-rectangle", "shape-ellipse", "shape-star", "shape-octagon", "shape-triangle", "text",
                      "text-rectangle", "speech-bubble", "speech-bubble2", "thought-bubble", "thought-bubble2",
                      "text-arrow", "text-arrow2", "arrow"]
        let styles = ["solid", "dash", "dot", "dashdot", "dashdotdot"]
        var layers: [Layer] = []
        for (i, shape) in shapes.enumerated() {
            let col = Double(i % 5), row = Double(i / 5)
            let c = CalloutContent(shape: shape, size: CGSize(width: 240, height: 160), fill: RGBA(0.2, 0.4, 0.8, 1),
                                   stroke: RGBA(0.1, 0.1, 0.1, 1), strokeWidth: 6, strokeStyle: styles[i % 5],
                                   tail: shape == "arrow" ? CGPoint(x: 200, y: 60) : CGPoint(x: -100, y: -140),
                                   anchorCap: "circle", text: shape.contains("text") || shape.contains("bubble") ? "Ag Wy 123" : "",
                                   fontName: "Helvetica", fontSize: 40, textColor: RGBA(1, 1, 1, 1), textStrokeWidth: 2)
            layers.append(Layer(clipID: Int64(i), content: .callout(c), size: c.size,
                                transform: CGAffineTransform(translationX: -760 + col * 380, y: 360 - row * 360)))
        }
        let plan = RenderPlan(time: 0, canvasSize: CGSize(width: 1920, height: 1080), background: RGBA(1, 1, 1),
                              layers: layers)
        let img = try GPUTest.render(plan, 1920, 1080)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var bytes = img.bytes
        let ctx = CGContext(data: &bytes, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 1920 * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        try writePNG(ctx.makeImage()!, to: URL(fileURLWithPath: dir).appendingPathComponent("callout-sheet.png"))
    }
}
