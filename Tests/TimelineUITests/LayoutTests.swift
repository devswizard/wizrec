import CoreGraphics
import Foundation
import Testing
import TSCProjKit
@testable import TimelineUI

@MainActor
struct LayoutTests {
    func layout(pps: Double = 30, scrollX: CGFloat = 0, size: CGSize = CGSize(width: 1000, height: 400))
        throws -> (TimelineSnapshot, TimelineLayout) {
        let s = TimelineSnapshot(project: try sampleProject())
        return (s, TimelineLayout(snapshot: s, pointsPerSecond: pps, scrollX: scrollX, size: size))
    }

    @Test func tickXRoundTrip() throws {
        let (_, L) = try layout(pps: 30, scrollX: 50)
        // 30 pt/s at editRate 30 → 1 pt per tick.
        let x0 = L.metrics.headerWidth + L.metrics.leadingInset - 50
        #expect(L.x(ofTicks: 0) == x0)
        #expect(L.x(ofTicks: 120) == x0 + 120)
        for t: Int64 in [0, 1, 77, 120, 9999] { #expect(L.ticks(atX: L.x(ofTicks: t)) == t) }
        #expect(L.ticks(forWidth: 15) == 15)
        #expect(L.width(ofTicks: 30) == 30)
    }

    @Test func zoomAnchorKeepsTimeUnderCursor() throws {
        let (_, L) = try layout(pps: 30, scrollX: 40)
        let anchorX: CGFloat = 600
        let t = L.ticks(atX: anchorX)
        var Z = L
        Z.scrollX = L.scrollX(keeping: t, atX: anchorX, pointsPerSecond: 90)
        Z.pointsPerSecond = 90
        #expect(abs(Z.x(ofTicks: t) - anchorX) < 0.01)
    }

    @Test func rowsStackTrackZeroAtBottom() throws {
        let (_, L) = try layout()
        #expect(L.rows.map(\.trackIndex) == [2, 1, 0])
        let r2 = L.rowRect(try #require(L.row(forTrack: 2)))
        let r0 = L.rowRect(try #require(L.row(forTrack: 0)))
        #expect(r2.minY == L.metrics.rulerHeight)
        #expect(r0.minY > r2.minY)
        #expect(L.contentHeight == 3 * L.metrics.defaultTrackHeight + 2 * L.metrics.rowGap)
    }

    @Test func storedTrackHeightIsClamped() throws {
        let p = try makeProject(tracks: tracksJSON(trackJSON(0, []), trackJSON(1, [])),
                                attrs: "[\(attr(height: 78)), \(attr(height: 900))]")
        let L = TimelineLayout(snapshot: TimelineSnapshot(project: p), pointsPerSecond: 100, size: CGSize(width: 800, height: 300))
        #expect(L.row(forTrack: 0)?.height == 78)
        #expect(L.row(forTrack: 1)?.height == L.metrics.maxTrackHeight)
    }

    @Test func hitTesting() throws {
        let (s, L) = try layout()
        let row0 = try #require(L.row(forTrack: 0))
        let y0 = L.rowRect(row0).midY
        // Clip 20 spans 120–210 on track 0.
        let a = L.x(ofTicks: 120), b = L.x(ofTicks: 210)
        #expect(L.hit(CGPoint(x: (a + b) / 2, y: y0), in: s) == .clip(id: 20, track: 0, zone: .body))
        #expect(L.hit(CGPoint(x: a + 2, y: y0), in: s) == .clip(id: 20, track: 0, zone: .leadingEdge))
        #expect(L.hit(CGPoint(x: b - 2, y: y0), in: s) == .clip(id: 20, track: 0, zone: .trailingEdge))
        #expect(L.hit(CGPoint(x: L.x(ofTicks: 100), y: y0), in: s) == .track(0, ticks: 100))
        #expect(L.hit(CGPoint(x: 400, y: 5), in: s) == .ruler(ticks: L.ticks(atX: 400)))
        #expect(L.hit(CGPoint(x: 20, y: 5), in: s) == .corner)
        #expect(L.hit(CGPoint(x: 20, y: y0), in: s) == .header(track: 0, control: nil))
        let mute = L.buttonRect(.audioMuted, in: row0)
        #expect(L.hit(CGPoint(x: mute.midX, y: mute.midY), in: s) == .header(track: 0, control: .audioMuted))
        #expect(L.hit(CGPoint(x: 500, y: 390), in: s) == .empty(ticks: L.ticks(atX: 500)))
    }

    @Test func headerButtonsDoNotOverlap() throws {
        let (_, L) = try layout()
        let row = try #require(L.rows.first)
        let rects = TrackHeaderControl.allCases.map { L.buttonRect($0, in: row) }
        for i in rects.indices.dropLast() { #expect(rects[i].maxX <= rects[i + 1].minX) }
        #expect(rects.allSatisfy { L.headerRect(row).contains($0) })
    }

    @Test func marqueeSelection() throws {
        let (s, L) = try layout()
        let row0 = L.rowRect(try #require(L.row(forTrack: 0)))
        let row1 = L.rowRect(try #require(L.row(forTrack: 1)))
        // From tick 100 to 130 across tracks 1 and 0: hits C (30–150) and B (120–210), not A (0–90).
        let r = CGRect(x: L.x(ofTicks: 100), y: row1.midY, width: 30, height: row0.midY - row1.midY)
        #expect(L.clips(in: r, snapshot: s) == [20, 30])
    }

    @Test func zoomLimitsAndFit() {
        #expect(TimelineZoom.clamp(0) == 100)
        #expect(TimelineZoom.clamp(1e9) == TimelineZoom.maxPointsPerSecond)
        // 420 s into 1000 pt with a 5 % margin.
        let pps = TimelineZoom.fit(duration: 420 * 705_600_000, editRate: 705_600_000, width: 1000)
        #expect(abs(pps - 950.0 / 420) < 1e-9)
    }

    @Test func rulerScaleChoosesReadableSpacing() {
        let tight = RulerScale.choose(pointsPerSecond: 2000, fps: 30)
        #expect(tight.showsFrames && tight.major * 2000 >= 72)
        let normal = RulerScale.choose(pointsPerSecond: 100, fps: 30)
        #expect(normal.major == 1 && !normal.showsFrames)
        let wide = RulerScale.choose(pointsPerSecond: 2, fps: 30)
        #expect(wide.major == 60)
        for pps in stride(from: 0.5, through: 4000, by: 7.3) {
            let s = RulerScale.choose(pointsPerSecond: pps, fps: 60)
            #expect(s.major * pps >= 72 || s.major == 3600)
        }
    }

    @Test func timecodes() {
        let rate: Int64 = 705_600_000
        let fps = Rational(30)
        #expect(TimelineTimecode.full(0, editRate: rate, fps: fps) == "0:00:00;00")
        #expect(TimelineTimecode.full(65 * rate + 12 * 23_520_000, editRate: rate, fps: fps) == "0:01:05;12")
        #expect(TimelineTimecode.full(3661 * rate, editRate: rate, fps: fps) == "1:01:01;00")
        #expect(TimelineTimecode.label(65 * rate, editRate: rate, fps: fps, frames: false) == "1:05")
        #expect(TimelineTimecode.label(5 * rate + 3 * 23_520_000, editRate: rate, fps: fps, frames: true) == "0:05;03")
        // 29.97: last frame of a second never shows as 30.
        let ntsc = Rational(30000, 1001)
        #expect(TimelineTimecode.full(rate - 1, editRate: rate, fps: ntsc).hasSuffix(";29"))
        // The demo screen clip: 770 frames at 30 fps = 25 s + 20 frames (Camtasia shows 00:00:25;20).
        #expect(TimelineTimecode.full(18_110_400_000, editRate: rate, fps: fps) == "0:00:25;20")
    }

    @Test func frameQuantize() throws {
        let p = try makeProject(tracks: "[]", editRate: 705_600_000, fps: 30)
        let s = TimelineSnapshot(project: p)
        #expect(s.quantize(23_520_000 + 11_000_000) == 23_520_000)
        #expect(s.quantize(23_520_000 + 12_000_000) == 47_040_000)
    }
}
