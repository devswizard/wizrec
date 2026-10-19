import CoreGraphics
import CoreMedia
import Foundation
import MediaEngine
import Testing
import TSCProjKit
@testable import RenderEngine

private let s = P.rate  // one second in ticks

private func videoRequest(_ l: Layer?) -> FrameRequest? {
    if case .video(let r)? = l?.content { r } else { nil }
}

private func children(_ l: Layer?) -> [Layer] {
    if case .group(let c)? = l?.content { c } else { [] }
}

// MARK: - Visibility and time mapping

@Test func clipVisibleOnHalfOpenSpan() throws {
    let p = try P.project(tracks: [P.track(0, [P.clip("VMFile", id: 10, src: 1, start: s, duration: s)])])
    let scene = P.scene(p)
    #expect(scene.evaluate(at: s - 1).layers.isEmpty)
    #expect(scene.evaluate(at: s).layers.count == 1)
    #expect(scene.evaluate(at: 2 * s - 1).layers.count == 1)
    #expect(scene.evaluate(at: 2 * s).layers.isEmpty)
    #expect(scene.duration == 2 * s)
}

@Test func leafFrameRequestUsesMediaStartAndStream() throws {
    let p = try P.project(tracks: [P.track(0, [
        P.clip("VMFile", id: 10, src: 1, trackNumber: 0, start: s, duration: 4 * s, mediaStart: 3 * s),
    ])])
    let r = try #require(videoRequest(P.scene(p).evaluate(at: s + s / 2).layers.first))
    #expect(r.url.path.hasSuffix("media/a.mp4"))
    #expect(r.stream == 0)
    #expect(r.time == CMTime(value: 3 * s + s / 2, timescale: Int32(s)))
}

@Test func scalarDividesLocalTime() throws {
    // scalar 1/2 = 2× speed: one timeline second consumes two media seconds.
    let p = try P.project(tracks: [P.track(0, [
        P.clip("VMFile", id: 10, src: 1, start: s, duration: 2 * s, mediaStart: 10, scalar: "1/2"),
    ])])
    let r = try #require(videoRequest(P.scene(p).evaluate(at: s + 100).layers.first))
    #expect(r.time.value == 10 + 200)
}

@Test func rationalMediaStartAndScalarStayExact() throws {
    // mediaStart 1000/3 ticks, scalar 3/7: m = 1000/3 + 7·300/3 = 1033.33 → rounds to 1033.
    let p = try P.project(tracks: [P.track(0, [
        P.clip("VMFile", id: 10, src: 1, start: 0, duration: s, mediaStart: "1000/3", scalar: "3/7"),
    ])])
    let r = try #require(videoRequest(P.scene(p).evaluate(at: 300).layers.first))
    #expect(r.time.value == 1033)
}

// MARK: - Geometry

@Test func transformIsTranslateRotateScale() throws {
    let p = try P.project(tracks: [P.track(0, [
        P.clip("VMFile", id: 10, src: 1, start: 0, duration: s, parameters: [
            "translation0": 100.0, "translation1": -50.0, "scale0": 0.5, "scale1": 0.25,
            "rotation2": Double.pi / 2,
        ]),
    ])])
    let l = try #require(P.scene(p).evaluate(at: 0).layers.first)
    #expect(l.size == CGSize(width: 1280, height: 720))
    // Layer-local (640, 0) → scale (320, 0) → rotate 90° CCW (0, 320) → translate (100, 270).
    #expect(approx(CGPoint(x: 640, y: 0).applying(l.transform), CGPoint(x: 100, y: 270)))
    #expect(approx(CGPoint.zero.applying(l.transform), CGPoint(x: 100, y: -50)))
}

@Test func missingParametersUseCamtasiaDefaults() throws {
    let p = try P.project(tracks: [P.track(0, [P.clip("VMFile", id: 10, src: 1, start: 0, duration: s)])])
    let l = try #require(P.scene(p).evaluate(at: 0).layers.first)
    #expect(l.transform == .identity)
    #expect(l.opacity == 1)
    #expect(l.geometryCrop == .zero && l.sourceCrop == .zero)
}

@Test func cropsAndOpacityAreReadAndClamped() throws {
    let p = try P.project(tracks: [P.track(0, [
        P.clip("VMFile", id: 10, src: 1, start: 0, duration: s, parameters: [
            "geometryCrop0": 0.1, "geometryCrop1": -1e-13, "geometryCrop2": 0.3, "geometryCrop3": 0.4,
            "sourceCrop0": 0.05, "sourceCrop3": 1.5, "opacity": ["type": "double", "defaultValue": 0.25],
        ]),
    ])])
    let l = try #require(P.scene(p).evaluate(at: 0).layers.first)
    #expect(l.geometryCrop == Insets(left: 0.1, top: 0, right: 0.3, bottom: 0.4))
    #expect(l.sourceCrop == Insets(left: 0.05, top: 0, right: 0, bottom: 1))
    #expect(l.opacity == 0.25)
}

@Test func keyframesAreRelativeToClipStart() throws {
    let p = try P.project(tracks: [P.track(0, [
        P.clip("VMFile", id: 10, src: 1, start: 10 * s, duration: 10 * s, parameters: [
            "opacity": P.keyframed(0, [(time: 0, end: 2 * s, value: 1)]),
            "translation0": P.keyframed(0, [(time: s, end: 3 * s, value: 100)], interp: "eioe"),
        ]),
    ])])
    let scene = P.scene(p)
    #expect(approx(try #require(scene.evaluate(at: 10 * s).layers.first).opacity, 0))
    #expect(approx(try #require(scene.evaluate(at: 11 * s).layers.first).opacity, 0.5))
    #expect(approx(try #require(scene.evaluate(at: 15 * s).layers.first).opacity, 1))
    // eioe at the midpoint of its span is half way; at a quarter, smoothstep(0.25) = 0.15625.
    #expect(approx(try #require(scene.evaluate(at: 12 * s).layers.first).transform.tx, 50))
    #expect(approx(try #require(scene.evaluate(at: 11 * s + s / 2).layers.first).transform.tx, 15.625))
}

/// Regression (time-mapping.md §6): keyframes are on the clip's media axis. A clip trimmed by
/// 22 frames (`mediaStart` 22 f) with keyframes 0→142 f shows media time 22…142 f.
@Test func keyframesUseMediaTimeAfterLeftTrim() throws {
    let f = s / 30
    let p = try P.project(tracks: [P.track(0, [
        P.clip("Callout", id: 10, start: 0, duration: 120 * f, mediaStart: 22 * f, parameters: [
            "opacity": P.keyframed(0, [(time: 0, end: 142 * f, value: 1)]),
        ], extra: ["def": ["kind": "remix", "shape": "text", "width": 10.0, "height": 10.0]]),
    ])])
    let scene = P.scene(p)
    // t = 0 → media 22 f → 22/142 of the way.
    #expect(approx(try #require(scene.evaluate(at: 0).layers.first).opacity, 22.0 / 142))
    #expect(approx(try #require(scene.evaluate(at: 49 * f).layers.first).opacity, 0.5))
}

@Test func keyframesOnSpedUpClipUseInnerTime() throws {
    // 2× speed (scalar 1/2): one timeline second = two media seconds on the keyframe axis [inf, X4].
    let p = try P.project(tracks: [P.track(0, [
        P.clip("VMFile", id: 10, src: 1, start: s, duration: 2 * s, scalar: "1/2", parameters: [
            "translation0": P.keyframed(0, [(time: 0, end: 4 * s, value: 400)], interp: "linr"),
        ]),
    ])])
    #expect(approx(try #require(P.scene(p).evaluate(at: 2 * s).layers.first).transform.tx, 200))
}

@Test func imageKeyframesUseTimelineOffset() throws {
    // Images: mediaStart 0, mediaDuration 1 tick; keyframes measured from the clip start + trimStartSum.
    let p = try P.project(tracks: [P.track(0, [
        P.clip("IMFile", id: 10, src: 2, start: 5 * s, duration: 10 * s, parameters: [
            "opacity": P.keyframed(0, [(time: 0, end: 4 * s, value: 1)], interp: "linr"),
        ], extra: ["mediaDuration": 1, "trimStartSum": 0]),
    ])])
    #expect(approx(try #require(P.scene(p).evaluate(at: 6 * s).layers.first).opacity, 0.25))
}

@Test func keyframeInterpFallsBackToParameterThenEioe() throws {
    let raw: [String: Any] = ["type": "double", "defaultValue": 0.0, "interp": "linr",
                              "keyframes": [["time": 0, "endTime": 100, "value": 1.0]]]
    let json = try JSON.parse(JSONSerialization.data(withJSONObject: raw))
    #expect(try #require(SParam(json)).value(at: 25) == 0.25)
    let bare: [String: Any] = ["type": "double", "defaultValue": 0.0,
                               "keyframes": [["time": 0, "endTime": 100, "value": 1.0]]]
    #expect(try #require(SParam(JSON.parse(JSONSerialization.data(withJSONObject: bare)))).value(at: 25) == 0.15625)
    let bounce: [String: Any] = ["type": "double", "defaultValue": 0.0,
                                 "keyframes": [["time": 0, "endTime": 100, "value": 1.0, "interp": "bnce"]]]
    #expect(try #require(SParam(JSON.parse(JSONSerialization.data(withJSONObject: bounce)))).value(at: 25) == 0.25)
}

@Test func sParamMatchesTSCProjKitParameter() throws {
    let raw: [String: Any] = P.keyframed(2, [(time: 100, end: 300, value: 10), (time: 500, end: 500, value: -4),
                                            (time: 700, end: 900, value: 6)], interp: "eioe")
    let json = try JSON.parse(JSONSerialization.data(withJSONObject: raw))
    let reference = Parameter(json)
    let mine = try #require(SParam(json))
    for t in stride(from: Int64(-50), through: 1000, by: 25) {
        #expect(approx(mine.value(at: Double(t)) ?? .nan, reference.value(at: t) ?? .nan), "t=\(t)")
    }
}

// MARK: - Tracks

@Test func tracksStackByTrackIndexAndHiddenTracksAreSkipped() throws {
    let p = try P.project(tracks: [
        P.track(1, [P.clip("IMFile", id: 11, src: 2, start: 0, duration: s)]),
        P.track(0, [P.clip("VMFile", id: 10, src: 1, start: 0, duration: s)]),
        P.track(2, [P.clip("VMFile", id: 12, src: 1, start: 0, duration: s)]),
    ], trackAttributes: [["videoHidden": false], ["videoHidden": false], ["videoHidden": true]])
    let plan = P.scene(p).evaluate(at: 0)
    #expect(plan.layers.map(\.clipID) == [10, 11])
    #expect(plan.layers[1].content == .image(URL(fileURLWithPath: "/m/./media/b.png")))
    #expect(plan.layers[1].size == CGSize(width: 400, height: 300))
}

@Test func clipLookupPicksTheClipCoveringTime() throws {
    let p = try P.project(tracks: [P.track(0, [
        P.clip("VMFile", id: 12, src: 1, start: 2 * s, duration: s),
        P.clip("VMFile", id: 10, src: 1, start: 0, duration: s),
        P.clip("VMFile", id: 11, src: 1, start: s, duration: s),
    ])])
    let scene = P.scene(p)
    #expect(scene.evaluate(at: 0).layers.map(\.clipID) == [10])
    #expect(scene.evaluate(at: s).layers.map(\.clipID) == [11])
    #expect(scene.evaluate(at: 2 * s + 5).layers.map(\.clipID) == [12])
    #expect(scene.evaluate(at: 3 * s).layers.isEmpty)
}

@Test func backgroundColourIsNormalised() throws {
    let p = try P.project(tracks: [], background: [255, 0, 51, 255])
    #expect(P.scene(p).evaluate(at: 0).background == RGBA(1, 0, 0.2, 1))
    let q = try P.project(tracks: [])
    #expect(P.scene(q).evaluate(at: 0).background == RGBA(0, 0, 0, 1))
}

// MARK: - Containers

@Test func unifiedMediaDrawsItsVideoHalf() throws {
    let u = P.clip("UnifiedMedia", id: 20, start: s, duration: s, mediaStart: 5 * s, extra: [
        "video": P.clip("VMFile", id: 21, src: 1, trackNumber: 0, start: s, duration: s, mediaStart: 5 * s,
                        parameters: ["scale0": 0.5, "scale1": 0.5]),
        "audio": P.clip("AMFile", id: 22, src: 1, trackNumber: 1, start: s, duration: s, mediaStart: 5 * s),
    ])
    let p = try P.project(tracks: [P.track(0, [u])])
    let l = try #require(P.scene(p).evaluate(at: s + 10).layers.first)
    #expect(l.clipID == 21)
    #expect(l.transform.a == 0.5)
    #expect(videoRequest(l)?.time.value == 5 * s + 10)
}

@Test func groupEvaluatesChildrenOnItsInnerTimeline() throws {
    let g = P.clip("Group", id: 30, start: 10 * s, duration: 4 * s, mediaStart: s, scalar: "1/2",
                   parameters: ["translation0": 20.0, "opacity": 0.5],
                   attributes: ["widthAttr": 800.0, "heightAttr": 600.0], extra: [
        "tracks": [
            P.track(0, [P.clip("VMFile", id: 31, src: 1, start: 0, duration: 20 * s, mediaStart: 7)]),
            P.track(1, [P.clip("IMFile", id: 32, src: 2, start: 3 * s, duration: s)]),
        ],
    ])
    let p = try P.project(tracks: [P.track(0, [g])])
    let scene = P.scene(p)
    // t = 11 s → inner m = 1 s + (1 s) / (1/2) = 3 s.
    let l = try #require(scene.evaluate(at: 11 * s).layers.first)
    #expect(l.clipID == 30)
    #expect(l.size == CGSize(width: 800, height: 600))
    #expect(l.transform.tx == 20 && l.opacity == 0.5)
    let kids = children(l)
    #expect(kids.map(\.clipID) == [31, 32])
    #expect(videoRequest(kids.first)?.time.value == 7 + 3 * s)
    // t = 12 s → m = 5 s; the image child (3 s..4 s) is gone.
    #expect(children(scene.evaluate(at: 12 * s).layers.first).map(\.clipID) == [31])
    #expect(scene.evaluate(at: 12 * s).frameRequests.count == 1)
}

@Test func groupTrackHiddenInlineIsSkipped() throws {
    let g = P.clip("Group", id: 30, start: 0, duration: s, extra: [
        "tracks": [
            P.track(0, [P.clip("VMFile", id: 31, src: 1, start: 0, duration: s)], extra: ["videoHidden": true]),
            P.track(1, [P.clip("VMFile", id: 32, src: 1, start: 0, duration: s)]),
        ],
    ])
    let p = try P.project(tracks: [P.track(0, [g])])
    let l = try #require(P.scene(p).evaluate(at: 0).layers.first)
    #expect(children(l).map(\.clipID) == [32])
    #expect(l.size == CGSize(width: 1920, height: 1080))  // no widthAttr → canvas
}

@Test func stitchedMediaPicksSegmentOnInnerTimeline() throws {
    func seg(_ id: Int, start: Int64, dur: Int64, ms: Int64) -> [String: Any] {
        P.clip("UnifiedMedia", id: id, start: start, duration: dur, mediaStart: ms, extra: [
            "video": P.clip("VMFile", id: id + 1, src: 1, start: start, duration: dur, mediaStart: ms,
                            parameters: ["geometryCrop0": 0.0]),
            "audio": P.clip("AMFile", id: id + 2, src: 1, trackNumber: 1, start: start, duration: dur, mediaStart: ms),
        ])
    }
    // Mirrors the vlog's clip 72: stitched clip starts inside the first segment.
    let st = P.clip("StitchedMedia", id: 40, start: 100 * s, duration: 6 * s, mediaStart: 2 * s,
                    parameters: ["scale0": 0.75, "scale1": 0.75], extra: [
        "minMediaStart": 0.0,
        "medias": [seg(41, start: 0, dur: 5 * s, ms: 0), seg(44, start: 5 * s, dur: 10 * s, ms: 50 * s)],
    ])
    let p = try P.project(tracks: [P.track(0, [st])])
    let scene = P.scene(p)
    let a = try #require(scene.evaluate(at: 101 * s).layers.first)   // inner 3 s → seg 41
    #expect(a.clipID == 40 && a.transform.a == 0.75)
    #expect(videoRequest(a)?.time.value == 3 * s)
    let b = try #require(scene.evaluate(at: 104 * s).layers.first)   // inner 6 s → seg 44, 51 s
    #expect(videoRequest(b)?.time.value == 51 * s)
    #expect(scene.evaluate(at: 106 * s).layers.isEmpty)
}

// MARK: - Content kinds

@Test func shaderAndCalloutContent() throws {
    let shader = P.clip("VMFile", id: 50, src: 3, start: 0, duration: s, extra: [
        "sourceEffect": ["effectName": "SourceEffect", "bypassed": false, "parameters": [
            "Color0-red": ["type": "double", "defaultValue": 0.25, "interp": "linr"],
            "Speed": 2.0, "sourceFileType": "tscshadervid",
        ]],
    ])
    let callout = P.clip("Callout", id: 51, start: 0, duration: s, extra: [
        "def": ["kind": "remix", "shape": "text", "width": 300.0, "height": 100.0],
    ])
    let p = try P.project(tracks: [P.track(0, [shader]), P.track(1, [callout])])
    let plan = P.scene(p).evaluate(at: 0)
    guard case .shader(let url, let params) = plan.layers[0].content else { Issue.record("not shader"); return }
    #expect(url.lastPathComponent == "bg.tscshadervid")
    #expect(params == ["Color0-red": 0.25, "Speed": 2])
    #expect(plan.layers[1].content == .unsupported(type: "Callout"))
    #expect(plan.layers[1].size == CGSize(width: 300, height: 100))
    #expect(plan.frameRequests.isEmpty)
}

@Test func effectsAreEvaluatedNotDrawn() throws {
    let p = try P.project(tracks: [P.track(0, [
        P.clip("VMFile", id: 10, src: 1, start: s, duration: s, effects: [
            ["effectName": "RoundCorners", "bypassed": false, "parameters": [
                "radius": P.keyframed(0, [(time: 0, end: s, value: 40)]), "enabled": true]],
            ["effectName": "dummy", "start": 0, "duration": 5],
            ["effectName": "DropShadow", "bypassed": true, "parameters": [String: Any]()],
        ]),
    ])])
    let l = try #require(P.scene(p).evaluate(at: s + s / 4).layers.first)
    #expect(l.effects == [
        EffectInstance(name: "RoundCorners", parameters: ["radius": 10, "enabled": 1], bypassed: false),
        EffectInstance(name: "DropShadow", parameters: [:], bypassed: true),
    ])
}

@Test func sceneModelDoesNotMutateTheProject() throws {
    let p = try P.project(tracks: [P.track(0, [
        ["id": 10, "_type": "VMFile", "src": 1, "trackNumber": 0, "start": 0, "duration": s],
    ])])
    let before = p.serialized()
    _ = P.scene(p).evaluate(at: 0)
    #expect(p.serialized() == before)
}

@Test func rationalHelpersSurviveOverflow() {
    let big = Rational(9_000_000_000_000_000_000 / 3, 1)
    let odd = Rational(1, 4_918_496)
    let r = Q.add(Q.mul(big, Rational(3, 1)), odd)  // overflows; falls back to whole ticks
    #expect(r.den == 1)
    #expect(Q.round(Rational(5, 2)) == 3 && Q.round(Rational(-5, 2)) == -3 && Q.round(Rational(7, 3)) == 2)
    #expect(Q.lt(Rational(1, 3), Rational(1, 2)))
}

// MARK: - Demo fixture

private func demoScene() throws -> SceneModel {
    let p = try Project(contentsOf: fixtureURL("demo.tscproj"))
    return SceneModel(project: p) { URL(fileURLWithPath: "/demo").appendingPathComponent($0.src) }
}

@Test func demoPlanAtZero() throws {
    let scene = try demoScene()
    #expect(scene.canvasSize == CGSize(width: 1920, height: 1080))
    let plan = scene.evaluate(at: 0)
    #expect(plan.layers.count == 1)
    let group = try #require(plan.layers.first)
    #expect(group.clipID == 4)
    #expect(group.size == CGSize(width: 1920, height: 1080))
    let kids = children(group)
    #expect(kids.map(\.clipID) == [5, 6, 8])

    guard case .shader(let url, let params) = kids[0].content else { Issue.record("bg not shader"); return }
    #expect(url.pathExtension == "tscshadervid")
    #expect(approx(params["Color0-red"] ?? 0, 0.368627450980392))
    #expect(params["Speed"] == 2)

    let screen = kids[1]
    let rq = try #require(videoRequest(screen))
    #expect(rq.stream == 0 && rq.url.pathExtension == "trec" && rq.time.value == 0)
    #expect(screen.size == CGSize(width: 3024, height: 1964))
    #expect(approx(screen.transform.a, 0.54989816700611))
    #expect(approx(screen.size.height * screen.transform.d, 1080, 0.01))  // fills canvas height
    #expect(screen.effects.map(\.name).contains("DropShadow"))
    #expect(screen.geometryCrop == .zero)  // −8e−14 noise clamped

    let camera = kids[2]
    #expect(videoRequest(camera)?.stream == 1)
    #expect(camera.size == CGSize(width: 1920, height: 1080))  // trackRect of stream 1
    #expect(approx(camera.transform.tx, 554.297629490835) && approx(camera.transform.ty, -384.104025549898))
    // Bottom-right: right edge inside the canvas, bottom edge on the canvas bottom (+y up).
    let corner = CGPoint(x: 960, y: -540).applying(camera.transform)
    #expect(corner.x < 960 && corner.x > 800)
    #expect(approx(corner.y, -540, 0.5))
    #expect(plan.frameRequests.count == 2)
}

@Test func demoPlanNearEnd() throws {
    let scene = try demoScene()
    // Camera/shader end at 18086880000; the screen recording runs to 18110400000.
    let late = scene.evaluate(at: 18_100_000_000)
    #expect(children(late.layers.first).map(\.clipID) == [6])
    #expect(scene.evaluate(at: scene.duration).layers.isEmpty)
    let mid = scene.evaluate(at: 12 * s)
    #expect(videoRequest(children(mid.layers.first)[1])?.time == CMTime(value: 12 * s, timescale: Int32(s)))
}

// MARK: - User projects (skip when absent)

@Test(.enabled(if: FileManager.default.fileExists(atPath: vlogBundleURL.path)))
func vlogEvaluatesEverywhereAndFast() throws {
    let bundle = try ProjectBundle(url: vlogBundleURL)
    let scene = SceneModel(project: bundle.project, resolve: bundle.resolve)
    let step = scene.duration / 997
    var t: Int64 = 0, frames = 0, visible = 0
    let clock = ContinuousClock()
    let elapsed = clock.measure {
        while t < scene.duration {
            let plan = scene.evaluate(at: t)
            frames += 1
            if !plan.layers.isEmpty { visible += 1 }
            t += step
        }
    }
    #expect(visible > frames * 9 / 10)
    let perEval = elapsed / frames
    #expect(perEval < .microseconds(500), "evaluate took \(perEval)")
    // Clip 82 (StitchedMedia, scalar 304/457) starts at 23531760000: second segment from inner 1881600000.
    let inner = Rational(1_881_600_000 + 1)  // just inside segment 2
    let tl = Conventions.parentTime(media: inner, start: 23_531_760_000, mediaStart: Rational(0),
                                    scalar: Rational(304, 457))
    let plan = scene.evaluate(at: Q.round(tl) + 1)
    let l = try #require(plan.layers.first)
    #expect(l.clipID == 82)
    let r = try #require(videoRequest(l))
    #expect(abs(r.time.value - (12_841_920_000 + 3)) < 5)
}
