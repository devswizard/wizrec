import CoreMedia
import Foundation
import Testing
import TSCProjKit
@testable import RenderEngine

private let s = P.rate

@Test func audioClipIsClippedToRange() throws {
    let p = try P.project(tracks: [P.track(0, [
        P.clip("AMFile", id: 10, src: 4, start: s, duration: 4 * s, mediaStart: 2 * s,
               parameters: ["volume": 0.5], attributes: ["gain": 0.8]),
    ])])
    let scene = P.scene(p)
    let segs = scene.audioSegments(in: 2 * s ..< 10 * s)
    #expect(segs.count == 1)
    let a = try #require(segs.first)
    #expect(a.clipID == 10 && a.stream == 0)
    #expect(a.url.lastPathComponent == "c.m4a")
    #expect(a.timelineRange == 2 * s ..< 5 * s)
    #expect(a.mediaStart == CMTime(value: 3 * s, timescale: Int32(s)))
    #expect(a.rate == 1)
    #expect(approx(a.gain, 0.4))
    #expect(scene.audioSegments(in: 0 ..< s).isEmpty)
    #expect(scene.audioSegments(in: 5 * s ..< 6 * s).isEmpty)
}

@Test func unifiedAudioHalfAndMutedTracks() throws {
    let u = P.clip("UnifiedMedia", id: 20, start: 0, duration: s, extra: [
        "video": P.clip("VMFile", id: 21, src: 1, start: 0, duration: s),
        "audio": P.clip("AMFile", id: 22, src: 1, trackNumber: 1, start: 0, duration: s),
    ])
    let p = try P.project(tracks: [
        P.track(0, [u]),
        P.track(1, [P.clip("AMFile", id: 30, src: 4, start: 0, duration: s)]),
    ], trackAttributes: [["audioMuted": false], ["audioMuted": true]])
    let segs = P.scene(p).audioSegments(in: 0 ..< s)
    #expect(segs.map(\.clipID) == [22])
    #expect(segs.first?.stream == 1)
}

@Test func nestedScalarsAndGainsMultiply() throws {
    // Group at 10 s, 2× speed (scalar 1/2), gain 0.5; child audio 1.5× (scalar 2/3), volume 0.5.
    let g = P.clip("Group", id: 40, start: 10 * s, duration: 4 * s, mediaStart: s, scalar: "1/2",
                   parameters: ["volume": 1.0], attributes: ["gain": 0.5], extra: [
        "tracks": [P.track(0, [
            P.clip("AMFile", id: 41, src: 4, start: 2 * s, duration: 30 * s, mediaStart: 100, scalar: "2/3",
                   parameters: ["volume": 0.5]),
        ])],
    ])
    let p = try P.project(tracks: [P.track(0, [g])])
    let segs = P.scene(p).audioSegments(in: 0 ..< 100 * s)
    let a = try #require(segs.first)
    #expect(segs.count == 1)
    // Inner 2 s ↔ timeline 10 s + (2 s − 1 s) × 1/2 = 10.5 s; group ends at 14 s.
    #expect(a.timelineRange == 10 * s + s / 2 ..< 14 * s)
    #expect(a.mediaStart.value == 100)
    #expect(approx(a.rate, 3))  // 2× · 1.5×
    #expect(approx(a.gain, 0.25))
}

@Test func stitchedAudioSplitsAtSegmentBoundary() throws {
    func seg(_ id: Int, start: Int64, dur: Int64, ms: Int64) -> [String: Any] {
        P.clip("UnifiedMedia", id: id, start: start, duration: dur, mediaStart: ms, extra: [
            "video": P.clip("VMFile", id: id + 1, src: 1, start: start, duration: dur, mediaStart: ms),
            "audio": P.clip("AMFile", id: id + 2, src: 1, trackNumber: 1, start: start, duration: dur, mediaStart: ms),
        ])
    }
    let st = P.clip("StitchedMedia", id: 40, start: 100 * s, duration: 6 * s, mediaStart: 2 * s, extra: [
        "medias": [seg(41, start: 0, dur: 5 * s, ms: 0), seg(44, start: 5 * s, dur: 10 * s, ms: 50 * s)],
    ])
    let p = try P.project(tracks: [P.track(0, [st])])
    let segs = P.scene(p).audioSegments(in: 0 ..< 200 * s)
    #expect(segs.map(\.clipID) == [43, 46])
    #expect(segs.map(\.timelineRange) == [100 * s ..< 103 * s, 103 * s ..< 106 * s])
    #expect(segs.map(\.mediaStart.value) == [2 * s, 50 * s])
}

@Test func demoAudioIsTheTrecAacStream() throws {
    let p = try Project(contentsOf: fixtureURL("demo.tscproj"))
    let scene = SceneModel(project: p) { URL(fileURLWithPath: "/demo").appendingPathComponent($0.src) }
    let segs = scene.audioSegments(in: 0 ..< scene.duration)
    #expect(segs.map(\.clipID) == [9])
    #expect(segs.first?.stream == 2)
    #expect(segs.first?.timelineRange == 0 ..< 18_086_880_000)
}

@Test(.enabled(if: FileManager.default.fileExists(atPath: vlogBundleURL.path)))
func vlogAudioSegmentsAreContiguousOnVideoTrack() throws {
    let bundle = try ProjectBundle(url: vlogBundleURL)
    let scene = SceneModel(project: bundle.project, resolve: bundle.resolve)
    let segs = scene.audioSegments(in: 0 ..< scene.duration)
    #expect(!segs.isEmpty)
    // Clip 82: stitched at 304/457 → its audio plays at 457/304× speed.
    let fast = segs.filter { $0.clipID == 85 || $0.clipID == 88 }
    #expect(fast.count == 2)
    #expect(fast.allSatisfy { approx($0.rate, 457.0 / 304.0) })
    #expect(fast[0].timelineRange.upperBound == fast[1].timelineRange.lowerBound)
    #expect(fast[0].timelineRange.lowerBound == 23_531_760_000)
    #expect(fast[1].timelineRange.upperBound == 23_531_760_000 + 3_575_040_000)
}
