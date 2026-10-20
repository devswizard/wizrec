import CoreGraphics
import Foundation
import MediaEngine
import Metal
import RenderEngine
import Testing
import TestGenKit
import TimelineEngine
import TSCProjKit

// S5-QA-1 / timeline7: the observed group rules end to end. Chains ungroup → group → move →
// trim-start → split → ungroup through an UndoStack, and checks after each structural step that
// OfflineRenderer draws the same frames (grouping and ungrouping must not change the picture),
// that save → reopen is lossless, and that undo-all returns the original bytes.

/// Renders `project` at `ticks`, small; media resolved through bundle `resolve` (the user's bundle is
/// read in place, never copied).
@MainActor
private func frame(_ project: Project, _ resolve: ProjectBundle, at ticks: Int64,
                   size: CGSize = CGSize(width: 480, height: 270)) async throws -> RGBAImage {
    let r = OfflineRenderer(scene: SceneModel(project: project, resolve: resolve.resolve), pool: MediaPool(diskCacheDirectory: nil))
    return RGBAImage(try await r.image(at: ticks, size: size))
}

/// Mean absolute RGB difference, 0–255.
private func meanAbsDiff(_ a: RGBAImage, _ b: RGBAImage) -> Double {
    guard a.width == b.width, a.height == b.height else { return 255 }
    var sum = 0
    for i in stride(from: 0, to: a.pixels.count, by: 4) {
        for c in 0..<3 { sum += abs(Int(a.pixels[i + c]) - Int(b.pixels[i + c])) }
    }
    return Double(sum) / Double(a.width * a.height * 3)
}

/// Guards against vacuous comparisons: every reference frame has content (not one flat colour),
/// and frames at different times differ (the clip moves through time).
private func expectInformative(_ refs: [RGBAImage], sourceLocation: SourceLocation = #_sourceLocation) {
    for (i, r) in refs.enumerated() {
        let first = r.pixel(0, 0)
        var distinct = 0
        for y in stride(from: 0, to: r.height, by: 7) {
            for x in stride(from: 0, to: r.width, by: 7) where r.pixel(x, y) != first { distinct += 1 }
        }
        #expect(distinct > 50, "reference \(i) is flat", sourceLocation: sourceLocation)
    }
    #expect(zip(refs, refs.dropFirst()).contains { meanAbsDiff($0, $1) > 1 }, "references do not change over time",
            sourceLocation: sourceLocation)
}

/// Top-level clip ids on every track, in track order.
private func topLevel(_ p: Project) -> [Int64] { p.tracks.flatMap { $0.clips.map(\.id) } }

@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
@MainActor struct GroupRulesIntegrationTests {
    /// Frames compared at each step: `before` rendered at `times`, `after` at `times + shift`.
    private func expectSameFrames(_ step: String, _ before: [RGBAImage], _ project: Project,
                                  _ resolve: ProjectBundle, times: [Int64], shift: Int64 = 0,
                                  tolerance: Double = 0.5) async throws {
        for (t, ref) in zip(times, before) {
            let now = try await frame(project, resolve, at: t + shift)
            let d = meanAbsDiff(ref, now)
            if d > 0 { print(String(format: "group rules %@ @%lld: mean |Δ| %.3f", step, t / frameTicks, d)) }
            #expect(d <= tolerance, "\(step): frame \(t / frameTicks) changed (mean |Δ| \(d))")
        }
    }

    /// Two red stills at different positions/scales on two tracks: group → move → trim-start →
    /// split → ungroup, with renders, save/reopen and undo-all. Runs everywhere.
    @Test func generatedChainKeepsFrames() async throws {
        let dir = try scratchDir("s5-group-gen")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundleURL = dir.appendingPathComponent("g.cmproj", isDirectory: true)
        let media = bundleURL.appendingPathComponent("media/1", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let card = TestCard(width: 320, height: 180, label: "G")
        let movie = try MediaWriter.writeH264(to: media.appendingPathComponent("g.mp4"), width: 320, height: 180,
                                              fps: 30, frameCount: 120) { n, ctx in card.draw(frame: n, fps: 30, in: ctx) }
        let b = ProjectBuilder(title: "g", width: 640, height: 360)
        let src = b.addVideoSource(src: "./media/1/g.mp4", movie: movie, modified: Date(timeIntervalSince1970: 1_792_000_000))
        b.tracks = [
            [b.video(src, start: 0, duration: b.frames(90), params: ["translation0": .constant(-120), "scale0": .constant(0.8),
                                                                      "scale1": .constant(0.8)])],
            [b.video(src, start: b.frames(15), duration: b.frames(90), mediaStart: b.frames(10),
                     params: ["translation0": .constant(140), "translation1": .constant(60), "rotation2": .constant(0.3)])],
        ]
        try b.build().serialized().write(to: bundleURL.appendingPathComponent("project.tscproj"), options: .atomic)
        let bundle = try ProjectBundle(url: bundleURL)
        let resolve = bundle
        let original = bundle.project.serialized()
        let chain = EditChain(bundle.project)
        let times = [frames(5), frames(20), frames(60), frames(100)]
        var ref: [RGBAImage] = []
        for t in times { ref.append(try await frame(bundle.project, resolve, at: t)) }
        expectInformative(ref)

        let ids = topLevel(chain.project)
        let g = try #require(try chain.run(GroupClips(clipIDs: ids)).groupID)
        #expect(topLevel(chain.project) == [g])
        try await expectSameFrames("group", ref, chain.project, resolve, times: times)

        // Move the group 30 frames later onto track 1: the same pictures, 30 frames later.
        try chain.run(MoveClip(clipID: g, toTrack: 1, start: frames(30)))
        let unshifted = try await frame(chain.project, resolve, at: times[1])
        #expect(meanAbsDiff(unshifted, ref[1]) > 1, "the move did not change the frame at its old time")
        try await expectSameFrames("move", ref, chain.project, resolve, times: times, shift: frames(30))

        // Trim the start by 10 frames: inner clips trimmed, later frames unchanged.
        try chain.run(TrimClip(clipID: g, edge: .start, to: frames(40)))
        try await expectSameFrames("trim-start", Array(ref[1...]), chain.project, resolve, times: Array(times[1...]),
                                   shift: frames(30))

        // Split at timeline frame 80 (inner 50): two groups, same frames on both sides.
        let right = try #require(try chain.run(SplitClip(clipID: g, at: frames(80))).rightID)
        #expect(Set(topLevel(chain.project)) == [g, right])
        try await expectSameFrames("split", Array(ref[1...]), chain.project, resolve, times: Array(times[1...]),
                                   shift: frames(30))

        // Ungroup the right half: its inner clips come out cut to the group and composed.
        let released = try chain.run(UngroupClip(clipID: right)).releasedIDs
        #expect(!released.isEmpty)
        try await expectSameFrames("ungroup", Array(ref[1...]), chain.project, resolve, times: Array(times[1...]),
                                   shift: frames(30))
        try chain.expectUndoRedoWalk()

        try bundle.saveWithBackup()
        let reopened = try ProjectBundle(url: bundleURL)
        #expect(reopened.project.serialized() == chain.project.serialized())
        #expect(ProjectInvariants.check(reopened.project).isEmpty)
        try await expectSameFrames("reopen", Array(ref[1...]), reopened.project, resolve, times: Array(times[1...]),
                                   shift: frames(30))

        try chain.undoAll()
        #expect(chain.project.serialized() == original)
    }

    /// The same chain on a temp copy of the user's demo project (only `project.tscproj` copied;
    /// media read in place from the original bundle). Its one top-level group (shader
    /// background, screen recording with cursor effects, unified media with mask) is ungrouped,
    /// regrouped, moved, start-trimmed, split and the right half ungrouped; every step keeps the
    /// picture; save/reopen is lossless; undo-all restores the original bytes.
    @Test(.enabled(if: userDemoBundle != nil, "~/Documents/demo project.cmproj not present"))
    func demoChainKeepsFrames() async throws {
        let originalURL = try #require(userDemoBundle)
        let originalBytes = try Data(contentsOf: originalURL.appendingPathComponent("project.tscproj"))
        let dir = try scratchDir("s5-group-demo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = try copyProjectOnly(originalURL, into: dir)
        let bundle = try ProjectBundle(url: copy)
        let resolve = try ProjectBundle(url: originalURL)
        let baseline = bundle.project.serialized()
        let chain = EditChain(bundle.project)
        let times = [frames(30), frames(200), frames(400), frames(700)]
        var ref: [RGBAImage] = []
        for t in times { ref.append(try await frame(bundle.project, resolve, at: t)) }
        expectInformative(ref)

        let g0 = try #require(bundle.project.tracks.first?.clips.first { $0.kind == .group }).id
        let released = try chain.run(UngroupClip(clipID: g0)).releasedIDs
        #expect(released.count >= 2)
        try await expectSameFrames("demo ungroup", ref, chain.project, resolve, times: times)

        let g = try #require(try chain.run(GroupClips(clipIDs: released)).groupID)
        try await expectSameFrames("demo regroup", ref, chain.project, resolve, times: times)

        try chain.run(MoveClip(clipID: g, toTrack: 1, start: frames(30)))
        let unshifted = try await frame(chain.project, resolve, at: times[1])
        #expect(meanAbsDiff(unshifted, ref[1]) > 1, "the move did not change the frame at its old time")
        try await expectSameFrames("demo move", ref, chain.project, resolve, times: times, shift: frames(30))

        try chain.run(TrimClip(clipID: g, edge: .start, to: frames(30 + 60)))
        let later = Array(times[1...]), laterRef = Array(ref[1...])
        try await expectSameFrames("demo trim-start", laterRef, chain.project, resolve, times: later, shift: frames(30))

        let right = try #require(try chain.run(SplitClip(clipID: g, at: frames(30 + 300))).rightID)
        try await expectSameFrames("demo split", laterRef, chain.project, resolve, times: later, shift: frames(30))
        _ = try chain.run(UngroupClip(clipID: right))
        try await expectSameFrames("demo ungroup right", laterRef, chain.project, resolve, times: later, shift: frames(30))
        try chain.expectUndoRedoWalk()

        try bundle.saveWithBackup()
        let reopened = try ProjectBundle(url: copy)
        #expect(reopened.project.serialized() == chain.project.serialized())
        #expect(ProjectInvariants.check(reopened.project).isEmpty)

        try chain.undoAll()
        try bundle.saveWithBackup()
        #expect(try Data(contentsOf: bundle.projectFile) == baseline)
        #expect(try Data(contentsOf: originalURL.appendingPathComponent("project.tscproj")) == originalBytes,
                "the user's demo project changed")
    }
}
