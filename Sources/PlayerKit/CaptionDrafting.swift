import Foundation
import TSCProjKit

/// Classic captions drafted from transcribed words (Captions panel ▸ Generate Captions): words
/// are grouped into short cues and mapped from source media time onto a clip's timeline span.
/// [WizRec: our own grouping; Camtasia's caption segmentation is unobserved.]
public enum CaptionDrafting {
    /// One drafted cue, timeline seconds.
    public struct Cue: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String
        public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
    }

    /// A word, seconds (source media time when given to `cues(words:clip:editRate:)`).
    public struct Word: Equatable, Sendable {
        public var text: String
        public var start: Double
        public var end: Double
        public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
    }

    /// At most this many words per cue.
    public static let maxWords = 8
    /// At most this long, seconds.
    public static let maxSeconds = 4.0
    /// A pause at least this long (seconds) starts a new cue.
    public static let pause = 0.7

    /// Groups `words` (sorted or not; seconds on one axis) into cues: a new cue after a sentence
    /// end (`.`, `?`, `!`), a pause of `pause` s, `maxWords` words or `maxSeconds` s. Empty words
    /// are skipped.
    public static func group(_ words: [Word]) -> [Cue] {
        var out: [Cue] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(Cue(start: first.start, end: max(last.end, first.start), text: current.map(\.text).joined(separator: " ")))
            current = []
        }
        for w in words.sorted(by: { $0.start < $1.start }) {
            let text = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = current.last, let first = current.first,
               w.start - last.end >= pause || current.count >= maxWords || w.end - first.start > maxSeconds {
                flush()
            }
            current.append(Word(text: text, start: w.start, end: w.end))
            if let c = text.last, ".?!".contains(c) { flush() }
        }
        flush()
        return out
    }

    /// Cues for the words `clip` plays: words in source seconds (`editRate` ticks per second)
    /// inside the clip's media window, grouped and mapped onto the clip's timeline span
    /// (`start + (media − mediaStart) · scalar`), clipped to it.
    @MainActor
    public static func cues(words: [Word], clip: Clip, editRate: Int64) -> [Cue] {
        let rate = Double(max(editRate, 1))
        let ms = clip.mediaStart.double, md = clip.mediaDuration.double
        let scalar = clip.scalar.double == 0 ? 1 : clip.scalar.double
        let lo = ms / rate, hi = (ms + md) / rate
        let inside = words.filter { $0.start >= lo && $0.start < hi }
        let start = Double(clip.start) / rate, end = Double(clip.end) / rate
        func timeline(_ s: Double) -> Double { min(end, max(start, start + (s - lo) * scalar)) }
        return group(inside).compactMap { c in
            let a = timeline(c.start), b = timeline(c.end)
            return b > a ? Cue(start: a, end: b, text: c.text) : nil
        }
    }

    /// A new cue at timeline second `at` on a clip spanning `clipStart…clipEnd` (seconds): 3 s,
    /// shortened to end at the next cue's start or the clip's end; nil when there is no room.
    public static func newCue(at: Double, clipStart: Double, clipEnd: Double, existing: [Cue], text: String) -> Cue? {
        guard at >= clipStart, at < clipEnd else { return nil }
        if existing.contains(where: { $0.start <= at && at < $0.end }) { return nil }
        let next = existing.map(\.start).filter { $0 > at }.min() ?? .infinity
        let end = min(at + 3, clipEnd, next)
        return end > at ? Cue(start: at, end: end, text: text) : nil
    }
}
