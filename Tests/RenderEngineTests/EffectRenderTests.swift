import CoreGraphics
import Foundation
import MediaEngine
import Metal
import Testing
import WizRecTestSupport
@testable import RenderEngine

private let canvas = CGSize(width: 192, height: 108)

private func plan(_ layers: [Layer], bg: RGBA = RGBA(0, 0, 0)) -> RenderPlan {
    RenderPlan(time: 0, canvasSize: canvas, background: bg, layers: layers)
}

private func solid(_ name: String, _ c: Px) -> (FrameRequest, VideoFrame) {
    (GPUTest.request(name), GPUTest.frame(GPUTest.pixelBuffer(16, 16) { _, _ in c }))
}

private func fx(_ name: String, _ p: [String: Double], bypassed: Bool = false) -> EffectInstance {
    EffectInstance(name: name, parameters: p, bypassed: bypassed)
}

/// A 100×60 layer centred on the canvas: target x 46…146, y 24…84.
private func box(_ rq: FrameRequest, effects: [EffectInstance], transform: CGAffineTransform = .identity,
                 size: CGSize = CGSize(width: 100, height: 60)) -> Layer {
    Layer(clipID: 1, content: .video(rq), size: size, transform: transform, effects: effects)
}

@Suite(.enabled(if: hasGPU)) struct EffectRenderTests {
    @Test func registryNamesTheDrawnEffects() {
        #expect(Compositor.renderedEffects.isSuperset(of: ["RoundCorners", "DropShadow", "Mask"]))
        #expect(!Compositor.renderedEffects.contains("CursorPhysics"))
    }

    @Test func roundCornersClearTheCorners() throws {
        let (rq, fr) = solid("w", .white)
        let img = try GPUTest.render(plan([box(rq, effects: [fx("RoundCorners", ["radius": 20])])]), frames: [rq: fr])
        #expect(img.at(47, 25) == .black)      // inside the corner's cut
        #expect(img.at(96, 54) == .white)
        #expect(img.at(96, 25) == .white)      // top edge, mid
        #expect(img.at(47, 54) == .white)      // left edge, mid
        #expect(img.at(53, 31).near(.white, 3)) // inside the arc
    }

    @Test func roundCornerFlagsAndLayerUnits() throws {
        let (rq, fr) = solid("w", .white)
        // Only top-left rounded; radius in layer px: 10 at 2× = 20 canvas px.
        let e = fx("RoundCorners", ["radius": 10, "top-right": 0, "bottom-left": 0, "bottom-right": 0])
        let l = box(rq, effects: [e], transform: CGAffineTransform(scaleX: 2, y: 2), size: CGSize(width: 50, height: 30))
        let img = try GPUTest.render(plan([l]), frames: [rq: fr])
        #expect(img.at(47, 25) == .black)
        #expect(img.at(145, 25) == .white && img.at(47, 83) == .white && img.at(145, 83) == .white)
        #expect(img.at(53, 31).near(.white, 3))
    }

    @Test func bypassedAndUnknownEffectsPassThrough() throws {
        let (rq, fr) = solid("r", .red)
        let l = box(rq, effects: [fx("RoundCorners", ["radius": 20], bypassed: true), fx("SomethingNew", ["x": 1])])
        let img = try GPUTest.render(plan([l]), frames: [rq: fr])
        #expect(img.at(47, 25) == .red && img.at(96, 54) == .red && img.at(40, 54) == .black)
    }

    @Test func maskKeepsTheBoxAndHidesTheRest() throws {
        let (rq, fr) = solid("w", .white)
        // 40×20 box at layer (+20, +10): target x 96…136, y 34…54 (y up → up on screen).
        let m = fx("Mask", ["mask-shape": 1, "mask-opacity": 0, "mask-width": 40, "mask-height": 20,
                            "mask-positionX": 20, "mask-positionY": 10])
        let img = try GPUTest.render(plan([box(rq, effects: [m])]), frames: [rq: fr])
        #expect(img.at(116, 44) == .white)
        #expect(img.at(60, 44) == .black && img.at(116, 70) == .black)
        // Partial outside opacity.
        let half = fx("Mask", ["mask-opacity": 0.5, "mask-width": 40, "mask-height": 20])
        let img2 = try GPUTest.render(plan([box(rq, effects: [half])]), frames: [rq: fr])
        #expect(img2.at(96, 54) == .white)
        #expect(img2.at(60, 30).near(Px(r: 128, g: 128, b: 128, a: 255), 2))
    }

    @Test func roundCornersThenEllipseMaskMakesACircle() throws {
        // The demo camera: RoundCorners then a square ellipse mask (shape 0) → circle [Mask.md].
        let (rq, fr) = solid("w", .white)
        let l = box(rq, effects: [fx("RoundCorners", ["radius": 500]),
                                  fx("Mask", ["mask-width": 60, "mask-height": 60])])
        let img = try GPUTest.render(plan([l]), frames: [rq: fr])
        #expect(img.at(96, 54) == .white)
        #expect(img.at(96, 25) == .white && img.at(67, 54) == .white)     // edges of the circle
        #expect(img.at(70, 28) == .black)                                   // square corner, outside the circle
    }

    @Test func dropShadowFallsBelowTheLayer() throws {
        let (rq, fr) = solid("r", .red)
        let e = fx("DropShadow", ["angle": 3 * .pi / 2, "offset": 10, "blur": 0, "opacity": 1,
                                  "color-red": 0, "color-green": 0, "color-blue": 0, "color-alpha": 1])
        let img = try GPUTest.render(plan([box(rq, effects: [e])], bg: RGBA(1, 1, 1)), frames: [rq: fr])
        #expect(img.at(96, 54) == .red)
        #expect(img.at(96, 89) == .black)        // below the bottom edge (84)
        #expect(img.at(96, 20) == .white)        // above: no shadow
        #expect(img.at(96, 95) == .white)        // past the offset
        // Soft shadow: blurred edge is between white and black.
        let soft = fx("DropShadow", ["angle": 3 * .pi / 2, "offset": 10, "blur": 8, "opacity": 1])
        let img2 = try GPUTest.render(plan([box(rq, effects: [soft])], bg: RGBA(1, 1, 1)), frames: [rq: fr])
        let edge = img2.at(96, 94)
        #expect(edge.r > 20 && edge.r < 235)
        #expect(img2.at(96, 54) == .red)
        // `enabled` 0 draws nothing.
        var off = e; off.parameters["enabled"] = 0
        let img3 = try GPUTest.render(plan([box(rq, effects: [off])], bg: RGBA(1, 1, 1)), frames: [rq: fr])
        #expect(img3.at(96, 89) == .white)
    }

    // MARK: Catalog names and defaults (docs/specs/effects/catalog.md, Border.md, Reflection.md)

    @Test func borderAndReflectionAreRendered() {
        #expect(Compositor.renderedEffects.isSuperset(of: ["Border", "Reflection"]))
    }

    @Test func borderDrawsOutsideTheLayer() throws {
        let (rq, fr) = solid("r", .red)
        let e = fx("Border", ["enabled": 1, "color-red": 0, "color-green": 0, "color-blue": 1, "color-alpha": 1,
                              "width": 4, "type": 0])
        let img = try GPUTest.render(plan([box(rq, effects: [e])]), frames: [rq: fr])
        #expect(img.at(96, 54) == .red)                     // the layer stays on top
        #expect(img.at(96, 86) == Px(r: 0, g: 0, b: 255, a: 255) && img.at(44, 54) == Px(r: 0, g: 0, b: 255, a: 255))
        #expect(img.at(149, 87) == Px(r: 0, g: 0, b: 255, a: 255)) // square outside corner
        #expect(img.at(96, 90) == .black && img.at(38, 54) == .black)
        // Width in canvas px: the same border on a 2× layer is still 4 px wide.
        let l2 = box(rq, effects: [e], transform: CGAffineTransform(scaleX: 2, y: 2), size: CGSize(width: 50, height: 30))
        let img2 = try GPUTest.render(plan([l2]), frames: [rq: fr])
        #expect(img2.at(96, 86) == Px(r: 0, g: 0, b: 255, a: 255) && img2.at(96, 90) == .black)
        // `enabled` 0 draws nothing.
        var off = e; off.parameters["enabled"] = 0
        #expect(try GPUTest.render(plan([box(rq, effects: [off])]), frames: [rq: fr]).at(96, 86) == .black)
    }

    @Test func borderDefaultsToOnePixelOpaqueWhite() throws {
        let (rq, fr) = solid("r", .red)
        let img = try GPUTest.render(plan([box(rq, effects: [fx("Border", [:])])]), frames: [rq: fr])
        #expect(img.at(96, 84) == .white && img.at(45, 54) == .white)
        #expect(img.at(96, 86) == .black)
    }

    @Test func reflectionMirrorsBelowAndFades() throws {
        // Top half green, bottom half red: the reflection starts with red (mirrored bottom edge).
        let rq = GPUTest.request("gr")
        let fr = GPUTest.frame(GPUTest.pixelBuffer(16, 16) { _, y in y < 8 ? .green : .red })
        let e = fx("Reflection", ["distance": 10, "opacity": 1])
        let img = try GPUTest.render(plan([box(rq, effects: [e])]), frames: [rq: fr])
        #expect(img.at(96, 30) == .green && img.at(96, 80) == .red)
        #expect(img.at(96, 89) == .black)                  // the gap below the layer (84…94)
        let near = img.at(96, 95), far = img.at(96, 105)
        #expect(near.r > 200 && near.g < 10)               // mirrored red, almost full strength
        #expect(far.r < near.r && far.r > 100)             // fading out (fade over half the layer height)
        // Defaults: distance 20, opacity 0.4.
        let d = try GPUTest.render(plan([box(rq, effects: [fx("Reflection", [:])])]), frames: [rq: fr])
        #expect(d.at(96, 100) == .black)                    // still in the 20-px gap
        let p = d.at(96, 105)
        #expect(p.r > 80 && p.r < 105)                       // ≈ 0.4 · (1 − 1.5/30) · 255
    }

    @Test func missingKeysTakeCatalogDefaults() throws {
        #expect(BlendModeSpec.mode(fx("BlendModeEffect", [:])) == .screen)       // mode 12
        #expect(MediaMatteSpec.mode(fx("MediaMatte", [:])) == (false, false))    // matteMode 1
        let (rq, fr) = solid("w", .white)
        // RoundCorners: radius 20.
        let rc = try GPUTest.render(plan([box(rq, effects: [fx("RoundCorners", [:])])]), frames: [rq: fr])
        #expect(rc.at(47, 25) == .black && rc.at(96, 54) == .white)
        // Mask: 360×360 ellipse at the centre (layer px): a 400×400 layer at 0.25 loses its corners.
        let big = box(rq, effects: [fx("Mask", [:])], transform: CGAffineTransform(scaleX: 0.25, y: 0.25),
                      size: CGSize(width: 400, height: 400))
        let m = try GPUTest.render(plan([big]), frames: [rq: fr])
        #expect(m.at(96, 54) == .white && m.at(96, 12) == .white)
        #expect(m.at(48, 6) == .black && m.at(144, 54) == .black)
        // DropShadow: 10 px down-right, blur 10, opacity 0.4, dark grey.
        let (rr, fred) = solid("r", .red)
        let s = try GPUTest.render(plan([box(rr, effects: [fx("DropShadow", [:])])], bg: RGBA(1, 1, 1)), frames: [rr: fred])
        let below = s.at(110, 89), above = s.at(80, 19)
        #expect(below.r < 235 && below.r > 120)
        #expect(above.r > 250)
    }

    @Test func colorAdjustmentSaturationZeroIsNeutral() throws {
        let (rq, fr) = solid("r", .red)
        let img = try GPUTest.render(plan([box(rq, effects: [fx("ColorAdjustment", ["saturation": 0])])]),
                                     frames: [rq: fr])
        #expect(img.at(96, 54) == .red)
        let grey = try GPUTest.render(plan([box(rq, effects: [fx("ColorAdjustment", ["saturation": -1])])]),
                                      frames: [rq: fr])
        let p = grey.at(96, 54)
        #expect(p.r == p.g && p.g == p.b && p.r > 20)
    }

    @Test func layerOpacityAppliesAfterEffects() throws {
        let (rq, fr) = solid("w", .white)
        var l = box(rq, effects: [fx("RoundCorners", ["radius": 20])])
        l.opacity = 0.5
        let img = try GPUTest.render(plan([l]), frames: [rq: fr])
        #expect(img.at(96, 54).near(Px(r: 128, g: 128, b: 128, a: 255), 2))
        #expect(img.at(47, 25) == .black)
    }

    @Test func fadeTransitionMixesBothSides() throws {
        let (ra, fa) = solid("a", .red), (rb, fb) = solid("b", .green)
        let a = Layer(clipID: 1, content: .video(ra), size: canvas)
        let b = Layer(clipID: 2, content: .video(rb), size: canvas)
        let t = TransitionInstance(name: "Fade", progress: 0.5, duration: 10)
        let l = Layer(clipID: 2, content: .transition(t, from: a, to: b), size: canvas)
        let img = try GPUTest.render(plan([l]), frames: [ra: fa, rb: fb])
        #expect(img.at(96, 54).near(Px(r: 128, g: 128, b: 0, a: 255), 2))
        // One-sided fade-in reveals the background (transparent missing side).
        let t2 = TransitionInstance(name: "Fade", progress: 0.25, duration: 10)
        let l2 = Layer(clipID: 2, content: .transition(t2, from: nil, to: b), size: canvas)
        let img2 = try GPUTest.render(plan([l2], bg: RGBA(0, 0, 1)), frames: [rb: fb])
        #expect(img2.at(96, 54).near(Px(r: 0, g: 64, b: 191, a: 255), 2))
        // Unknown names fall back to a cross-fade.
        let t3 = TransitionInstance(name: "CubeRotate", progress: 1, duration: 10)
        let img3 = try GPUTest.render(plan([Layer(clipID: 2, content: .transition(t3, from: a, to: b), size: canvas)]),
                                      frames: [ra: fa, rb: fb])
        #expect(img3.at(96, 54) == .green)
    }

    @Test func fadeThroughBlackIsBlackAtHalfway() throws {
        let (ra, fa) = solid("a", .red), (rb, fb) = solid("b", .green)
        let a = Layer(clipID: 1, content: .video(ra), size: canvas)
        let b = Layer(clipID: 2, content: .video(rb), size: canvas)
        let t = TransitionInstance(name: "FadeThroughBlack", progress: 0.5, duration: 10)
        let img = try GPUTest.render(plan([Layer(clipID: 2, content: .transition(t, from: a, to: b), size: canvas)],
                                          bg: RGBA(1, 1, 1)), frames: [ra: fa, rb: fb])
        #expect(img.at(96, 54).near(.black, 2))
        // The colour comes from `Color-red/-green/-blue` (TR2): through blue; a quarter in = half red, half blue.
        let blue = TransitionInstance(name: "FadeThroughBlack", progress: 0.5, duration: 10,
                                      parameters: ["Color-red": 0, "Color-green": 0, "Color-blue": 1])
        let img2 = try GPUTest.render(plan([Layer(clipID: 2, content: .transition(blue, from: a, to: b), size: canvas)]),
                                      frames: [ra: fa, rb: fb])
        #expect(img2.at(96, 54).near(Px(r: 0, g: 0, b: 255, a: 255), 2))
        var quarter = blue; quarter.progress = 0.25
        let img3 = try GPUTest.render(plan([Layer(clipID: 2, content: .transition(quarter, from: a, to: b), size: canvas)]),
                                      frames: [ra: fa, rb: fb])
        #expect(img3.at(96, 54).near(Px(r: 128, g: 0, b: 128, a: 255), 2))
    }

    @Test func pooledTexturesAreRecycled() throws {
        let device = try #require(gpu)
        let comp = try Compositor(device: device)
        let queue = try #require(device.makeCommandQueue())
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 192, height: 108,
                                                         mipmapped: false)
        d.usage = [.renderTarget]
        let target = try #require(device.makeTexture(descriptor: d))
        let (rq, fr) = solid("w", .white)
        let p = plan([box(rq, effects: [fx("RoundCorners", ["radius": 10]), fx("DropShadow", ["offset": 4, "blur": 4])])])
        var idle: [Int] = []
        for _ in 0..<6 {
            let cb = try #require(queue.makeCommandBuffer())
            try comp.encode(p, frames: [rq: fr], into: target, commandBuffer: cb)
            try GPUWait.commitAndWait(cb, "effect render")
            idle.append(comp.idleTextureCount)
        }
        #expect(idle[0] > 0)
        #expect(idle.last == idle[1])   // steady state: no growth
    }

    /// 1080p, 8 full-HD-quarter layers each with RoundCorners + DropShadow (blur 25) + Mask.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIZREC_PERF"] == "1", "timing: set WIZREC_PERF=1"))
    func perf1080pEightLayersWithEffects() throws {
        let (rq, fr) = solid("w", .white)
        let canvas = CGSize(width: 1920, height: 1080)
        let layers: [Layer] = (0..<8).map { (i: Int) -> Layer in
            let tx: Double = Double(i % 4) * 300 - 450, ty: Double = Double(i / 4) * 300 - 150
            return Layer(clipID: Int64(i), content: .video(rq), size: CGSize(width: 960, height: 540),
                  transform: CGAffineTransform(translationX: tx, y: ty),
                  effects: [fx("Mask", ["mask-width": 800, "mask-height": 450]), fx("RoundCorners", ["radius": 40]),
                            fx("DropShadow", ["angle": 4.71, "offset": 15, "blur": 25, "opacity": 0.3])])
        }
        let p = RenderPlan(time: 0, canvasSize: canvas, background: RGBA(0, 0, 0), layers: layers)
        _ = try GPUTest.render(p, frames: [rq: fr], 1920, 1080)
        var best = Double.infinity
        for _ in 0..<5 {
            var t = 0.0
            _ = try GPUTest.render(p, frames: [rq: fr], 1920, 1080, gpuTime: &t)
            best = min(best, t)
        }
        print("composite 1080p × 8 layers with 3 effects each: \(String(format: "%.3f", best * 1000)) ms GPU")
        #expect(best < 1.0 / 60)
    }
}
