import CoreGraphics
import Foundation
import MediaEngine
import Metal
import Testing
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

    @Test func roundCornerFlagsAndCanvasUnits() throws {
        let (rq, fr) = solid("w", .white)
        // Only top-left rounded; the layer is drawn at 2× so 20 canvas px = 10 layer px.
        let e = fx("RoundCorners", ["radius": 20, "top-right": 0, "bottom-left": 0, "bottom-right": 0])
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
        let m = fx("Mask", ["mask-shape": 0, "mask-opacity": 0, "mask-width": 40, "mask-height": 20,
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

    @Test func maskThenRoundCornersMakesACircle() throws {
        // The demo camera: square mask + large radius → circle [inf from the ProjectThumbnail].
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
            cb.commit(); cb.waitUntilCompleted()
            idle.append(comp.idleTextureCount)
        }
        #expect(idle[0] > 0)
        #expect(idle.last == idle[1])   // steady state: no growth
    }

    /// 1080p, 8 full-HD-quarter layers each with RoundCorners + DropShadow (blur 25) + Mask.
    @Test func perf1080pEightLayersWithEffects() throws {
        let (rq, fr) = solid("w", .white)
        let canvas = CGSize(width: 1920, height: 1080)
        let layers = (0..<8).map { i in
            Layer(clipID: Int64(i), content: .video(rq), size: CGSize(width: 960, height: 540),
                  transform: CGAffineTransform(translationX: Double(i % 4) * 300 - 450, y: Double(i / 4) * 300 - 150),
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
