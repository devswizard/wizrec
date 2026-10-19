import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import MediaEngine
import Testing
import TSCProjKit
@testable import RenderEngine

private let s = P.rate

/// A recording folder with `cursor.json` and one solid-colour cursor PNG (synthetic data).
private func recording(events: [[String: Any]], video: (Int, Int) = (200, 100), cursor: (Int, Int) = (8, 8),
                       hotspot: (Int, Int) = (2, 2)) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-cursor-\(UUID())")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("cursors"), withIntermediateDirectories: true)
    let log: [String: Any] = [
        "format": "wizrec-cursor-log", "version": 1, "coordinateSpace": "capturedPixels", "origin": "topLeft",
        "timeUnit": "seconds", "videoWidth": video.0, "videoHeight": video.1, "pixelsPerPoint": 1,
        "sampleRate": 30, "duration": 10, "keystrokesLogged": false, "futureKey": [1, 2],
        "cursors": [["id": 0, "file": "cursors/cursor-0.png", "width": cursor.0, "height": cursor.1,
                     "hotspotX": hotspot.0, "hotspotY": hotspot.1]],
        "events": events,
    ]
    try JSONSerialization.data(withJSONObject: log).write(to: dir.appendingPathComponent("cursor.json"))
    // Opaque red PNG.
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: cursor.0, height: cursor.1, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: cursor.0, height: cursor.1))
    let png = dir.appendingPathComponent("cursors/cursor-0.png")
    let dest = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return dir
}

private var moves: [[String: Any]] { [
    ["t": 0, "type": "move", "x": 10, "y": 20], ["t": 0, "type": "cursor", "id": 0],
    ["t": 1.5, "type": "move", "x": 100, "y": 50],
    ["t": 2, "type": "down", "button": "left", "x": 120, "y": 60, "clickCount": 1],
    ["t": 3, "type": "key", "keyCode": 0, "modifiers": [String]()],
    ["t": 4, "type": "somethingNew"],
] }

@Suite struct CursorTrackTests {
    @Test func samplesHoldTheLastPosition() throws {
        let dir = try recording(events: moves)
        let track = try #require(CursorTrack.load(dir.appendingPathComponent("cursor.json")))
        #expect(track.videoSize == CGSize(width: 200, height: 100))
        #expect(track.sample(at: -1) == nil)
        #expect(track.sample(at: 0)?.position == CGPoint(x: 10, y: 20))
        #expect(track.sample(at: 1.49)?.position == CGPoint(x: 10, y: 20))
        #expect(track.sample(at: 1.5)?.position == CGPoint(x: 100, y: 50))
        #expect(track.sample(at: 9)?.position == CGPoint(x: 120, y: 60))
        #expect(track.sample(at: 0)?.image.hotspot == CGPoint(x: 2, y: 2))
        #expect(track.sample(at: 0)?.image.url.lastPathComponent == "cursor-0.png")
    }

    /// `Fixtures/cursor-log-v1.json` was written by `Recorder.CursorLog.jsonData()`, so the mirrored
    /// decoder cannot drift from the writer silently. Regenerate it when the format version changes.
    @Test func readsTheRecorderWrittenFixture() throws {
        let track = try #require(CursorTrack.load(try fixtureURL("cursor-log-v1.json")))
        #expect(track.videoSize == CGSize(width: 640, height: 400))
        #expect(track.images.count == 2 && track.images[1]?.hotspot == CGPoint(x: 20, y: 20))
        #expect(track.sample(at: 0.7)?.position == CGPoint(x: 330.25, y: 210.5))
        #expect(track.sample(at: 1.05)?.position == CGPoint(x: 340, y: 220))    // down carries a position
        #expect(track.sample(at: 2.2)?.image.url.lastPathComponent == "cursor-1.png")
        #expect(track.sample(at: 3)?.position == CGPoint(x: 100, y: 50))
    }

    @Test func rejectsOtherJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-cursor-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("cursor.json")
        try Data(#"{"format":"other","version":1}"#.utf8).write(to: url)
        #expect(CursorTrack.load(url) == nil)
    }

    @Test func screenClipGetsCursorAtMediaTime() throws {
        let dir = try recording(events: moves)
        let sources: [[String: Any]] = [
            P.source(1, "./recordings/r/screen.mp4", w: 200, h: 100, tracks: [0]),
            P.source(2, "./recordings/r/camera.mp4", w: 200, h: 100, tracks: [0]),
        ]
        let screen = P.clip("ScreenVMFile", id: 10, src: 1, start: 0, duration: 5 * s, mediaStart: s)
        let camera = P.clip("VMFile", id: 11, src: 2, start: 0, duration: 5 * s)
        let p = try P.project(tracks: [P.track(0, [screen]), P.track(1, [camera])], sources: sources)
        let scene = SceneModel(project: p) { dir.appendingPathComponent(($0.src as NSString).lastPathComponent) }
        // Timeline 0.5 s = media 1.5 s.
        let plan = scene.evaluate(at: s / 2)
        let c = try #require(plan.layers[0].cursor)
        #expect(c.position == CGPoint(x: 100, y: 50))
        #expect(c.sourceSize == CGSize(width: 200, height: 100) && c.imageSize == CGSize(width: 8, height: 8))
        #expect(plan.layers[1].cursor == nil)   // camera.mp4 in the same folder
    }
}

@Suite(.enabled(if: hasGPU)) struct CursorRenderTests {
    @Test func cursorIsDrawnAtItsHotspot() throws {
        let dir = try recording(events: moves)
        let img = dir.appendingPathComponent("cursors/cursor-0.png")
        let rq = GPUTest.request("bg")
        let fr = GPUTest.frame(GPUTest.pixelBuffer(16, 16) { _, _ in .white })
        // Layer 200×100 source px drawn at 192×108 canvas... use canvas == layer size for 1:1.
        let c = CursorOverlay(image: img, imageSize: CGSize(width: 8, height: 8), hotspot: CGPoint(x: 2, y: 2),
                              position: CGPoint(x: 50, y: 30), sourceSize: CGSize(width: 200, height: 100))
        let layer = Layer(clipID: 1, content: .video(rq), size: CGSize(width: 200, height: 100), cursor: c)
        let plan = RenderPlan(time: 0, canvasSize: CGSize(width: 200, height: 100), background: RGBA(0, 0, 0),
                              layers: [layer])
        let out = try GPUTest.render(plan, frames: [rq: fr], 200, 100)
        // Image spans x 48…56, y 28…36.
        #expect(out.at(49, 29) == .red && out.at(55, 35) == .red)
        #expect(out.at(46, 29) == .white && out.at(58, 29) == .white && out.at(49, 38) == .white)
        // Clipped by the layer's crop: crop the right half away, cursor beyond it disappears.
        var cropped = layer
        cropped.cursor?.position = CGPoint(x: 150, y: 30)
        cropped.geometryCrop = Insets(right: 0.5)
        let out2 = try GPUTest.render(RenderPlan(time: 0, canvasSize: CGSize(width: 200, height: 100),
                                                 background: RGBA(0, 0, 0), layers: [cropped]), frames: [rq: fr], 200, 100)
        #expect(out2.at(150, 31) == .black)
    }
}
