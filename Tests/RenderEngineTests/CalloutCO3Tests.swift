import CoreGraphics
import Foundation
import Testing
import TSCProjKit
@testable import RenderEngine

// CO3 callouts (`docs/specs/callouts.md` §3.1): region, keystroke and Sketch Motion keys. Every SVG here is
// WizRec's own test drawing (never TechSmith artwork).

private let s = P.rate

/// Our own test drawing: two horizontal strokes on a 100×100 viewBox, top one first.
private let twoStrokes = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <path d="M10 25 L90 25"/>
  <path d="m10 75 h80"/>
</svg>
"""

private func content(_ def: [String: Any], at t: Int64 = 0, extra: [String: Any] = [:]) throws -> CalloutContent {
    let clip = P.clip("Callout", id: 60, start: 0, duration: 5 * s, extra: ["def": def].merging(extra) { a, _ in a })
    let scene = P.scene(try P.project(tracks: [P.track(0, [clip])]))
    guard case .callout(let c) = scene.evaluate(at: t).layers.first?.content else { throw CocoaError(.featureUnsupported) }
    return c
}

@Suite struct CalloutCO3ModelTests {
    @Test func highlighterKeys() throws {
        let c = try content(["kind": "TypeWinHighlighter", "shape": "", "style": "", "width": 400.0, "height": 200.0,
                             "fillColorRed": 1.0, "fillColorGreen": 0.0, "fillColorBlue": 1.0, "fill-color-opacity": 0.75,
                             "fill-invert": 0.0, "corner-radius": 6.0])
        #expect(c.fill == RGBA(1, 0, 1, 0.75) && c.cornerRadius == 6 && !c.invert)
    }

    @Test func blurInvertAndIntensity() throws {
        let c = try content(["kind": "TypeWinBlur", "width": 400.0, "height": 200.0, "blur-invert": 1.0, "intensity": 0.8125])
        #expect(c.invert && c.intensity == 0.8125)
    }

    @Test func sketchKeysAndDrawOnRamp() throws {
        let def: [String: Any] = ["kind": "TypeWinSVG", "shape": "", "style": "", "width": 393.6, "height": 117.8,
                                  "DrawTime": 1.0, "borderColorRed": 1.0, "borderColorGreen": 1.0, "borderColorBlue": 0.0,
                                  "borderWidth": 3.0, "corner-radius": 6.0, "xmlContent": twoStrokes]
        let ramp: [String: Any] = ["leftEdgeMods": [["group": "DrawPercentageFade", "duration": s,
                                                     "parameters": [["name": "DrawTime", "func": "FadeInFunc"]]]]]
        let c = try content(def, at: s / 2, extra: ramp)
        #expect(c.svg == twoStrokes && c.stroke == RGBA(1, 1, 0, 1) && c.strokeWidth == 3)
        #expect(abs(c.drawProgress - 0.5) < 1e-9)                 // half-way through the 1 s draw-on
        #expect(try content(def, at: 2 * s, extra: ramp).drawProgress == 1)
        #expect(try content(def, at: s / 2).drawProgress == 1)    // no ramp: DrawTime as written
    }

    @Test func keystrokeKeys() throws {
        let c = try content(["kind": "MacKey", "shape": "", "style": "", "width": 128.0, "height": 64.0,
                             "keys": "⌘ A", "name": "⌘ A", "keyStyle": 2.0, "showKeyBackg": 1.0, "showKeyHint": 0.0])
        #expect(c.text == "⌘ A" && c.keyStyle == 2 && c.showKeyBackground)
        #expect(abs(c.fontSize - 64 * CalloutKinds.keystrokeFontFraction) < 1e-9 && c.runs.isEmpty)
    }
}

@Suite struct SketchSVGTests {
    @Test func numbers() {
        #expect(SketchSVG.numbers("1-2.5.5,3e2 -.5") == [1, -2.5, 0.5, 300, -0.5])
    }

    @Test func pathCommands() throws {
        let doc = try #require(SketchSVG.parse(twoStrokes))
        #expect(doc.viewBox == CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(doc.polylines.count == 2 && abs(doc.length - 160) < 1e-9)
        #expect(doc.polylines[1] == [CGPoint(x: 10, y: 75), CGPoint(x: 90, y: 75)])
        // Curves flatten; Z closes back to the subpath start.
        let curvy = SketchSVG.path("M0 0 C0 10 10 10 10 0 Q15 -5 20 0 Z")
        #expect(curvy.count == 1 && curvy[0].first == .zero && curvy[0].last == .zero)
        #expect(SketchSVG.parse("<svg viewBox='0 0 10 10'><circle cx='5' cy='5' r='4'/></svg>")?.polylines.count == 1)
        #expect(SketchSVG.parse("not svg") == nil)
    }
}

private func render(_ c: CalloutContent, bg: RGBA = RGBA(1, 1, 1), w: Int = 192, h: Int = 108) throws -> GPUTest.Image {
    let l = Layer(clipID: 1, content: .callout(c), size: c.size)
    return try GPUTest.render(RenderPlan(time: 0, canvasSize: CGSize(width: w, height: h), background: bg, layers: [l]), w, h)
}

@Suite(.enabled(if: hasGPU)) struct CalloutCO3RenderTests {
    /// 100×100 box on the 192×108 canvas: x 46…146, y 4…104. Strokes at y 29 (first) and 79 (second).
    private func sketch(_ progress: Double) -> CalloutContent {
        var c = CalloutContent(kind: "TypeWinSVG", shape: "", size: CGSize(width: 100, height: 100),
                               stroke: RGBA(1, 0, 0, 1), strokeWidth: 4)
        c.svg = twoStrokes
        c.drawProgress = progress
        return c
    }

    @Test func sketchDrawsInStrokeOrder() throws {
        let full = try render(sketch(1))
        #expect(full.at(96, 29) == .red && full.at(96, 79) == .red && full.at(96, 54) == .white)
        // A quarter of the 160-unit total = the first half of the first stroke (x 56…96).
        let quarter = try render(sketch(0.25))
        #expect(quarter.at(70, 29) == .red && quarter.at(120, 29) == .white && quarter.at(96, 79) == .white)
        let none = try render(sketch(0))
        #expect(none.at(70, 29) == .white)
    }

    @Test func keystrokeDrawsAKeyCapWithText() throws {
        var c = CalloutContent(kind: "MacKey", shape: "", size: CGSize(width: 128, height: 64), text: "A",
                               fontSize: 28.8, textColor: CalloutKinds.keyColors(1).text)
        c.keyStyle = 1
        let img = try render(c)
        let cap = CalloutKinds.keyColors(1).cap
        #expect(img.at(40, 54).near(Px(r: Int((cap.r * 255).rounded()), g: Int((cap.g * 255).rounded()),
                                       b: Int((cap.b * 255).rounded()), a: 255), 3))
        #expect(img.at(20, 54) == .white)
        // Some light text pixels in the middle of the dark key.
        var light = 0
        for x in 86...106 { for y in 44...64 where img.at(x, y).r > 150 { light += 1 } }
        #expect(light > 5)
        c.showKeyBackground = false
        #expect(try render(c).at(40, 54) == .white)
    }

    @Test func highlighterRoundedAndInverted() throws {
        var c = CalloutContent(kind: "TypeWinHighlighter", shape: "", size: CGSize(width: 100, height: 60),
                               fill: RGBA(1, 0, 1, 0.5), cornerRadius: 12)
        let img = try render(c)
        #expect(img.at(96, 54).near(Px(r: 255, g: 128, b: 255, a: 255), 2))
        #expect(img.at(47, 25) == .white)                     // rounded corner
        c.invert = true
        let inv = try render(c)
        #expect(inv.at(96, 54) == .white)                     // inside the box: untouched
        #expect(inv.at(20, 10).near(Px(r: 255, g: 128, b: 255, a: 255), 2))
    }
}
