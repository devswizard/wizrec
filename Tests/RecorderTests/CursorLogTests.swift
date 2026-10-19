import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import Testing
@testable import Recorder

@Suite struct CursorLogTests {
    /// A Retina display region: 800×600 points at global (100, 50) captured as 1600×1200 pixels.
    let geometry = CaptureGeometry(sourceRect: CGRect(x: 100, y: 50, width: 800, height: 600), pixelWidth: 1600, pixelHeight: 1200)

    @Test func geometryMapsGlobalPointsToCapturedPixels() {
        #expect(geometry.pixelsPerPoint == 2)
        #expect(geometry.pixels(CGPoint(x: 100, y: 50)) == .zero)
        #expect(geometry.pixels(CGPoint(x: 150.255, y: 60)) == CGPoint(x: 100.51, y: 20))
        #expect(geometry.pixels(CGPoint(x: 0, y: 0)) == CGPoint(x: -200, y: -100), "outside the capture: still logged")
    }

    @Test func builderStitchesPausesAndCollapsesRepeats() {
        var s = TimelineStitcher()
        var b = CursorLogBuilder(geometry: geometry)
        b.move(to: CGPoint(x: 110, y: 60), hostTime: h(-1), timeline: s)  // before start: dropped, remembered
        b.cursor(0, hostTime: h(-1), timeline: s)
        s.start(at: h(0)); b.segmentStarted(timeline: s)
        b.move(to: CGPoint(x: 110, y: 60), hostTime: h(0.1), timeline: s)  // unchanged: collapsed
        b.move(to: CGPoint(x: 120, y: 60), hostTime: h(0.2), timeline: s)
        b.event(at: CGPoint(x: 120, y: 60), hostTime: h(0.25), timeline: s) { .down(button: .left, x: $0.x, y: $0.y, clickCount: 1) }
        b.cursor(0, hostTime: h(0.3), timeline: s)                           // same image: collapsed
        s.pause(at: h(1))
        b.move(to: CGPoint(x: 300, y: 300), hostTime: h(1.5), timeline: s)  // paused: dropped
        b.cursor(1, hostTime: h(1.5), timeline: s)
        s.resume(at: h(2)); b.segmentStarted(timeline: s)
        b.event(at: CGPoint(x: 300, y: 300), hostTime: h(2.5), timeline: s) { .up(button: .left, x: $0.x, y: $0.y) }
        b.key(.key(keyCode: 0, characters: "a", modifiers: [], isRepeat: false), hostTime: h(2.6), timeline: s)
        s.stop(at: h(3))
        b.move(to: CGPoint(x: 0, y: 0), hostTime: h(3.1), timeline: s)

        let e = b.sortedEvents
        #expect(e.map(\.t) == [0, 0, 0.2, 0.25, 1, 1, 1.5, 1.6])
        #expect(e[0].kind == .move(x: 20, y: 20))
        #expect(e[1].kind == .cursor(id: 0))
        #expect(e[2].kind == .move(x: 40, y: 20))
        #expect(e[4].kind == .move(x: 400, y: 500))
        #expect(e[5].kind == .cursor(id: 1))
        #expect(e[6].kind == .up(button: .left, x: 400, y: 500))
    }

    @Test func jsonShapeIsStable() throws {
        let log = CursorLog(
            videoWidth: 1600, videoHeight: 1200, pixelsPerPoint: 2, sampleRate: 30, duration: 1.5, keystrokesLogged: false,
            cursors: [CursorImage(id: 0, file: "cursors/cursor-0.png", width: 34, height: 46, hotspotX: 8, hotspotY: 8)],
            events: [
                CursorEvent(t: 0, kind: .move(x: 1.5, y: 2)),
                CursorEvent(t: 0.0334, kind: .down(button: .right, x: 1.5, y: 2, clickCount: 2)),
                CursorEvent(t: 0.5, kind: .scroll(dx: 0, dy: -3.5, x: 1, y: 2)),
                CursorEvent(t: 0.6, kind: .cursor(id: 0)),
            ]
        )
        let json = String(decoding: try log.jsonData(), as: UTF8.self)
        #expect(json.hasPrefix(#"{"coordinateSpace":"capturedPixels","cursors":[{"file":"cursors/cursor-0.png","height":46,"hotspotX":8,"hotspotY":8,"id":0,"width":34}],"duration":1.5,"events":[{"t":0,"type":"move","x":1.5,"y":2},{"button":"right","clickCount":2,"t":0.0334,"type":"down","x":1.5,"y":2}"#))
        #expect(json.hasSuffix(#""format":"wizrec-cursor-log","keystrokesLogged":false,"origin":"topLeft","pixelsPerPoint":2,"sampleRate":30,"timeUnit":"seconds","version":1,"videoHeight":1200,"videoWidth":1600}"#))
        #expect(try CursorLog.decode(log.jsonData()) == log)
    }

    @Test func decoderIgnoresUnknownKeysAndTypes() throws {
        let json = #"""
        {"format":"wizrec-cursor-log","version":1,"coordinateSpace":"capturedPixels","origin":"topLeft","timeUnit":"seconds",
         "videoWidth":10,"videoHeight":10,"pixelsPerPoint":1,"sampleRate":60,"duration":2,"keystrokesLogged":true,
         "futureField":{"a":1},"cursors":[],
         "events":[{"t":0,"type":"hover","z":1},{"t":1,"type":"key","keyCode":12,"characters":"q","modifiers":["command"],"repeat":true},
                   {"t":1.5,"type":"down","button":"button4","x":1,"y":1}]}
        """#
        let log = try CursorLog.decode(Data(json.utf8))
        #expect(log.events[0].kind == .unknown("hover"))
        #expect(log.events[1].kind == .key(keyCode: 12, characters: "q", modifiers: ["command"], isRepeat: true))
        #expect(log.events[2].kind == .down(button: .other(4), x: 1, y: 1, clickCount: 1))
    }

    @Test func registryWritesEachDistinctImageOnce() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        func bitmap(_ v: UInt8, hot: Double = 1) -> CursorBitmap {
            CursorBitmap(width: 4, height: 2, hotspotX: hot, hotspotY: 0, pixels: Data(repeating: v, count: 32))
        }
        var r = CursorImageRegistry(directory: dir)
        #expect(r.id(for: bitmap(255)) == 0)
        #expect(r.id(for: bitmap(128)) == 1)
        #expect(r.id(for: bitmap(255)) == 0)
        #expect(r.id(for: bitmap(255, hot: 2)) == 2, "same pixels, other hot spot = other cursor")
        #expect(r.images.map(\.file) == ["cursors/cursor-0.png", "cursors/cursor-1.png", "cursors/cursor-2.png"])
        #expect(r.writeErrors == 0)
        let src = try #require(CGImageSourceCreateWithURL(dir.appendingPathComponent("cursors/cursor-1.png") as CFURL, nil))
        let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(img.width == 4 && img.height == 2)
    }

    @Test func renderScalesImageAndHotspot() throws {
        let one = CursorBitmap(width: 16, height: 16, hotspotX: 0, hotspotY: 0, pixels: Data(repeating: 200, count: 16 * 16 * 4))
        let img = try #require(one.cgImage())
        let r = try #require(CursorBitmap.render(img, pointSize: CGSize(width: 16, height: 16), hotspot: CGPoint(x: 4, y: 5), scale: 2))
        #expect(r.width == 32 && r.height == 32 && r.hotspotX == 8 && r.hotspotY == 10)
    }

    @Test func windowFrameMatchesWindowList() throws {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let w = list.first(where: { ($0[kCGWindowLayer as String] as? Int) == 0 }),
              let id = w[kCGWindowNumber as String] as? Int,
              let b = w[kCGWindowBounds as String] as? NSDictionary,
              let expected = CGRect(dictionaryRepresentation: b as CFDictionary) else { return } // no windows (CI)
        #expect(CursorLogger.windowFrame(CGWindowID(id)) == expected)
        #expect(CursorLogger.windowFrame(0xFFFF_FFF0) == nil)
    }

    /// The live logger needs no Screen Recording permission: sample the real cursor briefly.
    @MainActor @Test func liveLoggerSamplesCursor() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = RecordingClock()
        let main = CGDisplayBounds(CGMainDisplayID())
        let g = CaptureGeometry(sourceRect: main, pixelWidth: Int(main.width) * 2, pixelHeight: Int(main.height) * 2)
        let logger = CursorLogger(clock: clock, geometry: g, windowID: nil, sampleRate: 30, logKeystrokes: false, directory: dir)
        try logger.startMonitoring()
        clock.start(at: hostNow())
        logger.segmentStarted()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let log = logger.finish(duration: clock.stop(at: hostNow()))
        #expect(log.pixelsPerPoint == 2)
        #expect(log.events.first?.t == 0)
        guard case .move = log.events.first?.kind else { Issue.record("first event is not a move"); return }
        if let c = log.cursors.first {  // nil only without a window server session
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(c.file).path))
            #expect(c.width > 0 && c.hotspotX >= 0)
        }
    }

    @Test func modifierNames() {
        #expect(CursorLogger.modifierNames([.maskCommand, .maskShift]) == ["shift", "command"])
    }
}
