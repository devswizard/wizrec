import Foundation
import Testing
import TimelineEngine
import TSCProjKit
@testable import PlayerKit

// The inspector's Clip Speed fields (APP14-3, edit-semantics.md ED2b). 30 fps at Camtasia's
// editRate: one frame = 23 520 000 ticks; the ED2b clip is 300 frames (10 s).

private let tb = Timebase.camtasia
private let frame: Int64 = 23_520_000
private let grid30 = FrameGrid(timebase: tb, fps: Rational(30), duration: 0)

@Suite struct ClipSpeedFieldsTests {
    @Test func durationIsShownInSecondsAndFrames() {
        #expect(ClipSpeedFields.durationText(230 * frame, grid: grid30) == "0:07;20")
        #expect(ClipSpeedFields.durationText(161 * frame, grid: grid30) == "0:05;11")
        #expect(ClipSpeedFields.durationText(300 * frame, grid: grid30) == "0:10;00")
        #expect(ClipSpeedFields.durationText(0, grid: grid30) == "0:00;00")
        #expect(ClipSpeedFields.durationText((3600 * 30 + 62 * 30 + 4) * frame, grid: grid30) == "1:01:02;04")
        // A duration between frames shows the frame it is in (floored).
        #expect(ClipSpeedFields.durationText(161 * frame + frame - 1, grid: grid30) == "0:05;11")
    }

    @Test func typedSecondsAndFramesGiveThatFrame() {
        #expect(ClipSpeedFields.durationTicks("5;11", grid: grid30) == 161 * frame)
        #expect(ClipSpeedFields.durationTicks("0:05;11", grid: grid30) == 161 * frame)
        #expect(ClipSpeedFields.durationTicks("0:00:05;11", grid: grid30) == 161 * frame)
        #expect(ClipSpeedFields.durationTicks(" 1:00;00 ", grid: grid30) == 1800 * frame)
        #expect(ClipSpeedFields.durationTicks(";15", grid: grid30) == 15 * frame)
        // Frames beyond a second just count on (7;45 = 255 frames).
        #expect(ClipSpeedFields.durationTicks("7;45", grid: grid30) == 255 * frame)
    }

    @Test func typedSecondsGiveTicks() {
        #expect(ClipSpeedFields.durationTicks("7.5", grid: grid30) == tb.ticks(seconds: 7.5))
        #expect(ClipSpeedFields.durationTicks("1:07.5", grid: grid30) == tb.ticks(seconds: 67.5))
        #expect(ClipSpeedFields.durationTicks("0:01:07,5", grid: grid30) == tb.ticks(seconds: 67.5))
        #expect(ClipSpeedFields.durationTicks("12", grid: grid30) == 360 * frame)
        // A millisecond value shown just below a frame start keeps that frame (4/30 s = 0.1333…).
        #expect(ClipSpeedFields.durationTicks("0.133", grid: grid30) == 4 * frame)
        #expect(ClipSpeedFields.durationTicks("7.667", grid: grid30).map(grid30.index(of:)) == 230)
    }

    @Test func rejectsWhatIsNoDuration() {
        for bad in ["", "abc", "1:2:3:4", "5;x", "5;", "1.5;03", "-3", "1::2", "5;1;2", "inf", "nan"] {
            #expect(ClipSpeedFields.durationTicks(bad, grid: grid30) == nil, "\(bad)")
        }
    }

    @Test func roundTripsAtFractionalRates() {
        for fps in [Rational(30000, 1001), Rational(2997, 100), Rational(24000, 1001), Rational(25), Rational(60)] {
            let g = FrameGrid(timebase: tb, fps: fps, duration: 0)
            for n in stride(from: Int64(1), to: 5000, by: 37) {
                let ticks = g.ticks(ofFrame: n)
                let text = ClipSpeedFields.durationText(ticks, grid: g)
                #expect(ClipSpeedFields.durationTicks(text, grid: g).map(g.index(of:)) == n, "\(fps) \(n) \(text)")
            }
        }
    }

    @Test func speedShowsTwoDecimals() {
        #expect(ClipSpeedFields.speedText(300.0 / 157.0) == "1.91")   // typed 1.9 (ED2b)
        #expect(ClipSpeedFields.speedText(300.0 / 161.0) == "1.86")   // Duration 5;11
        #expect(ClipSpeedFields.speedText(1) == "1.00")
        #expect(ClipSpeedFields.speedText(0.5) == "0.50")
        #expect(ClipSpeedFields.speedText(.nan) == "1.00")
    }

    @Test func typedSpeedIsExactHundredths() {
        #expect(ClipSpeedFields.speed("1.9") == Rational(190, 100))
        #expect(ClipSpeedFields.speed("1,9") == Rational(190, 100))
        #expect(ClipSpeedFields.speed("2x") == Rational(200, 100))
        #expect(ClipSpeedFields.speed(" 0.5 × ") == Rational(50, 100))
        #expect(ClipSpeedFields.speed("1.234") == Rational(123, 100))
        for bad in ["", "0", "-1", "0.001", "x", "fast", "1000"] {
            #expect(ClipSpeedFields.speed(bad) == nil, "\(bad)")
        }
    }
}

/// The ED2b base: one 10 s VMFile (300 frames) alone on track 0.
@MainActor
private func ed2bProject() throws -> Project {
    let clip = """
    {"id" : 7, "_type" : "VMFile", "src" : 1, "trackNumber" : 0, "attributes" : {"ident" : "v"}, \
    "parameters" : {}, "effects" : [], "start" : 0, "duration" : \(300 * frame), "mediaStart" : 0, \
    "mediaDuration" : \(300 * frame), "scalar" : 1, \
    "metadata" : {"clipSpeedAttribute" : {"type" : "bool", "value" : false}, "effectApplied" : "none"}, "animationTracks" : {}}
    """
    let text = """
    {"editRate" : 705600000, "videoFormatFrameRate" : 30, "sourceBin" : [], "timeline" : {"id" : 1, \
    "sceneTrack" : {"scenes" : [{"csml" : {"tracks" : [{"trackIndex" : 0, "medias" : [\(clip)], "transitions" : []}]}}]}, \
    "trackAttributes" : [{"ident" : "", "audioMuted" : false, "videoHidden" : false, "magnetic" : false, "matte" : 0, "solo" : false}]}}
    """
    return try Project(data: Data(text.utf8))
}

@MainActor @Suite struct ClipSpeedInspectorTests {
    /// What the fields show after the edit the inspector sends for the typed text.
    private func shown(after command: any EditCommand) throws -> (duration: String, speed: String) {
        let p = try ed2bProject()
        try command.apply(to: p)
        let i = try #require(ClipInspection.make(project: p, clipID: 7, playhead: 0))
        return (ClipSpeedFields.durationText(i.duration, grid: grid30), ClipSpeedFields.speedText(i.speed))
    }

    @Test func typedDurationGoesThroughSetClipDuration() throws {
        // Duration 5;11 → 161 frames, scalar 161/300, Speed shows 1.86 (ED2b [obs]).
        let ticks = try #require(ClipSpeedFields.durationTicks("5;11", grid: grid30))
        let p = try ed2bProject()
        try SetClipDuration(clipID: 7, duration: ticks, ripple: true).apply(to: p)
        let clip = try #require(p.tracks.first?.clips.first)
        #expect(clip.duration == 161 * frame)
        #expect(clip.mediaDuration == Rational(300 * frame))
        #expect(clip.scalar == Rational(161, 300))
        let f = try shown(after: SetClipDuration(clipID: 7, duration: ticks, ripple: true))
        #expect(f.duration == "0:05;11")
        #expect(f.speed == "1.86")
    }

    @Test func typedSpeedShowsTheEffectiveSpeed() throws {
        // Speed 1.9 → 157 frames (floored), the field then shows 1.91 (ED2b [obs]).
        let r = try #require(ClipSpeedFields.speed("1.9"))
        let f = try shown(after: SetClipSpeed(clipID: 7, speed: r, ripple: true))
        #expect(f.duration == "0:05;07")
        #expect(f.speed == "1.91")
        let g = try shown(after: SetClipSpeed(clipID: 7, speed: try #require(ClipSpeedFields.speed("1.3")), ripple: true))
        #expect(g.duration == "0:07;20")
        #expect(g.speed == "1.30")
    }
}
