import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

// Clip Speed with a duration that is not a whole number of frames
// (edit-semantics.md ED2b [obs]). Projects use Camtasia's editRate 705600000
// at 30 fps: one frame = 23520000 ticks; the 10 s video is 300 frames.

private let frame: Int64 = 23_520_000

private func frames(_ n: Int64) -> Int64 { n * frame }

/// The ED2b base: one 10 s video clip (`mediaStart` `ms` frames, `mediaDuration` `md` frames)
/// alone on track 0, as Camtasia writes it (integer lexemes, `scalar` 1).
@MainActor
private func base(ms: Int64 = 0, md: Int64 = 300, dur: Int64? = nil) throws -> Project {
    let d = dur ?? md
    let text = """
    {"editRate" : 705600000, "videoFormatFrameRate" : 30, "sourceBin" : [], "timeline" : {"id" : 1, \
    "sceneTrack" : {"scenes" : [{"csml" : {"tracks" : [\(track(0, [clipText(ms: frames(ms), md: frames(md), dur: frames(d), scalar: "1")]))]}}]}, \
    "trackAttributes" : [{"ident" : "", "audioMuted" : false, "videoHidden" : false, "magnetic" : false, "matte" : 0, "solo" : false}]}}
    """
    return try Project(data: Data(text.utf8))
}

private func clipText(ms: Int64, md: Int64, dur: Int64, scalar: String, speedOn: Bool = false) -> String {
    """
    {"id" : 7, "_type" : "VMFile", "src" : 1, "trackNumber" : 0, "attributes" : {"ident" : "v"}, \
    "parameters" : {}, "effects" : [], "start" : 0, "duration" : \(dur), "mediaStart" : \(ms), \
    "mediaDuration" : \(md), "scalar" : \(scalar), \
    "metadata" : {"clipSpeedAttribute" : {"type" : "bool", "value" : \(speedOn)}, \
    "effectApplied" : "\(speedOn ? "Clip Speed" : "none")"}, "animationTracks" : {}}
    """
}

/// Expected track 0 after a speed edit: only `duration`, `scalar` and the two metadata keys change.
private func expected(ms: Int64 = 0, md: Int64 = 300, frames n: Int64, scalar: String) -> String {
    tracks(track(0, [clipText(ms: frames(ms), md: frames(md), dur: frames(n), scalar: #""\#(scalar)""#,
                              speedOn: true)]))
}

@MainActor
private func check(_ command: any EditCommand, on p: Project, _ want: String,
                   sourceLocation: SourceLocation = #_sourceLocation) throws {
    try expectReversible(command, on: p, sourceLocation: sourceLocation)
    try command.apply(to: p)
    try expectTracks(p, want, sourceLocation: sourceLocation)
    let saved = p.serialized()
    #expect(try Project(data: saved).serialized() == saved, sourceLocation: sourceLocation)
    try command.revert(on: p)
}

@MainActor @Test func speedFloorsDurationAndRecomputesScalar() throws {
    // Typed 1.3: 230.77 frames → 230, "23/30".
    try check(SetClipSpeed(clipID: 7, speed: Rational(13, 10)), on: try base(), expected(frames: 230, scalar: "23/30"))
    // Typed 0.7: 428.57 frames → 428 (floored, not rounded), "107/75".
    try check(SetClipSpeed(clipID: 7, speed: Rational(7, 10)), on: try base(), expected(frames: 428, scalar: "107/75"))
    // Typed 1.9: 157.89 frames → 157, "157/300" (effective 1.91×).
    try check(SetClipSpeed(clipID: 7, speed: Rational(19, 10)), on: try base(), expected(frames: 157, scalar: "157/300"))
}

@MainActor @Test func durationFieldFollowsTheSameRule() throws {
    // Duration typed as 5;11 = 161 frames: scalar 161/300.
    try check(SetClipDuration(clipID: 7, duration: frames(161)), on: try base(), expected(frames: 161, scalar: "161/300"))
    // A sub-frame duration is floored to the frame.
    try check(SetClipDuration(clipID: 7, duration: frames(161) + frame - 1), on: try base(),
              expected(frames: 161, scalar: "161/300"))
    expectRejected(SetClipDuration(clipID: 7, duration: 0), on: try base(), .invalid(""))
    let q = try makeProject(tracks: tracks(track(0, [leaf(1, type: "IMFile", start: 0, dur: 30, md: "1")])))
    expectRejected(SetClipDuration(clipID: 1, duration: 60), on: q, .invalid(""))
}

@MainActor @Test func speedOnTrimmedClipKeepsMediaRange() throws {
    // mediaStart 3 s, mediaDuration 7 s at 1.9: 110.53 frames → 110, "11/21".
    let p = try base(ms: 90, md: 210)
    try check(SetClipSpeed(clipID: 7, speed: Rational(19, 10)), on: p, expected(ms: 90, md: 210, frames: 110, scalar: "11/21"))
}

@MainActor @Test func frameExactSpeedMatchesTheReciprocal() throws {
    // ED2: 1.5 on 300 frames = 200 frames exactly; scalar "2/3" = 1 / speed, media range kept.
    try check(SetClipSpeed(clipID: 7, speed: Rational(3, 2)), on: try base(), expected(frames: 200, scalar: "2/3"))
    // Speed 2 gives the integer-free reduced "1/2"; speed 1/2 the integer 2.
    let p = try base()
    try SetClipSpeed(clipID: 7, speed: Rational(1, 2)).apply(to: p)
    #expect(p.tracks[0].clips[0].object["scalar"]?.int == 2)
    #expect(p.tracks[0].clips[0].object["mediaDuration"]?.int == frames(300))
}

@MainActor @Test func speedEditsThroughUndoStackAreByteIdentical() throws {
    let p = try base()
    let original = p.serialized()
    let stack = UndoStack(project: p)
    try stack.perform(SetClipSpeed(clipID: 7, speed: Rational(13, 10)))
    try stack.perform(SetClipSpeed(clipID: 7, speed: Rational(7, 10)))
    try stack.perform(SetClipDuration(clipID: 7, duration: frames(161)))
    try expectTracks(p, expected(frames: 161, scalar: "161/300"))
    let done = p.serialized()
    try stack.undo(); try stack.undo(); try stack.undo()
    #expect(p.serialized() == original)
    try stack.redo(); try stack.redo(); try stack.redo()
    #expect(p.serialized() == done)
}

@MainActor @Test func speedOnDemoProjectCopyIsLossless() throws {
    // A temp copy of the demo fixture, edited and saved, then reloaded.
    let src = try demoProject()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-ed2b-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("demo.tscproj")
    try src.serialized().write(to: url)
    let p = try Project(contentsOf: url)
    let original = p.serialized()
    let target = try #require(mediaClip(in: p))
    let mediaStart = target.object["mediaStart"]
    let mediaDuration = target.object["mediaDuration"]
    let speed = SetClipSpeed(clipID: target.id, speed: Rational(19, 10), ripple: true)
    try expectReversible(speed, on: p)
    try speed.apply(to: p)
    let after = try #require(clip(target.id, in: p))
    #expect(after.object["mediaStart"] == mediaStart)
    #expect(after.object["mediaDuration"] == mediaDuration)
    let s: Rational = after.scalar, md: Rational = after.mediaDuration
    #expect(try Exact.mul(md, s) == Rational(after.duration))
    try p.serialized().write(to: url)
    let reread = try Project(contentsOf: url)
    #expect(reread.serialized() == p.serialized())
    try speed.revert(on: p)
    #expect(p.serialized() == original)
}

/// Every clip of `p` at any depth, in tree order.
@MainActor private func allClips(_ p: Project) -> [Clip] {
    var out: [Clip] = []
    for t in p.tracks { for c in t.clips { c.walk { (inner: Clip, _: Int) in out.append(inner) } } }
    return out
}

/// The first video/screen/unified clip with a media range.
@MainActor private func mediaClip(in p: Project) -> Clip? {
    allClips(p).first { (c: Clip) -> Bool in
        ["VMFile", "ScreenVMFile", "UnifiedMedia"].contains(c.object["_type"]?.string ?? "") && c.mediaDuration.num > 0
    }
}

@MainActor private func clip(_ id: Int64, in p: Project) -> Clip? { allClips(p).first { $0.id == id } }
