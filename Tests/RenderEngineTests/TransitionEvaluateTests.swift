import CoreGraphics
import CoreMedia
import Foundation
import MediaEngine
import Testing
import TSCProjKit
@testable import RenderEngine

private let s = P.rate

private func transition(_ name: String = "Fade", duration: Int64, left: Int? = nil, right: Int? = nil,
                        bypass: Bool = false) -> [String: Any] {
    var t: [String: Any] = ["name": name, "duration": duration, "trivial": false, "reverse": false,
                            "bypass": bypass, "useAudioPreRoll": true, "useVisualPreRoll": true]
    if let left { t["leftMedia"] = left }
    if let right { t["rightMedia"] = right }
    return t
}

/// Two 4-s clips cut at 4 s on track 0, with `transitions`.
private func cutProject(_ transitions: [[String: Any]]) throws -> SceneModel {
    let a = P.clip("VMFile", id: 10, src: 1, start: 0, duration: 4 * s, mediaStart: 1 * s)
    let b = P.clip("VMFile", id: 11, src: 1, start: 4 * s, duration: 4 * s, mediaStart: 20 * s)
    return P.scene(try P.project(tracks: [P.track(0, [a, b], extra: ["transitions": transitions])]))
}

private func transitionParts(_ l: Layer?) -> (TransitionInstance, Layer?, Layer?)? {
    guard let l, case .transition(let t, let from, let to) = l.content else { return nil }
    return (t, from, to)
}

@Suite struct TransitionEvaluateTests {
    @Test func betweenClipsIsCentredOnTheCut() throws {
        let scene = try cutProject([transition(duration: 2 * s, left: 10, right: 11)])
        // Window [3 s, 5 s).
        #expect(transitionParts(scene.evaluate(at: 3 * s - 1).layers.first) == nil)
        let (t, from, to) = try #require(transitionParts(scene.evaluate(at: 4 * s).layers.first))
        #expect(t.name == "Fade" && t.duration == 2 * s)
        #expect(approx(t.progress, 0.5))
        #expect(from?.clipID == 10 && to?.clipID == 11)
        // Outgoing post-rolls past its end (media 1 s + 4 s), incoming pre-rolls before its start.
        guard case .video(let ra)? = from?.content, case .video(let rb)? = to?.content else {
            Issue.record("not video"); return
        }
        #expect(ra.time == CMTime(value: 5 * s, timescale: Int32(s)))
        #expect(rb.time == CMTime(value: 20 * s, timescale: Int32(s)))
        let early = try #require(transitionParts(scene.evaluate(at: 3 * s).layers.first))
        #expect(approx(early.0.progress, 0))
        guard case .video(let rb2)? = early.2?.content else { Issue.record("no incoming"); return }
        #expect(rb2.time == CMTime(value: 19 * s, timescale: Int32(s)))
        #expect(transitionParts(scene.evaluate(at: 5 * s).layers.first) == nil)
        #expect(scene.evaluate(at: 5 * s).layers.first?.clipID == 11)
        // Both sides' frames are requested.
        #expect(scene.evaluate(at: 4 * s).frameRequests.count == 2)
    }

    @Test func oneSidedWindows() throws {
        let scene = try cutProject([transition(duration: 1 * s, right: 10), transition(duration: 1 * s, left: 11)])
        // Fade in on clip 10: [0, 1 s).
        let fin = try #require(transitionParts(scene.evaluate(at: s / 4).layers.first))
        #expect(fin.1 == nil && fin.2?.clipID == 10 && approx(fin.0.progress, 0.25))
        #expect(transitionParts(scene.evaluate(at: s).layers.first) == nil)
        // Fade out on clip 11: [7 s, 8 s).
        let fout = try #require(transitionParts(scene.evaluate(at: 7 * s + s / 2).layers.first))
        #expect(fout.1?.clipID == 11 && fout.2 == nil && approx(fout.0.progress, 0.5))
        // Past the clip's end, nothing.
        #expect(scene.evaluate(at: 8 * s).layers.isEmpty)
    }

    @Test func bypassedOrDanglingTransitionsAreIgnored() throws {
        let scene = try cutProject([transition(duration: 2 * s, left: 10, right: 11, bypass: true),
                                    transition(duration: 2 * s, left: 99)])
        #expect(scene.evaluate(at: 4 * s).layers.first?.clipID == 11)
        #expect(transitionParts(scene.evaluate(at: 4 * s).layers.first) == nil)
    }

    @Test func transitionLayerHasParentSize() throws {
        let scene = try cutProject([transition(duration: 2 * s, left: 10, right: 11)])
        let l = try #require(scene.evaluate(at: 4 * s).layers.first)
        #expect(l.size == CGSize(width: 1920, height: 1080) && l.transform == .identity)
    }

    @Test func effectWindowsGateEffects() throws {
        let c = P.clip("VMFile", id: 10, src: 1, start: 0, duration: 4 * s, mediaStart: 1 * s, effects: [
            ["effectName": "RoundCorners", "bypassed": false, "parameters": ["radius": 10.0]],
            ["effectName": "DropShadow", "bypassed": false, "start": 2 * s, "duration": s,
             "parameters": ["offset": 5.0]],
        ])
        let scene = P.scene(try P.project(tracks: [P.track(0, [c])]))
        // Effect time is on the keyframe (media) axis: media = 1 s + t.
        #expect(scene.evaluate(at: 0).layers[0].effects.map(\.name) == ["RoundCorners"])
        #expect(scene.evaluate(at: s).layers[0].effects.map(\.name) == ["RoundCorners", "DropShadow"])
        #expect(scene.evaluate(at: 2 * s).layers[0].effects.map(\.name) == ["RoundCorners"])
    }

    @Test func shaderTimeIsMediaSeconds() throws {
        let c = P.clip("VMFile", id: 50, src: 3, start: 2 * s, duration: 10 * s, mediaStart: 3 * s)
        let scene = P.scene(try P.project(tracks: [P.track(0, [c])]))
        guard case .shader(_, _, let time) = scene.evaluate(at: 4 * s).layers[0].content else {
            Issue.record("not shader"); return
        }
        #expect(approx(time, 5))
    }
}
