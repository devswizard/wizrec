import Foundation

/// How words are grouped into on-screen blocks. Camtasia's own block rule is [?]
/// (`docs/specs/captions.md` §4, experiment CA2); this is WizRec's rule.
public struct CaptionBlockRules: Sendable, Equatable {
    /// Characters per line (separators included); a single longer word gets a line of its own.
    public var maxCharsPerLine: Int
    /// Lines per block.
    public var maxLines: Int
    /// Seconds from a block's first word start to its last word end.
    public var maxBlockDuration: Double
    /// A silence of at least this many seconds between words starts a new block.
    public var gapBreak: Double
    /// Start a new block after a word ending a sentence (`.`, `!`, `?`, `…`, `。`, `！`, `？`).
    public var sentenceBreak: Bool
    /// Seconds a block stays on screen after its last word ends (cut short by the next block).
    public var linger: Double

    public init(maxCharsPerLine: Int = 32, maxLines: Int = 2, maxBlockDuration: Double = 6, gapBreak: Double = 1.5,
                sentenceBreak: Bool = false, linger: Double = 1.0) {
        self.maxCharsPerLine = max(1, maxCharsPerLine); self.maxLines = max(1, maxLines)
        self.maxBlockDuration = maxBlockDuration; self.gapBreak = gapBreak; self.sentenceBreak = sentenceBreak
        self.linger = linger
    }

    /// Rules for a caption box: characters per line estimated from the box width (callout px) and
    /// the base font size (≈ 0.55 em per character), two lines, sentence breaks from the style.
    public init(boxWidth: Double, fontSize: Double, style: DynamicCaptionStyle) {
        let perChar = max(fontSize, 1) * 0.55
        self.init(maxCharsPerLine: min(60, max(8, Int(boxWidth / perChar))),
                  sentenceBreak: style.newParagraphForEachSentence)
    }
}

/// One block of words shown together. Indices point into the word list given to `blocks`.
public struct CaptionBlock: Sendable, Equatable {
    /// Word index ranges, one per line, contiguous and in order.
    public var lines: [Range<Int>]
    /// First word start and last word end, seconds (word time axis).
    public var start: Double
    public var end: Double
    public var words: Range<Int> { (lines.first?.lowerBound ?? 0)..<(lines.last?.upperBound ?? 0) }
    public init(lines: [Range<Int>], start: Double, end: Double) { self.lines = lines; self.start = start; self.end = end }
}

/// What a dynamic caption shows at one instant. Pure state, no time, so equal frames compare equal.
public struct DynamicCaptionFrame: Sendable, Equatable {
    public enum WordState: Sendable, Equatable { case past, current, future }

    public struct Word: Sendable, Equatable {
        /// UTF-16 range of the word in `text`.
        public var range: Range<Int>
        public var state: WordState
        public init(range: Range<Int>, state: WordState) { self.range = range; self.state = state }
    }

    /// The block's text: words joined by spaces (none between CJK words), lines by `"\n"`.
    public var text: String
    /// One entry per word of the block, in order.
    public var words: [Word]
    /// Index into `words` of the word being spoken, nil in pauses and after the last word.
    public var currentWord: Int?
    /// The word highlighted before `currentWord` while the highlight is still easing from it.
    public var previousWord: Int?
    /// 0–1 easing of the highlight from `previousWord` to `currentWord` (`word-easing-duration`); 1 = settled.
    public var highlightProgress: Double
    /// 0–1 movement of the word box (`word-rectangle-transition-time`); 1 = settled.
    public var rectangleProgress: Double
    /// 0–1 progress of the block's entry transition (`block-transition-*`); 1 = fully shown.
    public var blockProgress: Double

    public init(text: String, words: [Word], currentWord: Int?, previousWord: Int? = nil,
                highlightProgress: Double = 1, rectangleProgress: Double = 1, blockProgress: Double = 1) {
        self.text = text; self.words = words; self.currentWord = currentWord; self.previousWord = previousWord
        self.highlightProgress = highlightProgress; self.rectangleProgress = rectangleProgress
        self.blockProgress = blockProgress
    }
}

/// Groups transcript words into blocks and lines.
public enum DynamicCaptionLayout {
    /// Greedy blocks in word order (see `CaptionBlockRules`). Words must be sorted by start time.
    public static func blocks(_ words: [TranscriptWord], rules: CaptionBlockRules) -> [CaptionBlock] {
        var out: [CaptionBlock] = []
        var lines: [Range<Int>] = []
        var lineChars = 0
        func close() {
            guard let first = lines.first, let last = lines.last, !first.isEmpty else { lines = []; return }
            out.append(CaptionBlock(lines: lines, start: words[first.lowerBound].start, end: words[last.upperBound - 1].end))
            lines = []
        }
        for (i, w) in words.enumerated() {
            let n = w.text.count
            if let first = lines.first?.lowerBound {
                let prev = words[i - 1]
                if w.start - prev.end >= rules.gapBreak
                    || (rules.sentenceBreak && endsSentence(prev.text))
                    || w.end - words[first].start > rules.maxBlockDuration {
                    close()
                }
            }
            if lines.isEmpty { lines = [i..<(i + 1)]; lineChars = n; continue }
            let sep = separator(words[i - 1].text, w.text).count
            if lineChars + sep + n <= rules.maxCharsPerLine {
                lines[lines.count - 1] = lines[lines.count - 1].lowerBound..<(i + 1)
                lineChars += sep + n
            } else if lines.count < rules.maxLines {
                lines.append(i..<(i + 1)); lineChars = n
            } else {
                close(); lines = [i..<(i + 1)]; lineChars = n
            }
        }
        close()
        return out
    }

    static func endsSentence(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]»"))
        return t.last.map { ".!?…。！？".contains($0) } ?? false
    }

    /// `" "` between words, `""` when either side of the boundary is a script written without spaces.
    static func separator(_ a: String, _ b: String) -> String {
        func noSpace(_ s: Unicode.Scalar?) -> Bool {
            guard let v = s?.value else { return false }
            return (0x3040...0x30FF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v)
                || (0xF900...0xFAFF).contains(v) || (0x3000...0x303F).contains(v) || (0xFF00...0xFFEF).contains(v)
                || (0x0E00...0x0E7F).contains(v)
        }
        return noSpace(a.unicodeScalars.last) || noSpace(b.unicodeScalars.first) ? "" : " "
    }
}

/// A dynamic caption's words, blocks and style, ready to answer `frame(at:)` cheaply. Build once
/// per scene (e.g. in RenderEngine's SceneModel), query per frame.
public struct DynamicCaptionTimeline: Sendable, Equatable {
    public let words: [TranscriptWord]
    public let blocks: [CaptionBlock]
    public let style: DynamicCaptionStyle
    public let rules: CaptionBlockRules

    public init(words: [TranscriptWord], rules: CaptionBlockRules, style: DynamicCaptionStyle) {
        let sorted = words.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
        self.words = sorted; self.rules = rules; self.style = style
        blocks = DynamicCaptionLayout.blocks(sorted, rules: rules)
    }

    /// The caption at `t` (seconds on the words' axis: source media time), nil when nothing shows:
    /// before the first block, and from `linger` seconds after a block's last word until the next block.
    public func frame(at t: Double) -> DynamicCaptionFrame? {
        guard let bi = blocks.lastIndex(where: { $0.start <= t }) else { return nil }
        let b = blocks[bi]
        guard t < b.end + rules.linger else { return nil }
        var text = ""
        var utf16 = 0
        var fw: [DynamicCaptionFrame.Word] = []
        var current: Int?
        for (li, line) in b.lines.enumerated() {
            if li > 0 { text += "\n"; utf16 += 1 }
            for i in line {
                if i > line.lowerBound {
                    let sep = DynamicCaptionLayout.separator(words[i - 1].text, words[i].text)
                    text += sep; utf16 += sep.utf16.count
                }
                let w = words[i]
                let len = w.text.utf16.count
                let state: DynamicCaptionFrame.WordState
                if w.start <= t && t < w.end { state = .current; current = fw.count }
                else if w.start <= t { state = .past } else { state = .future }
                fw.append(.init(range: utf16..<(utf16 + len), state: state))
                text += w.text; utf16 += len
            }
        }
        func progress(_ since: Double, _ duration: Double) -> Double {
            duration > 0 ? min(1, max(0, (t - since) / duration)) : 1
        }
        var previous: Int?, highlight = 1.0, rect = 1.0
        if let c = current {
            let w = words[b.words.lowerBound + c]
            highlight = progress(w.start, style.wordEasingDuration)
            rect = progress(w.start, style.wordRectangleTransitionTime)
            if c > 0, highlight < 1 || rect < 1 { previous = c - 1 }
        }
        let blockP = style.blockTransitionName.isEmpty ? 1 : progress(b.start, style.blockTransitionDuration)
        return DynamicCaptionFrame(text: text, words: fw, currentWord: current, previousWord: previous,
                                   highlightProgress: highlight, rectangleProgress: rect, blockProgress: blockP)
    }
}
