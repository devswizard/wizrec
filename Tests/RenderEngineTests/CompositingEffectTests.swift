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

    // MARK: Mode numbers (BlendModeEffect.md table) and MediaMatte trackDepth

    @Test func blendModeNumbersFollowTheSpecTable() {
        func mode(_ n: Double) -> BlendModeSpec.Mode { BlendModeSpec.mode(EffectInstance(name: "BlendModeEffect", parameters: ["mode": n], bypassed: false)) }
        #expect(mode(0) == .normal && mode(5) == .dissolve && mode(7) == .multiply && mode(12) == .screen)
        #expect(mode(14) == .linearDodge && mode(16) == .overlay && mode(23) == .difference && mode(30) == .luminosity)
        #expect(mode(1).stencil! == (false, false) && mode(4).stencil! == (true, true) && mode(12).stencil == nil)
        #expect(mode(31) == .normal && mode(-1) == .normal)
        #expect(BlendModeSpec.Mode.allCases.count == 31)
    }

    /// Blend of a source colour over a backdrop colour, full intensity: the resulting pixel.
    private func blended(_ mode: Int, source: Px, backdrop: RGBA) throws -> Px {
        let (s, fs) = solid("s\(mode)", source)
        let e = EffectInstance(name: "BlendModeEffect", parameters: ["mode": Double(mode), "intensity": 1], bypassed: false)
        return try GPUTest.render(plan([full(s, 1, effects: [e])], bg: backdrop), frames: [s: fs]).at(96, 54)
    }

    @Test func standardModeFormulas() throws {
        let grey = Px(r: 128, g: 128, b: 128, a: 255), b = RGBA(0.25, 0.5, 0.75)
        // Backdrop (64, 128, 191) against source 128 (≈ 0.502).
        #expect(try blended(7, source: grey, backdrop: b).near(Px(r: 32, g: 64, b: 96, a: 255), 2))      // multiply
        #expect(try blended(6, source: grey, backdrop: b).near(Px(r: 64, g: 128, b: 128, a: 255), 2))    // darken
        #expect(try blended(11, source: grey, backdrop: b).near(Px(r: 128, g: 128, b: 191, a: 255), 2))  // lighten
        #expect(try blended(14, source: grey, backdrop: b).near(Px(r: 192, g: 255, b: 255, a: 255), 2))  // add
        #expect(try blended(9, source: grey, backdrop: b).near(Px(r: 0, g: 0, b: 64, a: 255), 2))        // linear burn
        #expect(try blended(23, source: grey, backdrop: b).near(Px(r: 64, g: 0, b: 63, a: 255), 2))      // difference
        #expect(try blended(25, source: grey, backdrop: b).near(Px(r: 0, g: 0, b: 63, a: 255), 2))       // subtract
        #expect(try blended(22, source: grey, backdrop: b).near(Px(r: 0, g: 255, b: 255, a: 255), 1))    // hard mix
        #expect(try blended(10, source: grey, backdrop: b).near(Px(r: 64, g: 128, b: 191, a: 255), 2))   // darker colour: backdrop
        #expect(try blended(15, source: grey, backdrop: b).near(grey, 2))                                 // lighter colour: source
        #expect(try blended(20, source: grey, backdrop: b).near(Px(r: 64, g: 128, b: 192, a: 255), 2))   // linear light ≈ b
    }

    @Test func dissolveKeepsOrDropsWholePixels() throws {
        let (g, fg) = solid("g", .green)
        let e = EffectInstance(name: "BlendModeEffect", parameters: ["mode": 5, "intensity": 1], bypassed: false)
        var l = full(g, 1, effects: [e]); l.opacity = 0.5
        let img = try GPUTest.render(plan([l]), frames: [g: fg])
        var on = 0, partial = 0
        for y in stride(from: 0, to: 108, by: 3) { for x in stride(from: 0, to: 192, by: 3) {
            let p = img.at(x, y)
            if p == .green { on += 1 } else if p != Px.black { partial += 1 }
        } }
        #expect(partial == 0)
        #expect(on > 900 && on < 1400)   // ≈ half of 2304 samples
    }

    @Test func stencilAndSilhouetteModesMatteEverythingBelow() throws {
        let (r, fr) = solid("r", .red), (g, fg) = solid("g", .green), (w, fw) = solid("w", .white)
        func top(_ mode: Double) -> Layer {
            Layer(clipID: 3, content: .video(w), size: CGSize(width: 96, height: 108), transform: CGAffineTransform(translationX: -48, y: 0),
                  effects: [EffectInstance(name: "BlendModeEffect", parameters: ["mode": mode, "intensity": 1], bypassed: false)])
        }
        let half = full(g, 2, size: CGSize(width: 192, height: 54))   // green band over red
        // Stencil alpha: keep everything below where the layer is (left half), clear the rest.
        let s = try GPUTest.render(plan([full(r, 1), half, top(1)]), frames: [r: fr, g: fg, w: fw])
        #expect(s.at(40, 54) == .green && s.at(40, 10) == .red)
        #expect(s.at(150, 54) == .black && s.at(150, 10) == .black)
        // Silhouette alpha: the opposite.
        let k = try GPUTest.render(plan([full(r, 1), half, top(2)]), frames: [r: fr, g: fg, w: fw])
        #expect(k.at(40, 54) == .black && k.at(150, 54) == .green && k.at(150, 10) == .red)
    }

    @Test func matteTrackDepth() {
        func depth(_ p: [String: Double]) -> Int { MediaMatteSpec.trackDepth(EffectInstance(name: "MediaMatte", parameters: p, bypassed: false)) }
        #expect(depth([:]) == 1 && depth(["trackDepth": 2]) == 2 && depth(["trackDepth": 0]) == 1)
        #expect(depth(["trackDepth": 10002]) == Int.max)
        #expect(MediaMatteSpec.mode(EffectInstance(name: "MediaMatte", parameters: ["matteMode": 0], bypassed: false)) == (false, false))
        #expect(MediaMatteSpec.mode(EffectInstance(name: "MediaMatte", parameters: ["matteMode": 3], bypassed: false)) == (true, false))
    }

    @Test func matteWithTrackDepthMasksSeveralTracks() throws {
        let (r, fr) = solid("r", .red), (g, fg) = solid("g", .green), (w, fw) = solid("w", .white)
        let small = Layer(clipID: 2, content: .video(g), size: CGSize(width: 20, height: 20),
                          transform: CGAffineTransform(translationX: 60, y: 0))
        func matte(_ p: [String: Double]) -> Layer {
            Layer(clipID: 3, content: .video(w), size: CGSize(width: 96, height: 108), transform: CGAffineTransform(translationX: -48, y: 0),
                  effects: [EffectInstance(name: "MediaMatte", parameters: p, bypassed: false)])
        }
        // Missing: only the green square (track below) is masked; the red track still fills the right half.
        let one = try GPUTest.render(plan([full(r, 1), small, matte([:])]), frames: [r: fr, g: fg, w: fw])
        #expect(one.at(156, 54) == .red && one.at(150, 20) == .red && one.at(40, 54) == .red)
        // All below (10002): both tracks are masked; the right half is empty.
        let all = try GPUTest.render(plan([full(r, 1), small, matte(["trackDepth": 10002])]), frames: [r: fr, g: fg, w: fw])
        #expect(all.at(150, 20) == .black && all.at(156, 54) == .black && all.at(40, 54) == .red)
        // Explicit 2 = both tracks here.
        let two = try GPUTest.render(plan([full(r, 1), small, matte(["trackDepth": 2])]), frames: [r: fr, g: fg, w: fw])
        #expect(two.at(150, 20) == .black && two.at(40, 54) == .red)
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
