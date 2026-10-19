import Foundation
import Testing
import TSCProjKit
@testable import RenderEngine

private let s = P.rate

@Suite struct BehaviorTests {
    private func behavior(in inName: String, out outName: String, window: (Int64, Int64)? = nil) -> [String: Any] {
        func phase(_ n: String) -> [String: Any] { ["attributes": ["name": n, "type": 0, "springDamping": 5.0]] }
        var b: [String: Any] = ["_type": "GenericBehaviorEffect", "effectName": "flyIn", "bypassed": false,
                                "in": phase(inName), "center": phase("none"), "out": phase(outName)]
        if let window { b["start"] = window.0; b["duration"] = window.1 }
        return b
    }

    @Test func behaviorFadesItsInAndOutPhases() throws {
        let c = P.clip("VMFile", id: 10, src: 1, start: 0, duration: 4 * s,
                       effects: [behavior(in: "flyIn", out: "flyOut"),
                                 ["effectName": "RoundCorners", "bypassed": false, "parameters": ["radius": 4.0]]])
        let scene = P.scene(try P.project(tracks: [P.track(0, [c])]))
        let phase = Int64(Conventions.behaviorPhaseSeconds * Double(s))
        #expect(approx(scene.evaluate(at: 0).layers[0].opacity, 0))
        #expect(approx(scene.evaluate(at: phase / 2).layers[0].opacity, 0.5))
        #expect(approx(scene.evaluate(at: 2 * s).layers[0].opacity, 1))
        #expect(approx(scene.evaluate(at: 4 * s - phase / 4).layers[0].opacity, 0.25))
        // The behaviour is not a visual effect.
        #expect(scene.evaluate(at: 2 * s).layers[0].effects.map(\.name) == ["RoundCorners"])
    }

    @Test func phaseNamedNoneDoesNothing() throws {
        let c = P.clip("VMFile", id: 10, src: 1, start: 0, duration: 4 * s,
                       effects: [behavior(in: "none", out: "flyOut", window: (0, 2 * s))])
        let scene = P.scene(try P.project(tracks: [P.track(0, [c])]))
        #expect(approx(scene.evaluate(at: 0).layers[0].opacity, 1))
        #expect(scene.evaluate(at: 2 * s - 1).layers[0].opacity < 0.01)   // window ends at 2 s
        #expect(approx(scene.evaluate(at: 3 * s).layers[0].opacity, 1))   // outside the window
    }

    @Test func edgeRampsFadeTheNamedParameter() throws {
        let mods: (String, String) -> [[String: Any]] = { _, fn in
            [["group": "Video", "duration": s, "parameters": [["name": "intensity", "func": fn]]]]
        }
        let blend: [String: Any] = ["effectName": "BlendModeEffect", "bypassed": false,
                                    "parameters": ["mode": 12, "intensity": 1.0],
                                    "leftEdgeMods": mods("l", "FadeInFunc"), "rightEdgeMods": mods("r", "FadeOutFunc")]
        let c = P.clip("VMFile", id: 10, src: 1, start: 0, duration: 4 * s, effects: [blend])
        let scene = P.scene(try P.project(tracks: [P.track(0, [c])]))
        func intensity(_ t: Int64) -> Double { scene.evaluate(at: t).layers[0].effects[0].parameters["intensity"] ?? -1 }
        #expect(approx(intensity(0), 0))
        #expect(approx(intensity(s / 2), 0.5))
        #expect(approx(intensity(2 * s), 1))
        #expect(approx(intensity(4 * s - s / 4), 0.25))
        // Duration 0 (all observed files) means no ramp.
        var flat = blend
        flat["leftEdgeMods"] = [["group": "Video", "duration": 0, "parameters": [["name": "intensity", "func": "FadeInFunc"]]]]
        flat["rightEdgeMods"] = nil
        let c2 = P.clip("VMFile", id: 10, src: 1, start: 0, duration: 4 * s, effects: [flat])
        let scene2 = P.scene(try P.project(tracks: [P.track(0, [c2])]))
        #expect(scene2.evaluate(at: 0).layers[0].effects[0].parameters["intensity"] == 1)
    }
}
