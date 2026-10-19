import CoreGraphics
import Foundation
import MediaEngine
import Testing
@testable import RenderEngine

private let canvas = CGSize(width: 192, height: 108)

private func plan(_ layers: [Layer], bg: RGBA = RGBA(0, 0, 0)) -> RenderPlan {
    RenderPlan(time: 0, canvasSize: canvas, background: bg, layers: layers)
}

private func solid(_ name: String, _ c: Px) -> (FrameRequest, VideoFrame) {
    (GPUTest.request(name), GPUTest.frame(GPUTest.pixelBuffer(16, 16) { _, _ in c }))
}

private func full(_ rq: FrameRequest, _ id: Int64, effects: [EffectInstance] = [], size: CGSize = canvas,
                  x: Double = 0) -> Layer {
    Layer(clipID: id, content: .video(rq), size: size, transform: CGAffineTransform(translationX: x, y: 0),
          effects: effects)
}

@Suite(.enabled(if: hasGPU)) struct CompositingEffectTests {
    @Test func blendModeScreenOverRed() throws {
        let (r, fr) = solid("r", .red), (g, fg) = solid("g", .green)
        let screen = EffectInstance(name: "BlendModeEffect", parameters: ["mode": 12, "intensity": 1], bypassed: false)
        let img = try GPUTest.render(plan([full(r, 1), full(g, 2, effects: [screen])]), frames: [r: fr, g: fg])
        #expect(img.at(96, 54).near(Px(r: 255, g: 255, b: 0, a: 255), 2))
        // intensity 0 and unknown modes composite normally.
        var off = screen; off.parameters["intensity"] = 0
        #expect(try GPUTest.render(plan([full(r, 1), full(g, 2, effects: [off])]), frames: [r: fr, g: fg]).at(96, 54) == .green)
        var unknown = screen; unknown.parameters["mode"] = 99
        #expect(try GPUTest.render(plan([full(r, 1), full(g, 2, effects: [unknown])]), frames: [r: fr, g: fg]).at(96, 54) == .green)
    }

    @Test func blendSeesTheBackgroundAndKeepsLaterLayers() throws {
        let (g, fg) = solid("g", .green), (b, fb) = solid("b", .blue)
        let screen = EffectInstance(name: "BlendModeEffect", parameters: ["mode": 12], bypassed: false)
        // Green screened over a red background → yellow; a blue layer on top stays blue.
        let top = Layer(clipID: 3, content: .video(b), size: CGSize(width: 20, height: 20))
        let img = try GPUTest.render(plan([full(g, 2, effects: [screen]), top], bg: RGBA(1, 0, 0)), frames: [g: fg, b: fb])
        #expect(img.at(20, 20).near(Px(r: 255, g: 255, b: 0, a: 255), 2))
        #expect(img.at(96, 54) == .blue)
    }

    @Test func mediaMatteMasksTheTrackBelow() throws {
        let (r, fr) = solid("r", .red), (g, fg) = solid("g", .green), (w, fw) = solid("w", .white)
        // Matte: white, left half of the canvas.
        let matte = Layer(clipID: 3, content: .video(w), size: CGSize(width: 96, height: 108),
                          transform: CGAffineTransform(translationX: -48, y: 0),
                          effects: [EffectInstance(name: "MediaMatte", parameters: ["matteMode": 1, "intensity": 1],
                                                   bypassed: false)])
        let img = try GPUTest.render(plan([full(r, 1), full(g, 2), matte]), frames: [r: fr, g: fg, w: fw])
        #expect(img.at(40, 54) == .green)   // inside the matte: content kept
        #expect(img.at(150, 54) == .red)    // outside: content removed, the track two below shows
        // Inverted alpha flips it.
        var inv = matte
        inv.effects[0].parameters["matteMode"] = 2
        let img2 = try GPUTest.render(plan([full(r, 1), full(g, 2), inv]), frames: [r: fr, g: fg, w: fw])
        #expect(img2.at(40, 54) == .red && img2.at(150, 54) == .green)
        // A matte with nothing below draws nothing.
        let img3 = try GPUTest.render(plan([matte]), frames: [w: fw])
        #expect(img3.at(40, 54) == .black)
    }

    @Test func regionCalloutsWorkOnThePixelsBelow() throws {
        // Vertical 1-px stripes, black/white.
        let stripes = GPUTest.request("stripes")
        let fs = GPUTest.frame(GPUTest.pixelBuffer(192, 108) { x, _ in x % 2 == 0 ? .black : .white })
        let base = Layer(clipID: 1, content: .video(stripes), size: canvas)
        func region(_ kind: String, intensity: Double = 1) -> Layer {
            let c = CalloutContent(kind: kind, shape: "", size: CGSize(width: 80, height: 40), intensity: intensity)
            return Layer(clipID: 2, content: .callout(c), size: c.size)
        }
        let blurred = try GPUTest.render(plan([base, region("TypeWinBlur")]), frames: [stripes: fs])
        let inside = blurred.at(96, 54), outside = blurred.at(20, 54)
        #expect(inside.r > 90 && inside.r < 165)            // stripes averaged to grey
        #expect(outside == .black || outside == .white)     // untouched outside the box

        let pix = try GPUTest.render(plan([base, region("TypeWinPixelate", intensity: 0.2)]), frames: [stripes: fs])
        // 12-px blocks: neighbouring pixels in one block are equal.
        let block = 12
        let x0 = (96 / block) * block
        #expect(pix.at(x0 + 2, 54) == pix.at(x0 + 3, 54))

        let white = solid("w", .white)
        let spot = try GPUTest.render(plan([full(white.0, 1), region("TypeWinSpotlight", intensity: 0.5)]),
                                      frames: [white.0: white.1])
        #expect(spot.at(96, 54) == .white)
        #expect(spot.at(10, 10).near(Px(r: 128, g: 128, b: 128, a: 255), 2))
    }
}
