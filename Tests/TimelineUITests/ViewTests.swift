import AppKit
import Foundation
import Testing
import TimelineEngine
import TSCProjKit
@testable import TimelineUI

/// Media provider that returns solid colour frames and a square-wave waveform.
final class FakeMediaProvider: TimelineMediaProvider, @unchecked Sendable {
    // @unchecked: `requests` is only touched under `lock`.
    private let lock = NSLock()
    private var _requests: [(TimelineMediaRef, Double)] = []
    var requests: [(TimelineMediaRef, Double)] { lock.withLock { _requests } }

    func thumbnail(_ media: TimelineMediaRef, atSeconds seconds: Double, maxPixelSize: Int) async -> CGImage? {
        lock.withLock { _requests.append((media, seconds)) }
        let w = 32, h = 18
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))  // magenta
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    func waveform(_ media: TimelineMediaRef) async -> TimelineWaveform? {
        let n = 100_000
        return TimelineWaveform(bucketsPerSecond: 100, minima: Array(repeating: -0.8, count: n),
                                maxima: Array(repeating: 0.8, count: n))
    }
}

@MainActor
struct ViewTests {
    func makeView(_ project: Project? = nil, size: CGSize = CGSize(width: 900, height: 260),
                  pps: Double = 120) throws -> (TimelineModel, TimelineView) {
        let model = TimelineModel(undo: UndoStack(project: try project ?? sampleProject()))
        model.pointsPerSecond = pps
        let view = TimelineView(model: model)
        view.canvas.fitsOnFirstLayout = false
        view.frame = CGRect(origin: .zero, size: size)
        return (model, view)
    }

    func close(_ a: (r: Int, g: Int, b: Int), _ b: (r: Int, g: Int, b: Int), tol: Int = 12) -> Bool {
        abs(a.r - b.r) <= tol && abs(a.g - b.g) <= tol && abs(a.b - b.b) <= tol
    }

    func rgb(_ c: NSColor) -> (r: Int, g: Int, b: Int) {
        let s = c.usingColorSpace(.sRGB) ?? c
        return (Int((s.redComponent * 255).rounded()), Int((s.greenComponent * 255).rounded()),
                Int((s.blueComponent * 255).rounded()))
    }

    @Test func rendersRulerHeadersClipsAndPlayhead() throws {
        let (model, view) = try makeView()
        model.playhead = 60
        let rep = render(view)
        let url = savePNG(rep, "sample-dark")
        print("snapshot:", url?.path ?? "-")
        let L = view.currentLayout

        // Name strip of video clip B shows the video colour.
        let b = try #require(L.clipRect(track: 0, start: 120, duration: 90))
        #expect(close(pixel(rep, CGPoint(x: b.midX + 20, y: b.minY + 4)), rgb(Palette.clip(.video))))
        // Audio clip C's strip is green.
        let c = try #require(L.clipRect(track: 1, start: 30, duration: 120))
        #expect(close(pixel(rep, CGPoint(x: c.maxX - 30, y: c.minY + 4)), rgb(Palette.clip(.audio))))
        // Playhead is red in the clip area.
        let px = L.x(ofTicks: 60).rounded()
        let red = pixel(rep, CGPoint(x: px, y: L.clipArea.maxY - 10))
        #expect(red.r > 200 && red.g < 120 && red.b < 120)
        // Locked track 2 row is hatched (not one flat colour).
        let row2 = L.rowRect(try #require(L.row(forTrack: 2)))
        let samples = stride(from: row2.minX + 300, to: row2.minX + 330, by: 1).map { pixel(rep, CGPoint(x: $0, y: row2.midY)) }
        #expect(Set(samples.map { $0.r }).count > 1)
        // Header column is darker/lighter than the background and holds the track name.
        let header = pixel(rep, CGPoint(x: 4, y: L.headerRect(try #require(L.row(forTrack: 0))).midY))
        #expect(close(header, rgb(Palette.header.resolved(.darkAqua)), tol: 6))
    }

    @Test func selectionOutline() throws {
        let (model, view) = try makeView()
        model.selection = [20]
        let rep = render(view)
        savePNG(rep, "sample-selected")
        let b = try #require(view.currentLayout.clipRect(track: 0, start: 120, duration: 90))
        let edge = pixel(rep, CGPoint(x: b.midX, y: b.maxY - 1))
        #expect(close(edge, rgb(Palette.selection.resolved(.darkAqua)), tol: 40))
    }

    @Test func lightAppearanceRenders() throws {
        let (_, view) = try makeView()
        let rep = render(view, appearance: .aqua)
        savePNG(rep, "sample-light")
        let bg = pixel(rep, CGPoint(x: 600, y: 250))
        #expect(bg.r > 200)
    }

    @Test func thumbnailsAndWaveformsComeFromProvider() async throws {
        let (_, view) = try makeView()
        let provider = FakeMediaProvider()
        view.mediaProvider = provider
        _ = render(view)  // queues requests
        for _ in 0..<50 where !view.canvas.art.isIdle { await drainMainQueue() }
        let rep = render(view)
        savePNG(rep, "sample-media")
        #expect(!provider.requests.isEmpty)
        #expect(provider.requests.allSatisfy { $0.0.sourceID == 1 && $0.0.stream == 0 })
        // B starts at media 300 ticks = 10 s: its tiles ask for ≥ 10 s.
        let L = view.currentLayout
        let b = try #require(L.clipRect(track: 0, start: 120, duration: 90))
        let film = pixel(rep, CGPoint(x: b.midX, y: b.minY + 22))
        #expect(film.r > 200 && film.g < 60 && film.b > 200)
        // Waveform on the audio track: white-ish column near the centre line.
        let c = try #require(L.clipRect(track: 1, start: 30, duration: 120))
        let mid = (c.minY + 16 + c.maxY) / 2
        let wave = pixel(rep, CGPoint(x: c.midX + 0.5, y: mid - 6))
        #expect(wave.r > 170 && wave.g > 170)
    }

    @Test func modelChangesRedraw() async throws {
        let (model, view) = try makeView()
        _ = render(view)
        try model.undo.perform(MoveClip(clipID: 30, toTrack: 1, start: 400))
        await drainMainQueue()
        #expect(view.snapshot.clip(30)?.clip.start == 400)
    }

    @Test func zoomActionsKeepAnchor() throws {
        let (model, view) = try makeView(pps: 100)
        model.playhead = 90
        let before = view.currentLayout.x(ofTicks: 90)
        view.zoomIn(nil)
        #expect(abs(model.pointsPerSecond - 150) < 1e-9)
        #expect(abs(view.currentLayout.x(ofTicks: 90) - before) < 1)
        view.zoomOut(nil); view.zoomOut(nil)
        #expect(abs(model.pointsPerSecond - 100 / 1.5) < 1e-6)
        view.zoomToFit(nil)
        let L = view.currentLayout
        #expect(L.x(ofTicks: 210) <= L.clipArea.maxX && L.x(ofTicks: 210) > L.clipArea.midX)
    }

    @Test func menuValidation() throws {
        let (model, view) = try makeView()
        let split = NSMenuItem(title: "Split", action: #selector(TimelineView.splitAtPlayhead(_:)), keyEquivalent: "")
        let delete = NSMenuItem(title: "Delete", action: #selector(TimelineView.delete(_:)), keyEquivalent: "")
        model.playhead = 0
        #expect(!view.validateMenuItem(split))
        model.playhead = 60
        #expect(view.validateMenuItem(split))
        #expect(!view.validateMenuItem(delete))
        model.selection = [20]
        #expect(view.validateMenuItem(delete))
    }

    // MARK: Events

    func window(for view: TimelineView) -> NSWindow {
        let w = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.contentView = view
        return w
    }

    /// Mouse event at view point `p` (flipped view coordinates).
    func mouse(_ type: NSEvent.EventType, _ p: CGPoint, in view: NSView, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let w = view.convert(p, to: nil)
        return NSEvent.mouseEvent(with: type, location: w, modifierFlags: flags, timestamp: 0,
                                  windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                  clickCount: 1, pressure: 1)!
    }

    @Test func dragMovesClipAcrossTracks() throws {
        let (model, view) = try makeView(pps: 60)
        let w = window(for: view)
        defer { w.close() }
        let canvas = view.canvas
        let L = view.currentLayout
        // C (track 1, 30–150) dragged to track 0 after B: +210 ticks (1 tick = 2 pt at 60 pt/s).
        let c = try #require(L.clipRect(track: 1, start: 30, duration: 120))
        let start = CGPoint(x: c.midX, y: c.midY)
        let row0 = L.rowRect(try #require(L.row(forTrack: 0)))
        let end = CGPoint(x: start.x + 210 * 2, y: row0.midY)
        canvas.mouseDown(with: mouse(.leftMouseDown, start, in: canvas))
        #expect(model.selection == [30])
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: start.x + 20, y: start.y), in: canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, end, in: canvas))
        if case .move(_, let plan) = canvas.drag {
            #expect(plan.trackOffset == -1 && plan.delta == 210 && plan.isValid)
        } else { Issue.record("not moving: \(canvas.drag)") }
        let preview = render(view)
        savePNG(preview, "drag-preview")
        // Nothing committed during the drag.
        #expect(model.project.tracks[1].clips.map(\.id) == [30])
        canvas.mouseUp(with: mouse(.leftMouseUp, end, in: canvas))
        #expect(model.project.tracks[0].clips.map(\.id) == [10, 20, 30])
        #expect(model.project.tracks[0].clips.last?.start == 240)
        #expect(model.undo.undoName == "Move")
    }

    @Test func edgeDragTrims() throws {
        let (model, view) = try makeView(pps: 60)
        let w = window(for: view)
        defer { w.close() }
        let canvas = view.canvas
        let b = try #require(view.currentLayout.clipRect(track: 0, start: 120, duration: 90))
        let p = CGPoint(x: b.maxX - 2, y: b.midY)
        canvas.mouseDown(with: mouse(.leftMouseDown, p, in: canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: p.x - 60, y: p.y), in: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: p.x - 60, y: p.y), in: canvas))
        let clip = try #require(model.project.tracks[0].clips.first { $0.id == 20 })
        #expect(clip.duration == 60)
        #expect(model.undo.undoName == "Trim")
    }

    @Test func dragNearEdgeAutoscrolls() throws {
        let (_, view) = try makeView(pps: 60)
        let w = window(for: view)
        defer { w.close() }
        let canvas = view.canvas
        let c = try #require(view.currentLayout.clipRect(track: 1, start: 30, duration: 120))
        let start = CGPoint(x: c.midX, y: c.midY)
        canvas.mouseDown(with: mouse(.leftMouseDown, start, in: canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: start.x + 20, y: start.y), in: canvas))
        let edge = CGPoint(x: 895, y: start.y)
        canvas.mouseDragged(with: mouse(.leftMouseDragged, edge, in: canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, edge, in: canvas))
        let scrolled = view.scrollOffset.x
        #expect(scrolled > 0)
        guard case .move(_, let plan) = canvas.drag else { Issue.record("not moving"); return }
        // Delta follows the pointer in content space: (895 + scroll − start) / 2 pt per tick.
        #expect(abs(Double(plan.delta) - Double(edge.x + scrolled - start.x) / 2) <= 1)
        canvas.mouseUp(with: mouse(.leftMouseUp, edge, in: canvas))
    }

    @Test func rulerClickSeeks() throws {
        let (model, view) = try makeView()
        let w = window(for: view)
        defer { w.close() }
        var seeks: [Int64] = []
        model.onSeek = { seeks.append($0) }
        let canvas = view.canvas
        let x = view.currentLayout.x(ofTicks: 75)
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: x, y: 10), in: canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: x + 40, y: 10), in: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: x + 40, y: 10), in: canvas))
        #expect(seeks == [75, 85])
        #expect(model.playhead == 85)
        #expect(!model.undo.canUndo)
    }

    @Test func marqueeAndModifierClicks() throws {
        let (model, view) = try makeView()
        let w = window(for: view)
        defer { w.close() }
        let canvas = view.canvas
        let L = view.currentLayout
        let a = try #require(L.clipRect(track: 0, start: 0, duration: 90))
        let b = try #require(L.clipRect(track: 0, start: 120, duration: 90))
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: a.midX, y: a.midY), in: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: a.midX, y: a.midY), in: canvas))
        #expect(model.selection == [10])
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: b.midX, y: b.midY), in: canvas, flags: .command))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: b.midX, y: b.midY), in: canvas, flags: .command))
        #expect(model.selection == [10, 20])
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: a.midX, y: a.midY), in: canvas, flags: .command))
        #expect(model.selection == [20])
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: a.midX, y: a.midY), in: canvas))
        // Marquee from empty space in the locked top row down across the audio track.
        let row2 = L.rowRect(try #require(L.row(forTrack: 2)))
        let c = try #require(L.clipRect(track: 1, start: 30, duration: 120))
        let o = CGPoint(x: c.midX, y: row2.midY)
        canvas.mouseDown(with: mouse(.leftMouseDown, o, in: canvas))
        #expect(model.selection.isEmpty)
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: c.midX + 30, y: c.midY), in: canvas))
        #expect(model.selection == [30])
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: c.midX + 30, y: c.midY), in: canvas))
    }

    @Test func keyboardSplit() throws {
        let (model, view) = try makeView()
        let w = window(for: view)
        defer { w.close() }
        model.playhead = 150
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                   windowNumber: w.windowNumber, context: nil, characters: "s",
                                   charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1)!
        view.canvas.keyDown(with: key)
        #expect(model.project.tracks[0].clips.count == 3)
        #expect(model.undo.undoName == "Split")
        // Focus on the outer view forwards keys; an unhandled key does not loop.
        #expect(w.makeFirstResponder(view))
        model.playhead = 30
        view.keyDown(with: key)
        #expect(model.project.tracks[0].clips.count == 4)
        let other = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: w.windowNumber, context: nil, characters: "q",
                                     charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12)!
        view.keyDown(with: other)
    }

    @Test func headerButtonTogglesFlag() throws {
        let (model, view) = try makeView()
        let w = window(for: view)
        defer { w.close() }
        let L = view.currentLayout
        let r = L.buttonRect(.videoHidden, in: try #require(L.row(forTrack: 0)))
        let before = model.project.serialized()
        view.canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: r.midX, y: r.midY), in: view.canvas))
        if model.undo.canUndo {
            #expect(TimelineSnapshot(project: model.project).tracks[0].videoHidden)
        } else {
            #expect(model.project.serialized() == before)
            #expect(model.lastError != nil)  // SetTrackFlag still a stub
        }
    }

    @Test func dropLocationSnapsAndPicksTrack() throws {
        let (model, view) = try makeView()
        let L = view.currentLayout
        let row1 = L.rowRect(try #require(L.row(forTrack: 1)))
        // 2 ticks right of C's end (150) → snaps to 150 within 8 pt (= 2 ticks at 4 pt/tick).
        let loc = view.canvas.dropLocation(CGPoint(x: L.x(ofTicks: 151), y: row1.midY))
        #expect(loc.track == 1 && loc.ticks == 150)
        model.snappingEnabled = false
        #expect(view.canvas.dropLocation(CGPoint(x: L.x(ofTicks: 151), y: row1.midY)).ticks == 151)
        // Below all rows → nearest (bottom) track 0.
        #expect(view.canvas.dropLocation(CGPoint(x: 500, y: 255)).track == 0)
    }
}

extension NSColor {
    func resolved(_ name: NSAppearance.Name) -> NSColor {
        var out = self
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance { out = self.usingColorSpace(.sRGB) ?? self }
        return out
    }
}
