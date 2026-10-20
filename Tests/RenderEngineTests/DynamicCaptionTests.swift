import CaptionLayout
import CoreGraphics
import Foundation
import Testing
import TSCProjKit
@testable import RenderEngine

private let s = P.rate

/// Audio source 4 with a word transcription: "The" 0–0.5 s, "quick" 0.5–1 s, "fox." 1–1.5 s.
private func transcribedAudio(words: [(Double, String)] = [(0, "The"), (0.5, "quick"), (1, "fox."), (1.5, "")])
    -> [String: Any] {
    ["id": 4, "src": "./media/c.m4a", "rect": [0, 0, 0, 0],
     "sourceTracks": [[
         "type": 2, "editRate": 48000, "range": [0, 480_000], "trackRect": [0, 0, 0, 0], "transcriptionSet": true,
         "parameters": ["transcription": ["type": "string", "keyframes": words.map { t, v -> [String: Any] in
             let ticks = Int64((t * Double(s)).rounded())
             return ["endTime": ticks, "time": ticks, "value": v, "duration": 0]
         }]],
     ]]]
}

private func captionDef(_ extra: [String: Any] = [:]) -> [String: Any] {
    var d: [String: Any] = [
        "kind": "remix", "shape": "text", "style": "caption", "modifier": "dynamicCaption",
        "dynamic-caption-style": "block", "width": 1600.0, "height": 300.0, "text": "ABC",
        "font": ["name": "Helvetica", "size": 96.0, "weight": "Regular", "color-red": 1.0, "color-green": 1.0,
                 "color-blue": 1.0, "color-opacity": 1.0],
        "textAttributes": ["type": "textAttributeList", "keyframes": [
            ["time": 0, "endTime": 0, "duration": 0, "value": [
                ["name": "fontSize", "rangeStart": 0, "rangeEnd": 3, "value": 261.0, "valueType": "double"],
                ["name": "fontWeight", "rangeStart": 0, "rangeEnd": 1, "value": 700, "valueType": "int"],
            ]],
        ]],
    ]
    for (k, v) in extra { d[k] = v }
    return d
}

private func scene(audioStart: Int64 = 0, mediaStart: Int64 = 0, scalar: Any = 1, def: [String: Any] = captionDef(),
                   callout: (start: Int64, dur: Int64) = (0, 10 * s)) throws -> SceneModel {
    let audio = P.clip("AMFile", id: 10, src: 4, start: audioStart, duration: 5 * s, mediaStart: mediaStart, scalar: scalar)
    let call = P.clip("Callout", id: 20, start: callout.start, duration: callout.dur, extra: ["def": def])
    var sources = P.defaultSources.filter { ($0["id"] as? Int) != 4 }
    sources.append(transcribedAudio())
    return P.scene(try P.project(tracks: [P.track(0, [audio]), P.track(1, [call])], sources: sources))
}

private func caption(_ sc: SceneModel, at t: Int64) throws -> CalloutContent {
    let layer = try #require(sc.evaluate(at: t).layers.first { $0.clipID == 20 })
    guard case .callout(let c) = layer.content else { throw CocoaError(.featureUnsupported) }
    return c
}

@Suite struct DynamicCaptionEvaluateTests {
    @Test func showsTheWordsOfTheAudioPlayingNow() throws {
        let sc = try scene()
        let c = try caption(sc, at: s * 3 / 4)
        let dc = try #require(c.dynamicCaption)
        let f = try #require(dc.frame)
        #expect(f.text == "The quick fox." && c.text == f.text)
        #expect(f.currentWord == 1 && f.words.map(\.state) == [.past, .current, .future])
        #expect(dc.style == DynamicCaptionStyle(def: try #require(JSON.parse(
            String(decoding: JSONSerialization.data(withJSONObject: captionDef()), as: UTF8.self)).object)))
        // One run over the block: weight kept, the placeholder's fitted size dropped.
        #expect(c.runs == [CalloutTextRun(range: 0..<14, fontWeight: 700)])
        #expect(c.fontSize == 96)
    }

    @Test func resizeCalloutPresetsTakeFontAndSizeFromTheRuns() throws {
        // Camtasia 2026 presets: def.font is a stale "Bebas Neue 128"; the runs say Arial 96 [obs CA2].
        var def = captionDef(["resize-behavior": "resizeCallout",
                              "font": ["name": "Bebas Neue", "size": 128.0, "weight": "Regular"]])
        def["textAttributes"] = ["type": "textAttributeList", "keyframes": [
            ["time": 0, "endTime": 0, "duration": 0, "value": [
                ["name": "fontName", "rangeStart": 0, "rangeEnd": 3, "value": "Arial", "valueType": "string"],
                ["name": "fontSize", "rangeStart": 0, "rangeEnd": 3, "value": 96.0, "valueType": "double"],
            ]],
        ]]
        let c = try caption(try scene(def: def), at: s * 3 / 4)
        #expect(c.fontSize == 96)
        #expect(c.runs == [CalloutTextRun(range: 0..<14, fontName: "Arial")])
        // The fit starts from the run size and keeps the run's font (the box is wide enough here).
        let (fitted, _) = DynamicCaptionText.fit(c, box: CGRect(x: -800, y: -150, width: 1600, height: 300))
        #expect(fitted.fontSize == 96 && fitted.runs.first?.fontName == "Arial")
        // "resizeText" (CP1, earlier WizRec saves) keeps def.font.size.
        var old = def; old["resize-behavior"] = "resizeText"
        #expect(try caption(try scene(def: old), at: s * 3 / 4).fontSize == 128)
    }

    @Test func nothingOutsideTheWordsOrTheAudio() throws {
        let sc = try scene(audioStart: s)
        #expect(try caption(sc, at: s / 2).dynamicCaption?.frame == nil)      // audio not started
        #expect(try caption(sc, at: s / 2).text == "")
        #expect(try caption(sc, at: s + s / 4).dynamicCaption?.frame?.currentWord == 0)
        #expect(try caption(sc, at: 7 * s).dynamicCaption?.frame == nil)      // after audio and linger
    }

    @Test func followsTheAudioClipsMediaMapping() throws {
        // Trimmed by 0.5 s and played at 2× (scalar 1/2): timeline 0.3 s → media 0.5 + 0.6 = 1.1 s → "fox.".
        let sc = try scene(mediaStart: s / 2, scalar: "1/2")
        let f = try #require(try caption(sc, at: s * 3 / 10).dynamicCaption?.frame)
        #expect(f.words[f.currentWord ?? -1].state == .current)
        #expect(f.currentWord == 2)
    }

    @Test func ordinaryCalloutsAreUntouched() throws {
        var def = captionDef()
        def["modifier"] = nil
        let c = try caption(try scene(def: def), at: s / 4)
        #expect(c.dynamicCaption == nil && c.text == "ABC" && c.runs.count == 2)
    }

    @Test func unpairedCaptionShowsNothing() throws {
        let call = P.clip("Callout", id: 20, start: 0, duration: s, extra: ["def": captionDef()])
        let sc = P.scene(try P.project(tracks: [P.track(0, [call])]))
        let c = try caption(sc, at: s / 2)
        #expect(c.dynamicCaption != nil && c.dynamicCaption?.frame == nil && c.text.isEmpty)
    }

    @Test func boundsMakeRoomForTheHighlight() {
        var style = DynamicCaptionStyle()
        style.currentWordStrokeExtraWidth = 18
        let plain = CalloutContent(shape: "text", size: CGSize(width: 100, height: 50), fontSize: 40)
        var dyn = plain
        dyn.dynamicCaption = DynamicCaptionRender(frame: nil, style: style)
        #expect(CalloutGeometry.bounds(dyn).width >= CalloutGeometry.bounds(plain).width + 2 * 18)
    }
}

private func frame(_ words: [String], current: Int?) -> DynamicCaptionFrame {
    var text = "", out: [DynamicCaptionFrame.Word] = []
    for (i, w) in words.enumerated() {
        if i > 0 { text += " " }
        let lo = text.utf16.count
        text += w
        let st: DynamicCaptionFrame.WordState = current.map { i < $0 ? .past : i == $0 ? .current : .future } ?? .past
        out.append(.init(range: lo..<text.utf16.count, state: st))
    }
    return DynamicCaptionFrame(text: text, words: out, currentWord: current)
}

private func render(_ c: CalloutContent, w: Int = 192, h: Int = 108) throws -> GPUTest.Image {
    let l = Layer(clipID: 1, content: .callout(c), size: c.size)
    return try GPUTest.render(RenderPlan(time: 0, canvasSize: CGSize(width: w, height: h), background: RGBA(0, 0, 0),
                                         layers: [l]), w, h)
}

private func count(_ img: GPUTest.Image, _ test: (Px) -> Bool) -> (n: Int, minX: Int, maxX: Int) {
    var n = 0, lo = Int.max, hi = Int.min
    for y in 0..<img.height { for x in 0..<img.width where test(img.at(x, y)) { n += 1; lo = min(lo, x); hi = max(hi, x) } }
    return (n, lo, hi)
}

@Suite(.enabled(if: hasGPU)) struct DynamicCaptionRenderTests {
    func content(_ f: DynamicCaptionFrame?, _ style: DynamicCaptionStyle) -> CalloutContent {
        CalloutContent(kind: "remix", shape: "text", style: "caption", size: CGSize(width: 180, height: 60),
                       fill: RGBA(0, 0, 0, 0), text: f?.text ?? "", fontName: "Helvetica", fontSize: 24,
                       textColor: RGBA(1, 1, 1, 1), dynamicCaption: DynamicCaptionRender(frame: f, style: style))
    }

    @Test func currentWordIsHighlighted() throws {
        var style = DynamicCaptionStyle()
        style.currentWordColor = CaptionColor(1, 0, 0, 1)
        style.currentWordStrokeExtraWidth = 0
        let red: (Px) -> Bool = { $0.r > 200 && $0.g < 60 && $0.b < 60 }
        let white: (Px) -> Bool = { $0.r > 200 && $0.g > 200 && $0.b > 200 }
        // Middle word current: red pixels only in the middle third, white on both sides.
        let img = try render(content(frame(["AAA", "BBB", "CCC"], current: 1), style))
        let r = count(img, red), wh = count(img, white)
        #expect(r.n > 30)
        #expect(wh.minX < r.minX && wh.maxX > r.maxX)
        // No current word: no red at all.
        #expect(count(try render(content(frame(["AAA", "BBB", "CCC"], current: nil), style)), red).n == 0)
        // Highlight disabled: no red either.
        style.currentWordEnabled = false
        #expect(count(try render(content(frame(["AAA", "BBB", "CCC"], current: 1), style)), red).n == 0)
    }

    @Test func wordBoxAndBackgroundAndOpacity() throws {
        var style = DynamicCaptionStyle()
        style.currentWordStrokeExtraWidth = 0
        style.wordRectangleColor = CaptionColor(0, 0, 1, 1)
        let blue: (Px) -> Bool = { $0.b > 200 && $0.r < 60 && $0.g < 60 }
        let boxed = count(try render(content(frame(["AAA", "BBB", "CCC"], current: 2), style)), blue)
        #expect(boxed.n > 100 && boxed.minX > 96)  // behind the last word, right of centre
        style.wordRectangleColor = CaptionColor(0, 0, 1, 0)
        style.backgroundFillColor = CaptionColor(0, 1, 0, 1)
        let green = count(try render(content(frame(["AAA", "BBB", "CCC"], current: 2), style)), { $0.g > 200 && $0.r < 60 })
        #expect(green.n > 500)
        // Future words at opacity 0 vanish: with word 0 current, nothing white right of centre.
        style.backgroundFillColor = CaptionColor(0, 0, 0, 0)
        style.futureWordOpacity = 0
        style.currentWordColor = CaptionColor(1, 1, 1, 1)
        let lit = count(try render(content(frame(["AAA", "BBB", "CCC"], current: 0), style)), { $0.r > 128 })
        #expect(lit.n > 0 && lit.maxX < 96)
    }

    /// The highlight moves exactly at a word's start tick: one tick before 0.5 s "The" is red, at 0.5 s "quick".
    @Test func highlightSwitchesAtWordBoundary() throws {
        let def = captionDef(["width": 900.0, "height": 200.0, "dynamic-caption-current-word-color-red": 1.0,
                              "dynamic-caption-current-word-color-green": 0.0, "dynamic-caption-current-word-color-blue": 0.0,
                              "dynamic-caption-current-word-stroke-extra-width": 0.0])
        let sc = try scene(def: def)
        let red: (Px) -> Bool = { $0.r > 200 && $0.g < 60 && $0.b < 60 }
        func redSpan(at t: Int64) throws -> (n: Int, minX: Int, maxX: Int) {
            let plan = sc.evaluate(at: t)
            let layers = plan.layers.filter { $0.clipID == 20 }
            return count(try GPUTest.render(RenderPlan(time: t, canvasSize: plan.canvasSize, background: RGBA(0, 0, 0),
                                                       layers: layers), 480, 270), red)
        }
        let before = try redSpan(at: s / 2 - 1), after = try redSpan(at: s / 2)
        #expect(before.n > 20 && after.n > 20)
        #expect(before.maxX < after.minX)   // "The" is left of "quick"
        #expect(try caption(sc, at: s / 2 - 1).dynamicCaption?.frame?.currentWord == 0)
        #expect(try caption(sc, at: s / 2).dynamicCaption?.frame?.currentWord == 1)
        // The closing "" mark at 1.5 s ends "fox.": no word current, no red.
        #expect(try redSpan(at: 3 * s / 2).n == 0)
        #expect(try redSpan(at: 3 * s / 2 - 1).n > 20)
    }

    @Test func emptyFrameDrawsNothing() throws {
        let img = try render(content(nil, DynamicCaptionStyle()))
        #expect(count(img, { $0.r > 20 || $0.g > 20 || $0.b > 20 }).n == 0)
    }

    @Test func longBlocksShrinkToFit() throws {
        var style = DynamicCaptionStyle()
        style.currentWordStrokeExtraWidth = 0
        let words = (0..<12).map { "WORD\($0)" }
        let img = try render(content(frame(words, current: nil), style))
        let lit = count(img, { $0.r > 128 })
        #expect(lit.n > 0)
        // Box is 180×60 centred in 192×108: x 6…186.
        #expect(lit.minX >= 4 && lit.maxX <= 188)
    }
}

/// Camtasia's dynamic-caption sample, read in place (skipped when Camtasia is not installed). Writes
/// frames to `WIZREC_RENDER_OUT` when set, for eyeballing.
@Suite struct DynamicCaptionSampleTests {
    static let url = URL(fileURLWithPath:
        "/Applications/Camtasia.app/Contents/Resources/DynamicCaptions/DynamicCaptionPreviewBaseProject_en-US.tscproj")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: DynamicCaptionSampleTests.url.path)))
    func samplePairsCalloutWithItsAudio() throws {
        let p = try Project(contentsOf: Self.url)
        let sc = SceneModel(project: p) { URL(fileURLWithPath: "/nonexistent").appendingPathComponent($0.src) }
        let t = Int64(0.2 * Double(p.timebase.editRate))
        var found: CalloutContent?
        for l in sc.evaluate(at: t).layers { if case .callout(let c) = l.content, c.dynamicCaption != nil { found = c } }
        let c = try #require(found)
        let f = try #require(c.dynamicCaption?.frame)
        let cur = try #require(f.currentWord)
        let word = (f.text as NSString).substring(with: NSRange(location: f.words[cur].range.lowerBound,
                                                                length: f.words[cur].range.count))
        #expect(word == "Quick")
        #expect(c.fontName == "Bebas Neue" && c.fontSize == 96)

        guard hasGPU, let dir = ProcessInfo.processInfo.environment["WIZREC_RENDER_OUT"] else { return }
        for (i, sec) in [0.1, 0.2, 0.6, 1.2, 2.0].enumerated() {
            let plan = sc.evaluate(at: Int64(sec * Double(p.timebase.editRate)))
            let layers = plan.layers.filter { if case .callout = $0.content { true } else { false } }
            let img = try GPUTest.render(RenderPlan(time: plan.time, canvasSize: plan.canvasSize, background: RGBA(0.2, 0.3, 0.4),
                                                    layers: layers), 960, 512)
            let cs = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            var bytes = img.bytes
            let ctx = try #require(CGContext(data: &bytes, width: 960, height: 512, bitsPerComponent: 8, bytesPerRow: 960 * 4,
                space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            try writePNG(try #require(ctx.makeImage()), to: URL(fileURLWithPath: dir).appendingPathComponent("dyncap-\(i).png"))
        }
    }
}
