import Foundation
import Testing
import TSCProjKit
@testable import PlayerKit

/// Captions drafted from transcribed words (APP15-1d, Captions ▸ Generate Captions).
@Suite @MainActor struct CaptionDraftingTests {
    typealias W = CaptionDrafting.Word

    @Test func groupsBySentencePauseAndLength() {
        let words = [W(text: "Hello", start: 0, end: 0.4), W(text: "world.", start: 0.5, end: 0.9),
                     W(text: "This", start: 1.0, end: 1.2), W(text: "is", start: 1.3, end: 1.4),
                     W(text: "after", start: 2.5, end: 2.8), W(text: " ", start: 2.9, end: 3.0)]
        let cues = CaptionDrafting.group(words)
        #expect(cues.map(\.text) == ["Hello world.", "This is", "after"])
        #expect(cues[0].start == 0 && cues[0].end == 0.9 && cues[2].start == 2.5)
        // Eight words at most.
        let many = (0..<10).map { W(text: "w\($0)", start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.2) }
        #expect(CaptionDrafting.group(many).map { $0.text.split(separator: " ").count } == [8, 2])
        // Four seconds at most.
        let slow = (0..<6).map { W(text: "s\($0)", start: Double($0) * 0.9, end: Double($0) * 0.9 + 0.5) }
        #expect(CaptionDrafting.group(slow).count == 2)
        #expect(CaptionDrafting.group([]).isEmpty)
    }

    @Test func mapsWordsOntoTheClipSpan() throws {
        // A clip at 10 s playing source 2 s…6 s at 2× (scalar 1/2): source 3 s → 10.5 s.
        let rate: Int64 = 1000
        let json = """
        {"id": 5, "_type": "AMFile", "start": 10000, "duration": 2000, "mediaStart": 2000, "mediaDuration": 4000, "scalar": "1/2"}
        """
        let clip = Clip(try #require(JSON.parse(Data(json.utf8)).object))
        let words = [W(text: "before", start: 1, end: 1.5), W(text: "one", start: 3, end: 3.4),
                     W(text: "two.", start: 3.5, end: 4), W(text: "late", start: 7, end: 7.5)]
        let cues = CaptionDrafting.cues(words: words, clip: clip, editRate: rate)
        #expect(cues == [CaptionDrafting.Cue(start: 10.5, end: 11, text: "one two.")])
    }

    @Test func newCueFitsBeforeTheNextOneAndTheClipEnd() {
        let existing = [CaptionDrafting.Cue(start: 5, end: 6, text: "x")]
        #expect(CaptionDrafting.newCue(at: 1, clipStart: 0, clipEnd: 10, existing: existing, text: "t")?.end == 4)
        #expect(CaptionDrafting.newCue(at: 3.5, clipStart: 0, clipEnd: 10, existing: existing, text: "t")?.end == 5)
        #expect(CaptionDrafting.newCue(at: 8, clipStart: 0, clipEnd: 9, existing: existing, text: "t")?.end == 9)
        #expect(CaptionDrafting.newCue(at: 5.5, clipStart: 0, clipEnd: 10, existing: existing, text: "t") == nil)
        #expect(CaptionDrafting.newCue(at: 11, clipStart: 0, clipEnd: 10, existing: existing, text: "t") == nil)
    }
}
