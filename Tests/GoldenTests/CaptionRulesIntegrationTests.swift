import Captions
import CaptionLayout
import CoreGraphics
import Foundation
import MediaEngine
import Metal
import RenderEngine
import Testing
import TestGenKit
import TimelineEngine
import TSCProjKit

// S5-QA-1 / captions6 CA1/CA2: Add Captions (empty 4 s media-time segments) and Add Dynamic
// Caption Style (a 60 s callout on a new top track at the playhead or at a transcribed clip's
// start), through save/reopen, scene evaluation, OfflineRenderer and undo. Synthetic media only.

private let editRate: Int64 = 705_600_000

/// A bundle with `seconds` of mono tone (48 kHz) as one audio clip at timeline 1 s.
@MainActor
private func captionFixture(in dir: URL, seconds: Double = 13.2)
    throws -> (ProjectBundle, source: Int64, clip: Int64, chain: EditChain) {
    let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("cr.cmproj"), width: 640, height: 360)
    let n = Int(seconds * 48_000)
    let wav = dir.appendingPathComponent("tone.wav")
    try AudioSignals.writeWAV((0..<n).map { Float(sin(Double($0) * 0.05) * 0.3) }, to: wav)
    let setup = EditChain(bundle.project)
    let add = AddSource(SourceDescriptor(src: try bundle.importFile(wav), lastModified: Date(timeIntervalSince1970: 1_792_000_000), tracks: [
        .init(type: 2, editRate: 48_000, rangeEnd: Int64(n), width: 0, height: 0, sampleRate: Rational(48_000), bitDepth: 16, channelCount: 1),
    ]))
    add.addedAt = Date(timeIntervalSince1970: 1_792_376_869)
    try setup.run(add)
    let source = try #require(add.sourceID)
    let clip = try #require(try setup.run(InsertClip(sourceID: source, track: 0, start: frames(30))).clipID)
    return (bundle, source, clip, EditChain(bundle.project))
}

/// Media-time seconds of the clip's `captions` keyframes.
@MainActor
private func captionTimes(_ project: Project, clip id: Int64) -> [Double] {
    guard let c = project.tracks.flatMap(\.clips).first(where: { $0.id == id }) else { return [] }
    let kfs = c.object["parameters"]?.object?["captions"]?.object?["keyframes"]?.array?.items ?? []
    return kfs.compactMap { $0.object?["time"]?.int }.map { Double($0) / Double(editRate) }
}

/// The dynamic-caption callout drawn at `ticks`, if any.
@MainActor
private func dynamicCaption(_ project: Project, _ bundle: ProjectBundle, at ticks: Int64) -> DynamicCaptionRender? {
    func find(_ layers: [Layer]) -> DynamicCaptionRender? {
        for l in layers {
            switch l.content {
            case .callout(let c): if let d = c.dynamicCaption { return d }
            case .group(let inner): if let d = find(inner) { return d }
            default: break
            }
        }
        return nil
    }
    return find(SceneModel(project: project, resolve: bundle.resolve).evaluate(at: ticks).layers)
}

@Suite(.serialized) @MainActor struct CaptionRulesIntegrationTests {
    /// CA1: empty captions every 4 s of media time from `mediaStart` (0/4/8/12 s on 13.2 s;
    /// 1/5/9/13 s after a 1 s left trim); no visible cues; a second Add Captions is refused;
    /// save/reopen lossless; undo to the original bytes.
    @Test func addEmptyCaptionsFollowsMediaTime() throws {
        let dir = try scratchDir("s5-cap-empty")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (bundle, _, clip, chain) = try captionFixture(in: dir)
        let original = chain.project.serialized()
        try chain.run(AddEmptyCaptions(clipID: clip))
        #expect(captionTimes(chain.project, clip: clip) == [0, 4, 8, 12])
        #expect(ClassicCaptions.cues(in: chain.project).isEmpty, "empty captions should not show")
        #expect(throws: (any Error).self) { try AddEmptyCaptions(clipID: clip).apply(to: chain.project) }
        try bundle.saveWithBackup()
        #expect(try ProjectBundle(url: bundle.directory).project.serialized() == chain.project.serialized())
        try chain.undoAll()
        #expect(chain.project.serialized() == original)

        // After a 1 s left trim the segments start at the new mediaStart (fresh undo history).
        let trimmed = EditChain(bundle.project)
        try trimmed.run(TrimClip(clipID: clip, edge: .start, to: frames(60)))
        try trimmed.run(AddEmptyCaptions(clipID: clip))
        #expect(captionTimes(trimmed.project, clip: clip) == [1, 5, 9, 13])
        try trimmed.expectUndoRedoWalk()
        try trimmed.undoAll()
        #expect(trimmed.project.serialized() == original)
    }

    /// CA2: a transcribed clip gets a 60 s dynamic caption at its start on a new top track; the
    /// scene shows the current block only while words are spoken; OfflineRenderer draws it
    /// (pixels differ from the frame before the first word); save/reopen keeps the bytes and the
    /// picture; a second style at playhead 30 s goes on another new track; undo restores all.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
    func dynamicCaptionAtClipAndPlayhead() async throws {
        let dir = try scratchDir("s5-cap-dynamic")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (bundle, source, clip, chain) = try captionFixture(in: dir, seconds: 6)
        let original = chain.project.serialized()
        let words = [TranscriptWord(text: "Hello", start: 0.5, end: 1.0), TranscriptWord(text: "world.", start: 1.0, end: 1.5),
                     TranscriptWord(text: "Again", start: 3.0, end: 3.5), TranscriptWord(text: "friends.", start: 3.5, end: 4.0)]
        #expect(throws: (any Error).self) { try AddDynamicCaption(audioClipID: clip).apply(to: chain.project) }
        try chain.run(ApplyTranscription(sourceID: source, track: 0, words: words))
        let tracksBefore = chain.project.tracks.count
        let add = try chain.run(AddDynamicCaption(audioClipID: clip))
        let callout = try #require(add.calloutID)
        #expect(chain.project.tracks.count == tracksBefore + 1)
        let placed = try #require(chain.project.tracks.last?.clips.first { $0.id == callout })
        #expect(placed.start == frames(30) && placed.duration == 60 * editRate, "callout \(placed.start)…\(placed.duration)")

        let cues = DynamicCaptions.cues(in: chain.project)
        print("dynamic caption cues: \(cues.map { String(format: "%.2f–%.2f %@", $0.start, $0.end, $0.text) })")
        #expect(cues.contains { $0.text.contains("Hello") && abs($0.start - 1.5) < 0.05 })

        // Timeline = 1 s + source time.
        let speaking = editRate + editRate * 7 / 10, silent = editRate + editRate / 5
        let shown = try #require(dynamicCaption(chain.project, bundle, at: speaking)?.frame)
        #expect(shown.text.contains("Hello"), "block \(shown.text)")
        #expect(dynamicCaption(chain.project, bundle, at: silent)?.frame == nil, "caption before the first word")

        func render(_ project: Project, _ t: Int64) async throws -> RGBAImage {
            let r = OfflineRenderer(scene: SceneModel(project: project, resolve: bundle.resolve), pool: MediaPool(diskCacheDirectory: nil))
            return RGBAImage(try await r.image(at: t, size: CGSize(width: 640, height: 360)))
        }
        let withText = try await render(chain.project, speaking), without = try await render(chain.project, silent)
        var changed = 0
        for i in stride(from: 0, to: withText.pixels.count, by: 4) where withText.pixels[i] != without.pixels[i] { changed += 1 }
        print("dynamic caption: \(changed) px differ between a spoken and a silent frame")
        #expect(changed > 500, "the caption is not drawn")

        try bundle.saveWithBackup()
        let reopened = try ProjectBundle(url: bundle.directory)
        #expect(reopened.project.serialized() == chain.project.serialized())
        #expect(ProjectInvariants.check(reopened.project).isEmpty)
        #expect(try await render(reopened.project, speaking) == withText, "caption render changed across save/reopen")

        // A second style at the playhead (30 s) goes on another new track.
        let second = try chain.run(AddDynamicCaption(at: 30, preset: .arial2LineDarkBackground))
        let id2 = try #require(second.calloutID)
        #expect(chain.project.tracks.count == tracksBefore + 2)
        #expect(chain.project.tracks.last?.clips.first { $0.id == id2 }?.start == 30 * editRate)

        try chain.expectUndoRedoWalk()
        try chain.undoAll()
        #expect(chain.project.serialized() == original)
    }
}
