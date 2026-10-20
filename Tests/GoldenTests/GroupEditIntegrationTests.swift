import Foundation
import RenderEngine
import Testing
import TestGenKit
import TSCProjKit
import TimelineEngine

// S3-QA-1: group-inner track edits and media drops into groups (S3-TL-1), as
// command chains through an UndoStack on generated projects and on a temp copy
// of the user's demo project: invariants after every step, render evaluation of
// the dropped clips, byte-identical undo/redo, save → reopen → continue.

/// Clip ids drawn in `layers`, recursing into groups and transitions.
private func drawnClipIDs(_ layers: [Layer]) -> Set<Int64> {
    var out = Set<Int64>()
    for l in layers {
        switch l.content {
        case .group(let inner): out.insert(l.clipID); out.formUnion(drawnClipIDs(inner))
        case .transition(_, let from, let to): out.formUnion(drawnClipIDs([from, to].compactMap { $0 }))
        default: out.insert(l.clipID)
        }
    }
    return out
}

/// Whether clip `id` (or, for a unified/stitched clip, one of its parts) is drawn at `t`.
@MainActor
private func shows(_ id: Int64, at t: Int64, _ project: Project, _ bundle: ProjectBundle) -> Bool {
    guard let clip = locateClip(id, in: project) else { return false }
    var ids = Set<Int64>()
    clip.walk { c, _ in ids.insert(c.id) }
    let drawn = drawnClipIDs(SceneModel(project: project, resolve: bundle.resolve).evaluate(at: t).layers)
    return !drawn.isDisjoint(with: ids)
}

@Suite(.serialized) @MainActor struct GroupEditIntegrationTests {

    /// New bundle with one imported synthetic movie: A (video+audio, 60 frames),
    /// B (video only, 90 frames), C (image).
    private func generated(in dir: URL) async throws -> (ProjectBundle, a: Int64, b: Int64, c: Int64, chain: EditChain) {
        let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("grp.cmproj"), width: 320, height: 180)
        let movie = dir.appendingPathComponent("card.mp4")
        let card = TestCard(width: 160, height: 90, label: "G")
        _ = try await MediaWriter.writeH264(to: movie, width: 160, height: 90, fps: 30, frameCount: 30) { n, ctx in
            card.draw(frame: n, fps: 30, in: ctx)
        }
        let src = try bundle.importFile(movie)
        let chain = EditChain(bundle.project)
        let fixed = Date(timeIntervalSince1970: 1_792_376_869)
        let a = AddSource(movieDescriptor(src: src, frames: 60, audio: true)); a.addedAt = fixed
        let b = AddSource(movieDescriptor(src: src, frames: 90, audio: false)); b.addedAt = fixed
        let c = AddSource(imageDescriptor(src: "./media/still.png")); c.addedAt = fixed
        try chain.run(a); try chain.run(b); try chain.run(c)
        return (bundle, try #require(a.sourceID), try #require(b.sourceID), try #require(c.sourceID), chain)
    }

    /// Group-inner AddTrack/RemoveTrack and drops (timeline and inner time,
    /// group growth, nested groups under a speed change), rejected edits leave
    /// the bytes alone, the dropped clips render at the mapped times, then
    /// undo/redo walk, save/reopen, continue, undo-all.
    @Test func groupTrackAndDropChain() async throws {
        let dir = try scratchDir("grp-chain")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (bundle, sa, sb, sc, chain) = try await generated(in: dir)

        let a1 = try #require(try chain.run(InsertClip(sourceID: sa, track: 0, start: 0)).clipID)
        let a2 = try #require(try chain.run(InsertClip(sourceID: sa, track: 0, start: frames(60))).clipID)
        let g = try #require(try chain.run(GroupClips(clipIDs: [a1, a2])).groupID)
        func group(_ id: Int64) throws -> Clip { try #require(locateClip(id, in: chain.project)) }
        #expect(try group(g).tracks.count == 1)

        // Inner track above A, drop B at project time 10 → inner time 10 (group at 0, scalar 1).
        try chain.run(AddGroupTrack(group: g, at: 1))
        #expect(try group(g).tracks.count == 2)
        let b1 = try #require(try chain.run(InsertClipInGroup(sourceID: sb, group: g, track: 1, at: .timeline(frames(10)))).clipID)
        #expect(try group(g).tracks[1].clips.map(\.start) == [frames(10)])
        #expect(try group(g).duration == frames(120))

        // A drop in inner time that ends past the group grows it (100 + 90 = 190 frames).
        let b2 = try #require(try chain.run(InsertClipInGroup(sourceID: sb, group: g, track: 1, at: .inner(frames(100)))).clipID)
        #expect(try group(g).duration == frames(190))
        #expect(try group(g).mediaDuration == Rational(frames(190)))
        #expect(chain.project.duration == frames(190))

        // Overlap on the non-magnetic inner track and a drop left of the window are rejected.
        #expect(!chain.attempt(InsertClipInGroup(sourceID: sb, group: g, track: 1, at: .inner(frames(50)))))
        #expect(!chain.attempt(InsertClipInGroup(sourceID: sb, group: g, track: 1, at: .inner(-frames(5)))))
        #expect(!chain.attempt(AddGroupTrack(group: g, at: 5)))
        #expect(!chain.attempt(AddGroupTrack(group: a1, at: 0)))  // not a group

        // Bottom insert shifts B's track up; removing it shifts back.
        try chain.run(AddGroupTrack(group: g, at: 0))
        #expect(try group(g).tracks.map(\.clips.count) == [0, 2, 2])
        try chain.run(RemoveGroupTrack(group: g, at: 0))
        #expect(try group(g).tracks.map(\.clips.count) == [2, 2])

        // Render: inside the group, B shows from project frame 10; at frame 5 only A.
        func drawn(_ id: Int64, _ t: Int64) -> Bool { shows(id, at: t, chain.project, bundle) }
        #expect(drawn(g, frames(5)) && drawn(a1, frames(5)) && !drawn(b1, frames(5)))
        #expect(drawn(a1, frames(20)) && drawn(b1, frames(20)))
        #expect(drawn(b2, frames(150)) && !drawn(b1, frames(150)))

        // Nest: outer group of [g, image]; double speed on the outer group.
        let img = try #require(try chain.run(InsertClip(sourceID: sc, track: 0, start: frames(300))).clipID)
        let outer = try #require(try chain.run(GroupClips(clipIDs: [g, img])).groupID)
        #expect(!chain.attempt(RemoveGroupTrack(group: outer, at: 0)), "a group keeps at least one track")
        try chain.run(SetClipSpeed(clipID: outer, speed: Rational(2)))
        let outerStart = try group(outer).start
        // Project time t → inner time of g = (t − outerStart) × 2 (g sits at 0 in outer, scalar 1).
        let t = outerStart + frames(20)
        #expect(try GroupTiming.innerTime(group: g, timeline: t, in: chain.project) == Rational(frames(40)))
        #expect(try GroupTiming.timelineTime(group: g, inner: frames(40), in: chain.project) == Rational(t))
        try chain.run(AddGroupTrack(group: g, at: 2))
        let b3 = try #require(try chain.run(InsertClipInGroup(sourceID: sb, group: g, track: 2, at: .timeline(t))).clipID)
        #expect(try group(g).tracks[2].clips.map(\.start) == [frames(40)])
        #expect(drawn(outer, t + frames(1)) && drawn(b3, t + frames(1)))
        #expect(!drawn(b3, t - frames(1)))

        try chain.expectUndoRedoWalk()

        // Save, reopen: bytes equal, and the reopened project continues the chain.
        try bundle.saveWithBackup()
        let reopened = try ProjectBundle(url: bundle.directory)
        #expect(reopened.project.serialized() == chain.project.serialized())
        #expect(ProjectInvariants.check(reopened.project).isEmpty)
        let next = EditChain(reopened.project)
        try next.run(RemoveGroupTrack(group: g, at: 2))
        try next.run(InsertClipInGroup(sourceID: sa, group: g, track: 0, at: .inner(frames(120))))
        try next.expectUndoRedoWalk()
        try next.undoAll()

        try chain.undoAll()
    }

    /// A magnetic inner track takes a drop at the insertion point and packs; the
    /// group grows to the packed end.
    @Test func dropOnMagneticInnerTrackPacks() async throws {
        let dir = try scratchDir("grp-magnetic")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, sa, sb, _, chain) = try await generated(in: dir)
        let a1 = try #require(try chain.run(InsertClip(sourceID: sa, track: 0, start: 0)).clipID)
        let a2 = try #require(try chain.run(InsertClip(sourceID: sa, track: 0, start: frames(60))).clipID)
        let g = try #require(try chain.run(GroupClips(clipIDs: [a1, a2])).groupID)
        try chain.run(SetGroupTrackFlag(group: g, track: 0, .magnetic, true))
        let stack = chain
        let drop = try stack.run(InsertClipInGroup(sourceID: sb, group: g, track: 0, at: .inner(frames(30))))
        let inner = try #require(locateClip(g, in: stack.project)).tracks[0].clips
        #expect(inner.count == 3)
        #expect(zip(inner, inner.dropFirst()).allSatisfy { $0.end == $1.start }, "packed without gaps")
        #expect(inner.contains { $0.id == drop.clipID })
        #expect(try #require(locateClip(g, in: stack.project)).duration == frames(210))
        try stack.expectUndoRedoWalk()
        try stack.undoAll()
    }

    /// On a copy of the user's demo project: add/remove inner tracks of the real
    /// (effect-laden, nested) group and drop the demo's own source into it; save,
    /// reopen, undo back to the original bytes. The original stays untouched.
    @Test(.enabled(if: userDemoBundle != nil, "~/Documents/demo project.cmproj not present"))
    func groupEditsOnDemoCopy() throws {
        let original = try #require(userDemoBundle)
        let originalBytes = try Data(contentsOf: original.appendingPathComponent("project.tscproj"))
        let dir = try scratchDir("grp-demo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = try copyProjectOnly(original, into: dir)
        let bundle = try ProjectBundle(url: copy)
        let baseline = bundle.project.serialized()
        let chain = EditChain(bundle.project)

        let g = try #require(bundle.project.tracks.first?.clips.first { $0.kind == .group })
        let gid = g.id, n = g.tracks.count
        try chain.run(AddGroupTrack(group: gid, at: n))
        // Drop the first non-shader video source onto the new top inner track at the group's start.
        let source = try #require(bundle.project.sourceBin.first { $0.src.hasSuffix(".trec") || $0.src.hasSuffix(".mp4") || $0.src.hasSuffix(".mov") })
        let drop = try chain.run(InsertClipInGroup(sourceID: source.id, group: gid, track: n, at: .timeline(g.start)))
        let dropped = try #require(drop.clipID)
        #expect(shows(dropped, at: g.start + frames(1), chain.project, bundle))
        try chain.run(AddGroupTrack(group: gid, at: 0))
        try chain.run(RemoveGroupTrack(group: gid, at: 0))
        try chain.expectUndoRedoWalk()

        try bundle.saveWithBackup()
        #expect(try ProjectBundle(url: copy).project.serialized() == chain.project.serialized())
        try chain.undoAll()
        try bundle.saveWithBackup()
        #expect(try Data(contentsOf: bundle.projectFile) == baseline)
        #expect(try Data(contentsOf: original.appendingPathComponent("project.tscproj")) == originalBytes,
                "the user's demo project changed")
    }
}
