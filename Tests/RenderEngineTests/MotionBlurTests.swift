import CoreGraphics
import Foundation
import MediaEngine
import Testing
import TSCProjKit
@testable import RenderEngine

private let s = P.rate

@Suite struct MotionBlurEvaluateTests {
    private func scene(effects: [[String: Any]], animated: Bool = true) throws -> SceneModel {
        let tx: Any = animated ? P.keyframed(-600, [(time: 0, end: s, value: 600)], interp: "linr") : 0.0
        let c = P.clip("VMFile", id: 10, src: 1, start: 0, duration: 2 * s,
                       parameters: ["translation0": tx], effects: effects)
        return P.scene(try P.project(tracks: [P.track(0, [c])]))
    }

    private let blur: [String: Any] = ["effectName": "MotionBlur", "bypassed": false, "parameters": ["intensity": 1.0]]

    @Test func samplesSpanOneFrameCentredOnTheTime() throws {
        let l = try scene(effects: [blur]).evaluate(at: s / 2).layers[0]
        // 1200 px/s at 30 fps = 40 px per frame → ±20 px around tx = 0.
        #expect(l.motion.count >= 2)
        #expect(approx(Double(l.motion.first?.tx ?? 0), -20, 1e-6) && approx(Double(l.motion.last?.tx ?? 0), 20, 1e-6))
        #expect(approx(l.transform.tx, 0, 1e-6))
    }

    @Test func noMotionWithoutAnimationOrEffect() throws {
        #expect(try scene(effects: [blur], animated: false).evaluate(at: s / 2).layers[0].motion.isEmpty)
        #expect(try scene(effects: []).evaluate(at: s / 2).layers[0].motion.isEmpty)
        var off = blur; off["bypassed"] = true
        #expect(try scene(effects: [off]).evaluate(at: s / 2).layers[0].motion.isEmpty)
        // Past the animation the transform is static.
        #expect(try scene(effects: [blur]).evaluate(at: s + s / 2).layers[0].motion.isEmpty)
    }
}

@Suite(.enabled(if: hasGPU)) struct MotionBlurRenderTests {
    @Test func samplesAreAveraged() throws {
        let rq = GPUTest.request("w")
        let fr = GPUTest.frame(GPUTest.pixelBuffer(16, 16) { _, _ in .white })
        // A 20-px square at 9 offsets −20…20: pixel centre x = 0.5 is covered by 4 samples, 25.5 by 1, 35.5 by none.
        let motion = (0..<9).map { CGAffineTransform(translationX: -20 + Double($0) * 5, y: 0) }
        let l = Layer(clipID: 1, content: .video(rq), size: CGSize(width: 20, height: 20), motion: motion)
        let plan = RenderPlan(time: 0, canvasSize: CGSize(width: 192, height: 108), background: RGBA(0, 0, 0), layers: [l])
        let img = try GPUTest.render(plan, frames: [rq: fr])
        #expect(abs(img.at(96, 54).r - 113) <= 3)
        #expect(abs(img.at(96 + 25, 54).r - 28) <= 3)
        #expect(img.at(96 + 35, 54).r < 5)                // beyond the smear
    }
}
