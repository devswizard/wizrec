import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

// TL15-1: a new project starts with two empty tracks (ui-workflow §2 [obs]).
// The edit commands treat them as ordinary empty tracks.

private let frame: Int64 = 23_520_000

/// A 10 s 1920×1080 video source.
private let bin = """
[{"id" : 1, "src" : "./media/1/video.mp4", "rect" : [0, 0, 1920, 1080], "sourceTracks" : [\
{"range" : [0, 300], "type" : 0, "editRate" : 30, "trackRect" : [0, 0, 1920, 1080], "numChannels" : 0}]}]
"""

@MainActor private func fresh() throws -> Project {
    let p = ProjectTemplate.newProject(width: 1920, height: 1080, fps: 30)
    p.root["sourceBin"] = try JSON.parse(bin)
    return p
}

@MainActor @Test func newProjectHasTwoEmptyTracks() throws {
    let p = ProjectTemplate.newProject(width: 1920, height: 1080, fps: 30)
    try expectTracks(p, tracks(track(0, []), track(1, [])))
    #expect(p.timeline?.trackAttributes.count == 2)
}

@MainActor @Test func canvasDropOnNewProjectLandsOnTrackZero() throws {
    let p = try fresh()
    let drop = DropClip(sourceID: 1, .canvas(playhead: 0))
    try expectReversible(drop, on: p)
    try drop.apply(to: p)
    #expect(drop.placement == DropPlacement(rule: .lowestTrackWithRoom, track: 0, start: 0))
    #expect(p.tracks.count == 2 && p.tracks[0].clips.count == 1 && p.tracks[1].clips.isEmpty)
}

@MainActor @Test func timelineDropsOnNewProjectUseBothTracks() throws {
    let p = try fresh()
    let upper = DropClip(sourceID: 1, .timeline(track: 1, at: .timeline(30 * frame)))
    try expectReversible(upper, on: p)
    try upper.apply(to: p)
    #expect(upper.placement == DropPlacement(rule: .target, track: 1, start: 30 * frame))
    #expect(p.tracks.count == 2 && p.tracks[1].clips.map(\.start) == [30 * frame])

    // Above the top track: a third track.
    let above = DropClip(sourceID: 1, .timeline(track: 2, at: .timeline(0)))
    try expectReversible(above, on: p)
    try above.apply(to: p)
    #expect(above.placement?.rule == .newTopTrack && above.placement?.track == 2)
    #expect(p.tracks.count == 3 && p.timeline?.trackAttributes.count == 3)
}

@MainActor @Test func trackCommandsOnNewProjectAreByteReversible() throws {
    let p = try fresh()
    try expectReversible(AddTrack(at: 2), on: p)
    try expectReversible(AddTrack(at: 0), on: p)
    try expectReversible(RemoveTrack(at: 1), on: p)
    let remove = RemoveTrack(at: 1)
    try remove.apply(to: p)
    #expect(p.tracks.map(\.index) == [0] && p.timeline?.trackAttributes.count == 1)
}
