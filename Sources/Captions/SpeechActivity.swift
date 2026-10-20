import Foundation

/// Energy-based speech activity over mono PCM, used to keep whisper.cpp's word times out of
/// silences [WizRec]. whisper-cli 1.9.5 with `-ml 1 -sow` places words inside long pauses
/// (measured: sentence starts up to 3 s early after a 3 s pause), so the recognizer
///
/// 1. finds voiced spans (`regions`),
/// 2. transcribes a *compacted* copy where each long silence is cut to `gapSeconds`
///    (`Compaction`), then maps word times back, and
/// 3. trims each word to its voiced frames (`trim`).
///
/// Frames are 10 ms. A frame is voiced when its RMS exceeds
/// `clamp(10th-percentile RMS × floorRatio, minimumRMS…maximumThreshold)`, so steady room noise
/// raises the bar, pure digital silence uses `minimumRMS` (−50 dBFS), and audio that is speech
/// throughout (a high 10th percentile) never gets a bar above −40 dBFS that would cut soft
/// syllables. Noise louder than that is all "voiced": one region covers everything and the
/// transcription behaves as without compaction.
struct SpeechActivity: Sendable {
    /// Frame length, seconds.
    static let frameSeconds = 0.01
    /// Voiced threshold relative to the noise floor (10 dB, amplitude ratio).
    static let floorRatio: Float = 3.162
    /// Lowest voiced threshold, linear RMS (−50 dBFS).
    static let minimumRMS: Float = 0.003_162
    /// Highest voiced threshold, linear RMS (−40 dBFS).
    static let maximumThreshold: Float = 0.01
    /// A silence this long, seconds, ends a word's voiced cluster in `trim`.
    static let wordBreakSeconds = 0.3
    /// Silences shorter than this, seconds, stay inside one region.
    static let mergeSeconds = 0.5
    /// Padding kept around each region, seconds.
    static let padSeconds = 0.2

    /// Per-frame voiced flags.
    let voiced: [Bool]
    /// Samples per second of the analysed audio.
    let sampleRate: Double
    /// Duration of the analysed audio, seconds.
    let duration: Double

    init(_ x: [Float], sampleRate: Double) {
        self.sampleRate = sampleRate
        duration = sampleRate > 0 ? Double(x.count) / sampleRate : 0
        let frame = max(1, Int((sampleRate * Self.frameSeconds).rounded()))
        var rms: [Float] = []
        rms.reserveCapacity(x.count / frame + 1)
        var i = 0
        while i < x.count {
            let e = min(x.count, i + frame)
            var sum: Float = 0
            for k in i..<e { let v = x[k].isFinite ? x[k] : 0; sum += v * v }
            rms.append((sum / Float(e - i)).squareRoot())
            i = e
        }
        let sorted = rms.sorted()
        let floor = sorted.isEmpty ? 0 : sorted[sorted.count / 10]
        let threshold = min(max(floor * Self.floorRatio, Self.minimumRMS), Self.maximumThreshold)
        voiced = rms.map { $0 > threshold }
    }

    /// True when any frame is voiced.
    var hasSpeech: Bool { voiced.contains(true) }

    /// Voiced spans, seconds: silences under `mergeSeconds` merged, `padSeconds` added on both
    /// sides, overlaps joined, clamped to `0...duration`. Ascending and disjoint.
    func regions() -> [ClosedRange<Double>] {
        let f = Self.frameSeconds
        let mergeFrames = Int((Self.mergeSeconds / f).rounded())
        var spans: [(Int, Int)] = []  // frame ranges [a, b)
        var i = 0
        while i < voiced.count {
            guard voiced[i] else { i += 1; continue }
            var j = i
            while j < voiced.count, voiced[j] { j += 1 }
            if let last = spans.last, i - last.1 < mergeFrames { spans[spans.count - 1].1 = j } else { spans.append((i, j)) }
            i = j
        }
        var out: [ClosedRange<Double>] = []
        for (a, b) in spans {
            let lo = max(0, Double(a) * f - Self.padSeconds)
            let hi = min(duration, Double(b) * f + Self.padSeconds)
            guard hi > lo else { continue }
            if let last = out.last, lo <= last.upperBound {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, hi)
            } else {
                out.append(lo...hi)
            }
        }
        return out
    }

    /// `word` clamped to the audio, then shrunk to its first voiced cluster (plus 20 ms each
    /// side): from its first voiced frame to the last voiced frame before a silence of
    /// `wordBreakSeconds`. whisper often lets a sentence's last word run through the following
    /// pause into the next sentence's first syllable; the cluster rule cuts that tail. A word with
    /// no voiced frame keeps its clamped span.
    func trim(_ word: TranscriptWord) -> TranscriptWord {
        var w = word
        w.start = min(max(0, w.start), duration)
        w.end = min(max(w.start, w.end), duration)
        let f = Self.frameSeconds, pad = 0.02
        let i0 = max(0, Int((w.start / f).rounded(.down)))
        let i1 = min(voiced.count, Int((w.end / f).rounded(.up)))
        guard i0 < i1, let first = (i0..<i1).first(where: { voiced[$0] }) else { return w }
        let breakFrames = Int((Self.wordBreakSeconds / f).rounded())
        var last = first
        for k in (first + 1)..<max(first + 1, i1) where voiced[k] {
            if k - last > breakFrames { break }
            last = k
        }
        let s = max(w.start, Double(first) * f - pad)
        let e = min(w.end, Double(last + 1) * f + pad)
        if e > s { w.start = s; w.end = e }
        return w
    }
}

/// A copy of the audio with the silences between `SpeechActivity.regions()` shortened to
/// `gapSeconds`, and the map from compacted time back to original time (seconds).
struct Compaction: Sendable {
    /// Silence placed between two regions in the compacted audio, seconds.
    static let gapSeconds = 0.3

    /// One kept span: where it starts in the compacted audio and in the original, and its length.
    struct Piece: Sendable, Equatable { var compact: Double; var original: Double; var length: Double }

    let pieces: [Piece]
    /// The compacted samples.
    let samples: [Float]

    /// Compacts `x` to `regions` (seconds, ascending, disjoint).
    init(_ x: [Float], sampleRate: Double, regions: [ClosedRange<Double>]) {
        var out: [Float] = [], pieces: [Piece] = []
        let gap = Int((Self.gapSeconds * sampleRate).rounded())
        for r in regions {
            let a = max(0, min(x.count, Int((r.lowerBound * sampleRate).rounded())))
            let b = max(a, min(x.count, Int((r.upperBound * sampleRate).rounded())))
            guard b > a else { continue }
            if !pieces.isEmpty { out.append(contentsOf: repeatElement(0, count: gap)) }
            pieces.append(Piece(compact: Double(out.count) / sampleRate, original: Double(a) / sampleRate,
                                length: Double(b - a) / sampleRate))
            out.append(contentsOf: x[a..<b])
        }
        self.pieces = pieces
        samples = out
    }

    /// Original time of compacted time `t`. A time inside an inserted gap maps to the start of
    /// the next piece when `isStart`, else to the end of the previous one, so a word never
    /// straddles a removed silence.
    func original(_ t: Double, isStart: Bool) -> Double {
        guard let firstPiece = pieces.first else { return t }
        var previous: Piece?
        for p in pieces {
            if t < p.compact {
                if isStart || previous == nil { return p.original }
                return previous.map { $0.original + $0.length } ?? p.original
            }
            if t <= p.compact + p.length { return p.original + (t - p.compact) }
            previous = p
        }
        let last = previous ?? firstPiece
        return last.original + last.length
    }

    /// `words` (compacted times) on the original time axis; an end never precedes its start.
    func original(_ words: [TranscriptWord]) -> [TranscriptWord] {
        words.map { w in
            var o = w
            o.start = original(w.start, isStart: true)
            o.end = max(o.start, original(w.end, isStart: false))
            return o
        }
    }
}
