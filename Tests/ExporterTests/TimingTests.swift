import CoreGraphics
import CoreMedia
import Testing
import TSCProjKit
@testable import Exporter

struct FrameTimingTests {
    let E: Int64 = 705_600_000

    @Test func thirtyFPS() {
        let t = FrameTiming(editRate: E, fps: Rational(30), range: 0..<(150 * tpf))
        #expect(t.frameCount == 150)
        #expect(t.ticks(frame: 0) == 0 && t.ticks(frame: 1) == tpf && t.ticks(frame: 149) == 149 * tpf)
        #expect(t.presentationTime(frame: 30) == CMTime(value: 1, timescale: 1))
        #expect(t.duration.seconds == 5)
        #expect(t.timescale % 30 == 0 && t.timescale >= 600)
    }

    @Test func partialLastFrameCounts() {
        // A range ending one tick into frame 10 still exports frame 10.
        let t = FrameTiming(editRate: E, fps: Rational(30), range: 0..<(10 * tpf + 1))
        #expect(t.frameCount == 11)
        #expect(FrameTiming(editRate: E, fps: Rational(30), range: 0..<(10 * tpf)).frameCount == 10)
        #expect(FrameTiming(editRate: E, fps: Rational(30), range: 0..<1).frameCount == 1)
    }

    @Test func rangeOffset() {
        let t = FrameTiming(editRate: E, fps: Rational(30), range: (45 * tpf + 7)..<(60 * tpf))
        #expect(t.ticks(frame: 0) == 45 * tpf + 7)
        #expect(t.ticks(frame: 2) == 47 * tpf + 7)
        #expect(t.frameCount == 15)
    }

    @Test func ntscRateIsExactAndCeiled() {
        let fps = Rational(30000, 1001)
        let t = FrameTiming(editRate: E, fps: fps, range: 0..<(E * 10))
        // 705600000 · 1001 / 30000 = 23543520 exactly.
        #expect(t.ticks(frame: 1) == 23_543_520)
        #expect(t.frameCount == 300)  // 10 s × 29.97 = 299.7 → frames 0…299
        #expect(t.timescale == 30000)
        #expect(t.presentationTime(frame: 30000) == CMTime(value: 1001, timescale: 1))
        // Non-dividing rate: first tick of the frame, never before its exact start.
        let odd = FrameTiming(editRate: 1000, fps: Rational(3), range: 0..<10_000)
        #expect(odd.ticks(frame: 1) == 334 && odd.ticks(frame: 2) == 667 && odd.ticks(frame: 3) == 1000)
        #expect(odd.frameCount == 30)
    }

    @Test func matchesPlayerFrameGridRule() {
        // Player: index(of: t) = t·n / (E·d) (floor); ticks(ofFrame: i) = ceil(i·E·d / n).
        let fps = Rational(24000, 1001)
        let t = FrameTiming(editRate: E, fps: fps, range: 0..<(E * 3))
        for i in 0..<t.frameCount {
            let ticks = t.ticks(frame: i)
            #expect(ticks * fps.num / (E * fps.den) == Int64(i))
        }
    }

    @Test func longExportsDoNotOverflow() {
        let t = FrameTiming(editRate: E, fps: Rational(60000, 1001), range: 0..<(E * 3600 * 10))
        #expect(t.frameCount == 2_157_843)  // 10 h at 59.94
        #expect(t.ticks(frame: t.frameCount - 1) < E * 3600 * 10)
    }

    @Test func invalidRateFallsBack() {
        let t = FrameTiming(editRate: E, fps: Rational(0, 1), range: 0..<E)
        #expect(t.fps == Rational(30) && t.frameCount == 30)
    }

    @Test func aspectFit() {
        let c = CGSize(width: 1920, height: 1080)
        #expect(CGSize.aspectFit(c, in: CGSize(width: 1280, height: 720), even: true) == CGSize(width: 1280, height: 720))
        #expect(CGSize.aspectFit(CGSize(width: 1440, height: 1080), in: CGSize(width: 1920, height: 1080), even: true)
                == CGSize(width: 1440, height: 1080))
        #expect(CGSize.aspectFit(c, in: CGSize(width: 640, height: 640), even: false) == CGSize(width: 640, height: 360))
        #expect(CGSize.aspectFit(CGSize(width: 1001, height: 1000), in: CGSize(width: 501, height: 500), even: true)
                == CGSize(width: 500, height: 500))
    }
}
