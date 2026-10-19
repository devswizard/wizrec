import Captions
import Foundation
import Testing
import TestGenKit
import TimelineEngine
import TSCProjKit

// Wave B integration: subtitle files ↔ project captions through TSCProjKit
// save/reopen, undo, and the TimelineEngine edits that move or cut the
// carrying audio clips. Synthetic projects only.

private let srt = """
1
00:00:00,500 --> 00:00:01,500
Hello, WizRec.

2
00:00:02,000 --> 00:00:03,200
Zweite Zeile — mit Umlauten
und zwei Zeilen

3
00:00:04,000 --> 00:00:05,000
<i>Third</i> & last

"""

@MainActor
private func captionProject(in dir: URL, seconds: Int64 = 6) throws -> (ProjectBundle, clip: Int64, chain: EditChain) {
    let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("cap.cmproj"))
    let setup = EditChain(bundle.project)
    let add = AddSource(movieDescriptor(src: "./media/talk.mov", frames: seconds * 30, audio: true))
    add.addedAt = Date(timeIntervalSince1970: 1_792_376_869)
    try setup.run(add)
    let source = try #require(add.sourceID)
    let clip = try #require(try setup.run(InsertClip(sourceID: source, track: 0, start: 0)).clipID)
    return (bundle, clip, EditChain(bundle.project))
}

/// Cue times compared at 1 ms (cues are frame-rounded on import).
private func same(_ a: [CaptionCue], _ b: [CaptionCue], shift: Double = 0) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy {
        abs($0.start + shift - $1.start) < 1e-3 && abs($0.end + shift - $1.end) < 1e-3 && $0.text == $1.text
    }
}

@Suite @MainActor struct CaptionsIntegrationTests {

    /// SRT → AddCaptions → save → reopen → SRT/VTT export: same cues; undo is byte-identical.
    @Test func srtImportSaveReopenExport() throws {
        let dir = try scratchDir("cap-rt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (bundle, _, chain) = try captionProject(in: dir)
        let parsed = try CaptionFiles.parse(srt)
        #expect(parsed.count == 3)
        let add = try chain.run(CaptionFiles.importCommand(srt))
        #expect(add.droppedCues.isEmpty)
        let inProject = CaptionFiles.cues(in: chain.project)
        #expect(same(parsed, inProject), "\(inProject)")

        try bundle.saveWithBackup()
        let reopened = try ProjectBundle(url: bundle.directory)
        #expect(reopened.project.serialized() == chain.project.serialized())
        let back = CaptionFiles.cues(in: reopened.project)
        #expect(same(parsed, back))
        // Exported text parses back to the same cues, in both formats.
        #expect(same(parsed, try CaptionFiles.parse(CaptionFiles.srt(reopened.project))))
        #expect(same(parsed, try CaptionFiles.parse(CaptionFiles.vtt(reopened.project))))
        // Re-importing the export into a fresh copy changes nothing visible.
        try chain.run(SetCaptionStyle(CaptionStyle(fontSize: 48)))
        try chain.expectUndoRedoWalk()
        try chain.undoAll()
        #expect(CaptionFiles.cues(in: chain.project).isEmpty)
    }

    /// Moving the carrying clip moves its captions with it.
    @Test func captionsFollowAMovedClip() throws {
        let dir = try scratchDir("cap-move")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, clip, chain) = try captionProject(in: dir)
        try chain.run(CaptionFiles.importCommand(srt))
        let before = CaptionFiles.cues(in: chain.project)
        try chain.run(MoveClip(clipID: clip, toTrack: 0, start: frames(60)))
        let after = CaptionFiles.cues(in: chain.project)
        #expect(same(before, after, shift: 2), "captions did not move with the clip: \(after)")
        try chain.expectUndoRedoWalk()
    }

    /// Splitting the carrying clip must not move any caption on the timeline.
    @Test func splitKeepsCaptionTimes() throws {
        let dir = try scratchDir("cap-split")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, clip, chain) = try captionProject(in: dir)
        try chain.run(CaptionFiles.importCommand(srt))
        let before = CaptionFiles.cues(in: chain.project)
        try chain.run(SplitClip(clipID: clip, at: frames(105)))  // 3.5 s, between cues 2 and 3
        let after = CaptionFiles.cues(in: chain.project)
        #expect(same(before, after), "split moved captions:\nbefore \(before)\nafter  \(after)")
        try chain.expectUndoRedoWalk()
    }

    /// Trimming the start of the carrying clip keeps the remaining captions where they were.
    @Test func trimStartKeepsCaptionTimes() throws {
        let dir = try scratchDir("cap-trim")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, clip, chain) = try captionProject(in: dir)
        try chain.run(CaptionFiles.importCommand(srt))
        let before = CaptionFiles.cues(in: chain.project)
        try chain.run(TrimClip(clipID: clip, edge: .start, to: frames(30)))  // cuts into cue 1
        let after = CaptionFiles.cues(in: chain.project)
        let expected = [CaptionCue(start: 1.0, end: 1.5, text: before[0].text)] + before.dropFirst()
        #expect(same(expected, after), "trim moved captions:\nexpected \(expected)\nafter    \(after)")
    }

    /// Detaching audio keeps the captions (they live on the audio half).
    @Test func detachAudioKeepsCaptions() throws {
        let dir = try scratchDir("cap-detach")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, clip, chain) = try captionProject(in: dir)
        try chain.run(CaptionFiles.importCommand(srt))
        let before = CaptionFiles.cues(in: chain.project)
        try chain.run(DetachAudio(clipID: clip))
        let after = CaptionFiles.cues(in: chain.project)
        #expect(same(before, after), "detach lost or moved captions: \(after)")
    }
}
