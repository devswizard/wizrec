import Testing
import TSCProjKit
@testable import PlayerKit

private let tb = Timebase.camtasia

@Suite struct FrameGridTests {
    @Test func snapsToProjectFrames() {
        let g = FrameGrid(timebase: tb, fps: Rational(30), duration: tb.ticks(seconds: 10))
        #expect(g.index(of: 0) == 0)
        #expect(g.index(of: 23_520_000 - 1) == 0)      // one frame at 30 fps = 23 520 000 ticks
        #expect(g.index(of: 23_520_000) == 1)
        #expect(g.snap(23_520_000 * 5 + 17) == 23_520_000 * 5)
        #expect(g.frameCount == 300)
        #expect(g.lastFrame == 299)
        #expect(g.clamp(frame: 1000) == 299)
        #expect(g.clamp(frame: -3) == 0)
        #expect(g.snap(tb.ticks(seconds: 20)) == g.ticks(ofFrame: 299))
    }

    @Test func roundTripsFrameIndicesAtFractionalRates() {
        // 29.97 as "2997/100" does not divide 705600000: boundaries fall between ticks.
        for fps in [Rational(2997, 100), Rational(30000, 1001), Rational(24000, 1001), Rational(60), Rational(25)] {
            let g = FrameGrid(timebase: tb, fps: fps, duration: tb.ticks(seconds: 60))
            for i in stride(from: Int64(0), to: 1800, by: 7) {
                #expect(g.index(of: g.ticks(ofFrame: i)) == i)
                #expect(g.index(of: g.ticks(ofFrame: i) - 1) == max(0, i - 1))
            }
        }
    }

    @Test func oldFrameTimebase() {
        // Pre-2020 projects tick in frames (editRate 30).
        let g = FrameGrid(timebase: Timebase(editRate: 30), fps: Rational(30), duration: 90)
        #expect(g.index(of: 45) == 45)
        #expect(g.ticks(ofFrame: 45) == 45)
        #expect(g.lastFrame == 89)
    }

    @Test func rejectsZeroRate() {
        let g = FrameGrid(timebase: tb, fps: Rational(0), duration: 100)
        #expect(g.fps == Rational(30))
    }
}

@Suite struct PlaybackClockTests {
    @Test func runsAndHolds() {
        var c = PlaybackClock(editRate: 1000)
        #expect(c.ticks(atHost: 5) == 0)
        c.start(at: 200, host: 10)
        #expect(c.ticks(atHost: 10) == 200)
        #expect(c.ticks(atHost: 11.5) == 1700)
        c.stop(host: 12)
        #expect(c.ticks(atHost: 100) == 2200)
        c.start(at: c.ticks(atHost: 100), host: 100)
        #expect(c.ticks(atHost: 101) == 3200)
    }

    @Test func seekKeepsRunning() {
        var c = PlaybackClock(editRate: 1000)
        c.start(at: 0, host: 0)
        c.seek(to: 5000, host: 2)
        #expect(c.ticks(atHost: 3) == 6000)
        c.rate = 2
        c.seek(to: 0, host: 3)
        #expect(c.ticks(atHost: 4) == 2000)
    }

    @Test func resyncsOnlyBeyondTolerance() {
        var c = PlaybackClock(editRate: 1000)
        c.start(at: 0, host: 0)
        var r = c.resync(toTicks: 1010, atHost: 1, tolerance: 0.015)    // 10 ms: keep host clock
        #expect(!r)
        #expect(c.ticks(atHost: 1) == 1000)
        r = c.resync(toTicks: 1030, atHost: 1, tolerance: 0.015)        // 30 ms: follow audio
        #expect(r)
        #expect(c.ticks(atHost: 2) == 2030)
        c.stop(host: 2)
        r = c.resync(toTicks: 0, atHost: 3, tolerance: 0.015)
        #expect(!r)
    }

    @Test func audioPositionExtrapolatesFromRenderTime() {
        let p = PlaybackClock.audioPosition(sampleTime: 44100, sampleRate: 44100, renderHost: 100,
                                            atHost: 100.25, latency: 0.05)
        #expect(abs(p - 1.2) < 1e-9)
        #expect(PlaybackClock.audioPosition(sampleTime: 1, sampleRate: 0, renderHost: 0, atHost: 0) == 0)
    }
}

@Suite struct LaunchOptionsTests {
    @Test func parsesCaptionScripting() {
        let o = LaunchOptions(arguments: ["p.cmproj", "--import-captions", "in.srt", "--export-captions", "out.vtt"])
        #expect(o.paths == ["p.cmproj"])
        #expect(o.importCaptions == "in.srt" && o.exportCaptions == "out.vtt")
        #expect(o != LaunchOptions(arguments: ["p.cmproj"]))
        let e = LaunchOptions(arguments: ["--export", "/tmp/x.mp4", "--export-preset", "A", "--export-preset", "B"])
        #expect(e.exportPresets == ["A", "B"] && e.exportPath == "/tmp/x.mp4")
    }

    @Test func parsesPathsAndFlags() {
        let o = LaunchOptions(arguments: ["-NSDocumentRevisionsDebugMode", "YES", "--autoplay", "/a b.cmproj",
                                          "--seek", "3.5", "-psn_0_123", "--stats-log", "--no-audio",
                                          "--quit-after", "8", "x.tscproj"])
        #expect(o.paths == ["/a b.cmproj", "x.tscproj"])
        #expect(o.autoplay && o.statsLog && !o.audio && !o.overlay)
        #expect(o.seekSeconds == 3.5)
        #expect(o.quitAfter == 8)
    }

    /// `-Key value` argument-domain defaults (UI checks set the export folder this way) are not
    /// project paths.
    @Test func skipsArgumentDomainDefaults() {
        let o = LaunchOptions(arguments: ["-WizRec.ExportFolder", "/tmp/out", "p.cmproj", "-WizRec.Model", "",
                                          "-psn_0_1", "q.cmproj"])
        #expect(o.paths == ["p.cmproj", "q.cmproj"])
        #expect(!o.isScripted)
    }

    @Test func groupDropIsAScriptedStep() {
        let o = LaunchOptions(arguments: ["p.cmproj", "--group-drop", "a.mp4", "--group-drop", "b.png"])
        #expect(o.groupDropPaths == ["a.mp4", "b.png"] && o.paths == ["p.cmproj"])
        #expect(o.runsScript && o.isScripted)
        #expect(o != LaunchOptions(arguments: ["p.cmproj"]))
    }

    /// Scripted and timed runs never wait for the user: no relink sheet at open.
    @Test func scriptedRunsSkipTheRelinkSheet() {
        let user = LaunchOptions(arguments: ["p.cmproj", "--autoplay"])
        #expect(!user.isScripted && !user.runsScript)
        #expect(user.showsRelinkAtOpen(missing: 2))
        #expect(!user.showsRelinkAtOpen(missing: 0))
        for args in [["--quit-after", "3"], ["--export", "/tmp/x.mp4"], ["--snapshot-dir", "/tmp/s"],
                     ["--import", "a.mov"], ["--import-captions", "a.srt"], ["--export-captions", "a.vtt"]] {
            let o = LaunchOptions(arguments: ["p.cmproj"] + args)
            #expect(o.isScripted, "\(args)")
            #expect(!o.showsRelinkAtOpen(missing: 2), "\(args)")
        }
        #expect(!LaunchOptions(arguments: ["--quit-after", "3"]).runsScript)
        #expect(LaunchOptions(arguments: ["--export", "/tmp/x.mp4"]).runsScript)
    }
}

@Suite struct StatsTests {
    @Test func windowsAndCounters() {
        var a = StatsAccumulator(now: 0)
        a.display(timestamp: 0, period: 1.0 / 60, counting: true)
        a.display(timestamp: 1.0 / 60, period: 1.0 / 60, counting: true)
        a.display(timestamp: 4.0 / 60, period: 1.0 / 60, counting: true)   // two refreshes missed
        for i in 0..<60 { a.draw(frame: Int64(i / 2), cpuMs: 1, stale: i == 3) }
        a.fetch(ms: 0.5); a.fetch(ms: 10)
        a.gpu(ms: 0.5)
        #expect(a.flush(now: 0.5, clock: "host") == nil)
        let s = a.flush(now: 1, clock: "audio")
        #expect(s?.drawFPS == 60)
        #expect(s?.contentFPS == 30)
        #expect(s?.droppedDisplayFrames == 2)
        #expect(s?.staleDraws == 1)
        #expect(s?.fastFetchRatio == 0.5)
        #expect(s?.gpuMs == 0.5)
        #expect(s?.clock == "audio")
    }
}
