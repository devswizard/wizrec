import Testing
import TSCProjKit
@testable import CaptionLayout

private func words(_ s: String, step: Double = 0.5) -> [TranscriptWord] {
    s.split(separator: " ").enumerated().map { i, w in
        TranscriptWord(text: String(w), start: Double(i) * step, end: Double(i) * step + step)
    }
}

@Suite struct LayoutTests {
    @Test func greedyLinesAndBlocks() {
        let w = words("The quick brown fox jumps over the lazy dog")
        let blocks = DynamicCaptionLayout.blocks(w, rules: CaptionBlockRules(maxCharsPerLine: 10, maxLines: 2))
        // "The quick" (9) | "brown fox" (9) ; "jumps over" (10) | "the lazy" (8) ; "dog"
        #expect(blocks.map(\.lines) == [[0..<2, 2..<4], [4..<6, 6..<8], [8..<9]])
        #expect(blocks[0].start == 0 && blocks[0].end == 2)
    }

    @Test func breaksOnGapsSentencesAndDuration() {
        var w = words("One two. Three four")
        w[2].start += 5; w[2].end += 5; w[3].start += 5; w[3].end += 5
        let gap = DynamicCaptionLayout.blocks(w, rules: CaptionBlockRules(maxCharsPerLine: 40, gapBreak: 1.5))
        #expect(gap.map(\.words) == [0..<2, 2..<4])
        let sentence = DynamicCaptionLayout.blocks(words("One two. Three four"),
                                                   rules: CaptionBlockRules(maxCharsPerLine: 40, sentenceBreak: true))
        #expect(sentence.map(\.words) == [0..<2, 2..<4])
        let dur = DynamicCaptionLayout.blocks(words("a b c d e f", step: 1), rules: CaptionBlockRules(maxCharsPerLine: 40, maxBlockDuration: 3))
        #expect(dur.map(\.words) == [0..<3, 3..<6])
    }

    @Test func longWordGetsOwnLineAndCJKHasNoSpaces() {
        let w = [TranscriptWord(text: "supercalifragilistic", start: 0, end: 1), TranscriptWord(text: "ok", start: 1, end: 2)]
        #expect(DynamicCaptionLayout.blocks(w, rules: CaptionBlockRules(maxCharsPerLine: 5)).map(\.lines) == [[0..<1, 1..<2]])
        let cjk = [TranscriptWord(text: "敏捷的", start: 0, end: 1), TranscriptWord(text: "棕色狐狸", start: 1, end: 2)]
        let tl = DynamicCaptionTimeline(words: cjk, rules: CaptionBlockRules(maxCharsPerLine: 10), style: DynamicCaptionStyle())
        #expect(tl.frame(at: 0.5)?.text == "敏捷的棕色狐狸")
    }

    @Test func frameStatesAndRanges() throws {
        let tl = DynamicCaptionTimeline(words: words("The quick brown fox"), rules: CaptionBlockRules(maxCharsPerLine: 9), style: DynamicCaptionStyle())
        #expect(tl.frame(at: -0.1) == nil)
        let f = try #require(tl.frame(at: 0.75))
        #expect(f.text == "The quick\nbrown fox")
        #expect(f.words.map(\.range) == [0..<3, 4..<9, 10..<15, 16..<19])
        #expect(f.words.map(\.state) == [.past, .current, .future, .future])
        #expect(f.currentWord == 1 && f.highlightProgress == 1 && f.blockProgress == 1)
        // After the last word: all past while lingering, then hidden.
        let after = try #require(tl.frame(at: 2.5))
        #expect(after.currentWord == nil && after.words.allSatisfy { $0.state == .past })
        #expect(tl.frame(at: 3.01) == nil)
        // Pure state: same word, different time → equal frames.
        #expect(tl.frame(at: 0.7) == tl.frame(at: 0.95))
    }

    @Test func easingAndBlockTransition() throws {
        var style = DynamicCaptionStyle()
        style.wordEasingDuration = 0.2; style.blockTransitionName = "Fade"; style.blockTransitionDuration = 0.5
        let tl = DynamicCaptionTimeline(words: words("a b"), rules: CaptionBlockRules(), style: style)
        let f = try #require(tl.frame(at: 0.65))
        #expect(abs(f.highlightProgress - 0.75) < 1e-9)
        #expect(f.previousWord == 0 && f.rectangleProgress == 1 && f.blockProgress == 1)
        #expect(abs((tl.frame(at: 0.25)?.blockProgress ?? 0) - 0.5) < 1e-9)
    }

    @Test func styleParsesDefAndDefaults() throws {
        let def = try #require(JSON.parse("""
        {"modifier":"dynamicCaption","dynamic-caption-style":"block","dynamic-caption-past-word-opacity":0.4,
         "dynamic-caption-current-word-color-red":0.5,"dynamic-caption-current-word-enabled":0.0,
         "dynamic-caption-new-paragraph-for-each-sentence":1.0}
        """).object)
        let s = DynamicCaptionStyle(def: def)
        #expect(DynamicCaptionStyle.isDynamicCaption(def))
        #expect(s.pastWordOpacity == 0.4 && s.currentWordColor == CaptionColor(0.5, 1, 1, 1))
        #expect(!s.currentWordEnabled && s.newParagraphForEachSentence)
        #expect(s.wordRectangleColor == CaptionColor(0, 0.4, 0.98, 0) && s.backgroundCornerRadius == 19.2)
        let names = s.numericEntries.map(\.0)
        #expect(names == names.sorted() && names.count == 30)
    }

    @Test func decodesTranscriptKeyframes() throws {
        let track = try #require(JSON.parse("""
        {"range":[0,8024],"type":2,"editRate":1000,"transcriptionSet":true,"parameters":{"transcription":{"type":"string","keyframes":[
          {"endTime":117600000,"time":117600000,"value":"Quick","duration":0},
          {"endTime":0,"time":0,"value":"The","duration":0},
          {"endTime":305760000,"time":305760000,"value":"","duration":0},
          {"endTime":493920000,"time":493920000,"value":"Fox","duration":0}]}}}
        """).object)
        let w = Transcript.words(SourceTrack(track), editRate: 705_600_000)
        #expect(w.map(\.text) == ["The", "Quick", "Fox"])
        #expect(w[0].start == 0 && abs(w[0].end - 1.0 / 6) < 1e-12)
        #expect(abs(w[1].end - 305760000.0 / 705600000) < 1e-12)
        #expect(abs(w[2].end - 8.024) < 1e-12)
        #expect(Transcript.isSet(SourceTrack(track)))
    }
}
