import CoreMedia
import Testing
@testable import Recorder

/// Host time `s` seconds after an arbitrary base, exact at 1/3000 s.
func h(_ s: Double) -> CMTime { CMTime(value: Int64(((1000 + s) * 3000).rounded()), timescale: 3000) }
func sec(_ t: CMTime?) -> Double? { t.map { (CMTimeGetSeconds($0) * 1000).rounded() / 1000 } }

@Suite struct TimelineStitcherTests {
    @Test func dropsBeforeStartAndMapsFromZero() {
        var s = TimelineStitcher()
        #expect(s.map(h(0)) == nil)
        s.start(at: h(1))
        #expect(s.map(h(0.5)) == nil)
        #expect(sec(s.map(h(1))) == 0)
        #expect(sec(s.map(h(2.5))) == 1.5)
    }

    @Test func pauseIsCutOutWithoutGap() {
        var s = TimelineStitcher()
        s.start(at: h(0))
        s.pause(at: h(1))
        #expect(s.map(h(1.5)) == nil)
        #expect(sec(s.recordingTime(at: h(1.7))) == 1)
        #expect(sec(s.resume(at: h(3))) == 1)
        #expect(sec(s.map(h(0.999))) == 0.999)
        #expect(sec(s.map(h(3))) == 1)
        #expect(sec(s.map(h(4))) == 2)
        s.pause(at: h(5)); s.resume(at: h(5.5))
        #expect(sec(s.map(h(6))) == 3.5)
        #expect(sec(s.stop(at: h(7))) == 4.5)
        #expect(s.map(h(7)) == nil)
        #expect(sec(s.recordingTime(at: h(99))) == 4.5)
    }

    @Test func stopWhilePausedEndsAtPausePoint() {
        var s = TimelineStitcher()
        s.start(at: h(0)); s.pause(at: h(2))
        #expect(sec(s.stop(at: h(10))) == 2)
        #expect(s.map(h(5)) == nil)
    }

    @Test func pauseAndResumeAreIdempotent() {
        var s = TimelineStitcher()
        s.pause(at: h(0)) // before start: ignored
        #expect(s.pauses.isEmpty)
        s.start(at: h(0)); s.pause(at: h(1)); s.pause(at: h(2))
        #expect(s.pauses.count == 1)
        s.resume(at: h(3))
        #expect(s.resume(at: h(4)) == nil)
        #expect(sec(s.map(h(4))) == 2)
    }

    @Test func audioBufferStraddlingPauseOrStopIsDropped() {
        var s = TimelineStitcher()
        s.start(at: h(0)); s.pause(at: h(1)); s.resume(at: h(2))
        let d = CMTime(value: 60, timescale: 3000) // 20 ms
        #expect(sec(s.map(h(0.9), duration: d)) == 0.9)
        #expect(s.map(h(0.99), duration: d) == nil)
        #expect(sec(s.map(h(2), duration: d)) == 1)
        s.stop(at: h(3))
        #expect(s.map(h(2.99), duration: d) == nil)
        #expect(sec(s.map(h(2.98), duration: d)) == 1.98)
    }
}

@Suite struct VideoFrameGateTests {
    @Test func heldFrameStartsTheFileAtZero() {
        var s = TimelineStitcher()
        var g = VideoFrameGate<Int>()
        #expect(g.offer(1, hostTime: h(-0.2), timeline: s).isEmpty)
        #expect(g.offer(2, hostTime: h(-0.1), timeline: s).isEmpty)
        s.start(at: h(0))
        let out = g.activate(timeline: s)
        #expect(out.map(\.0) == [2] && out.map { sec($0.1) } == [0])
        let next = g.offer(3, hostTime: h(0.5), timeline: s)
        #expect(next.map(\.0) == [3] && next.map { sec($0.1) } == [0.5])
    }

    @Test func firstFrameAfterStartIsPulledToZero() {
        var s = TimelineStitcher()
        s.start(at: h(0))
        var g = VideoFrameGate<Int>()
        #expect(g.offer(1, hostTime: h(0.3), timeline: s).map { sec($0.1) } == [0])
        #expect(g.offer(2, hostTime: h(0.4), timeline: s).map { sec($0.1) } == [0.4])
    }

    @Test func frameFromPauseShowsAtResumePoint() {
        var s = TimelineStitcher()
        s.start(at: h(0))
        var g = VideoFrameGate<Int>()
        _ = g.offer(1, hostTime: h(0), timeline: s)
        s.pause(at: h(1))
        #expect(g.offer(2, hostTime: h(1.5), timeline: s).isEmpty)
        s.resume(at: h(2))
        // A frame racing ahead of activate() flushes the held one first, in order.
        let out = g.offer(3, hostTime: h(2.5), timeline: s)
        #expect(out.map(\.0) == [2, 3])
        #expect(out.map { sec($0.1) } == [1, 1.5])
        #expect(g.activate(timeline: s).isEmpty)
    }

    @Test func outputIsStrictlyIncreasing() {
        var s = TimelineStitcher()
        s.start(at: h(0))
        var g = VideoFrameGate<Int>()
        _ = g.offer(1, hostTime: h(1), timeline: s)
        _ = g.offer(2, hostTime: h(2), timeline: s)
        #expect(g.offer(3, hostTime: h(1.5), timeline: s).isEmpty)
        s.stop(at: h(3))
        #expect(g.offer(4, hostTime: h(3.5), timeline: s).isEmpty)
        #expect(g.activate(timeline: s).isEmpty)
    }
}
