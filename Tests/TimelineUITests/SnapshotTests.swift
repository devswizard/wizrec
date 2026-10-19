import Foundation
import Testing
import TSCProjKit
@testable import TimelineUI

@MainActor
struct SnapshotTests {
    @Test func tracksAndFlags() throws {
        let s = TimelineSnapshot(project: try sampleProject())
        #expect(s.tracks.count == 3)
        #expect(s.tracks.map(\.name) == ["Video", "Track 2", "Locked"])
        #expect(s.tracks.map(\.locked) == [false, false, true])
        #expect(s.duration == 210)
        #expect(s.frameTicks == 1)
        let t0 = s.tracks[0]
        #expect(t0.clips.map(\.id) == [10, 20])
        #expect(t0.clips[0].style == .unified)
        #expect(t0.clips[0].name == "clip.mp4")
        #expect(t0.clips[1].style == .video)
        #expect(s.tracks[1].clips[0].style == .audio)
        #expect(s.clip(30)?.track == 1)
    }

    @Test func unifiedSpansMapMedia() throws {
        let s = TimelineSnapshot(project: try sampleProject())
        let u = try #require(s.clip(10)?.clip)
        #expect(u.videoSpans.count == 1 && u.audioSpans.count == 1)
        #expect(u.videoSpans[0].media == TimelineMediaRef(sourceID: 1, src: "./media/1/clip.mp4", stream: 0))
        #expect(u.audioSpans[0].media.stream == 1)
        let v = try #require(s.clip(20)?.clip)
        // mediaStart 300 ticks at editRate 30 = 10 s; 30 ticks later = 11 s.
        #expect(abs(v.videoSpans[0].mediaSeconds(at: 150, editRate: 30) - 11) < 1e-9)
    }

    @Test func flagsHeightsAndStyles() throws {
        let p = try makeProject(
            tracks: tracksJSON(trackJSON(0, [
                vm(1, start: 0, dur: 30, type: "IMFile", src: 3),
                vm(2, start: 30, dur: 30, src: 4),
                #"{"id" : 3, "_type" : "Callout", "start" : 60, "duration" : 30, "mediaStart" : 0, "mediaDuration" : 30, "def" : {"text" : "Hello\nworld"}}"#,
            ])),
            attrs: "[\(attr(muted: true, hidden: true, magnetic: true, height: 90))]")
        let s = TimelineSnapshot(project: p)
        let t = s.tracks[0]
        #expect(t.audioMuted && t.videoHidden && t.magnetic && !t.locked)
        #expect(t.storedHeight == 90)
        #expect(t.clips.map(\.style) == [.image, .shader, .callout])
        #expect(t.clips[0].videoSpans.first?.rate == 0)
        #expect(t.clips[1].videoSpans.isEmpty)
        #expect(t.clips[2].name == "Hello")
    }

    @Test func stitchedSegmentsAndCuts() throws {
        // Inner timeline: seg A 0–60 (media 100…), seg B 60–150 (media 500…).
        // Window: mediaStart 30, mediaDuration 90 at 2× speed (scalar 1/2) → 45 ticks on the track.
        let segA = vm(41, start: 0, dur: 60, ms: 100, type: "AMFile", src: 2)
        let segB = vm(42, start: 60, dur: 90, ms: 500, type: "AMFile", src: 2)
        let stitched = """
        {"id" : 40, "_type" : "StitchedMedia", "start" : 300, "duration" : 45, "mediaStart" : 30, \
        "mediaDuration" : 90, "scalar" : "1/2", "medias" : [\(segA), \(segB)], "minMediaStart" : 0.0}
        """
        let s = TimelineSnapshot(project: try makeProject(tracks: tracksJSON(trackJSON(0, [stitched]))))
        let c = try #require(s.clip(40)?.clip)
        #expect(c.style == .stitched)
        #expect(abs(c.speed - 2) < 1e-9)
        // Cut at inner 60 → track 300 + (60 − 30) / 2 = 315.
        #expect(c.cuts == [315])
        #expect(c.audioSpans.count == 2)
        #expect(c.audioSpans[0].start == 300 && c.audioSpans[0].end == 315)
        // Segment A at inner 30 → media 130 ticks = 4.333 s; rate 2.
        #expect(abs(c.audioSpans[0].mediaStart - 130.0 / 30) < 1e-9)
        #expect(abs(c.audioSpans[0].rate - 2) < 1e-9)
        #expect(c.audioSpans[1].start == 315 && c.audioSpans[1].end == 345)
        #expect(abs(c.audioSpans[1].mediaStart - 500.0 / 30) < 1e-9)
    }

    @Test func groupLanes() throws {
        let inner = #"[{"trackIndex" : 0, "medias" : [\#(vm(51, start: 0, dur: 100))]}, {"trackIndex" : 1, "medias" : [\#(vm(52, start: 50, dur: 100, type: "AMFile", src: 2))]}]"#
        let group = """
        {"id" : 50, "_type" : "Group", "start" : 200, "duration" : 120, "mediaStart" : 20.0, \
        "mediaDuration" : 120.0, "scalar" : 1, "tracks" : \(inner), "attributes" : {"ident" : "Intro"}}
        """
        let s = TimelineSnapshot(project: try makeProject(tracks: tracksJSON(trackJSON(0, [group]))))
        let g = try #require(s.clip(50)?.clip)
        #expect(g.style == .group && g.name == "Intro")
        #expect(g.lanes.count == 2)
        #expect(g.lanes[0] == [TimelineLaneSpan(start: 200, end: 280, style: .video)])
        #expect(g.lanes[1] == [TimelineLaneSpan(start: 230, end: 320, style: .audio)])
    }

    @Test func transitionWindows() throws {
        let tr = """
        [{"name" : "Fade", "duration" : 20, "leftMedia" : 1, "rightMedia" : 2},
         {"name" : "FadeIn", "duration" : 10, "rightMedia" : 1},
         {"name" : "FadeOut", "duration" : 16, "leftMedia" : 2},
         {"name" : "Orphan", "duration" : 16, "leftMedia" : 99}]
        """
        let p = try makeProject(tracks: tracksJSON(trackJSON(0, [vm(1, start: 0, dur: 100), vm(2, start: 100, dur: 100)],
                                                             transitions: tr)))
        let t = TimelineSnapshot(project: p).tracks[0].transitions
        #expect(t.count == 3)
        #expect((t[0].start, t[0].end) == (90, 110))
        #expect((t[1].start, t[1].end) == (0, 10))
        #expect((t[2].start, t[2].end) == (184, 200))
    }

    @Test func demoFixtureProjects() throws {
        guard let url = Bundle.module.url(forResource: "demo", withExtension: "tscproj", subdirectory: "Fixtures") else {
            Issue.record("fixture missing"); return
        }
        let s = TimelineSnapshot(project: try Project(contentsOf: url))
        #expect(s.tracks.count == 2)
        let g = try #require(s.tracks[0].clips.first)
        #expect(g.style == .group)
        #expect(g.duration == 18_110_400_000)
        #expect(!g.lanes.isEmpty)
        #expect(s.frameTicks == 23_520_000)
    }
}
