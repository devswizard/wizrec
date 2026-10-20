import Foundation
import Testing
@testable import Captions

/// Mono samples: each part is `(seconds, amplitude)`; amplitude 0 = digital silence, otherwise a
/// sine of that peak amplitude.
func speechLike(_ parts: [(Double, Float)], rate: Double = 16_000) -> [Float] {
    var x: [Float] = []
    for (seconds, amp) in parts {
        let n = Int((seconds * rate).rounded())
        x += (0..<n).map { amp == 0 ? 0 : amp * Float(sin(Double($0) * 0.3)) }
    }
    return x
}

@Suite struct SpeechActivityTests {
    @Test func regionsMergeShortGapsPadAndClamp() {
        // 3 s silence, 1 s speech, 0.3 s pause, 1 s speech, 2 s silence, 1 s speech (to the end).
        let x = speechLike([(3, 0), (1, 0.3), (0.3, 0), (1, 0.3), (2, 0), (1, 0.3)])
        let a = SpeechActivity(x, sampleRate: 16_000)
        #expect(a.hasSpeech)
        #expect(abs(a.duration - 8.3) < 1e-9)
        let r = a.regions()
        #expect(r.count == 2)
        guard r.count == 2 else { return }
        #expect(abs(r[0].lowerBound - 2.8) < 0.02 && abs(r[0].upperBound - 5.5) < 0.02)  // short pause merged
        #expect(abs(r[1].lowerBound - 7.1) < 0.02 && r[1].upperBound == 8.3)  // padding clamped at the end
    }

    @Test func silenceAndNoise() {
        #expect(!SpeechActivity(speechLike([(2, 0)]), sampleRate: 16_000).hasSpeech)
        #expect(!SpeechActivity([], sampleRate: 16_000).hasSpeech)
        #expect(SpeechActivity([], sampleRate: 16_000).regions().isEmpty)
        // Below −50 dBFS counts as silence.
        #expect(!SpeechActivity(speechLike([(1, 0.002)]), sampleRate: 16_000).hasSpeech)
        // Steady loud audio throughout: a single region, so compaction changes nothing.
        let loud = SpeechActivity(speechLike([(2, 0.5), (1, 0.05), (2, 0.5)]), sampleRate: 16_000)
        #expect(loud.regions() == [0...5])
        // Non-finite samples do not poison the analysis.
        var x = speechLike([(1, 0), (1, 0.3)])
        x[10] = .nan
        #expect(SpeechActivity(x, sampleRate: 16_000).regions().count == 1)
    }

    @Test func trimToFirstVoicedCluster() {
        // Speech 1–2 s, silence 2–5 s, speech 5–6 s; audio is 6 s.
        let a = SpeechActivity(speechLike([(1, 0), (1, 0.3), (3, 0), (1, 0.3)]), sampleRate: 16_000)
        // A sentence's last word that whisper ran through the pause into the next sentence.
        let t = a.trim(TranscriptWord(text: "dog.", start: 1.5, end: 5.05, confidence: 0.8))
        #expect(t.start == 1.5 && abs(t.end - 2.02) < 1e-6 && t.confidence == 0.8 && t.text == "dog.")
        // A word that starts in silence moves to its voiced onset.
        let s = a.trim(TranscriptWord(text: "The", start: 0, end: 1.4))
        #expect(abs(s.start - 0.98) < 1e-6 && s.end == 1.4)
        // No voiced frame: span kept.
        #expect(a.trim(TranscriptWord(text: "um", start: 3, end: 4)) == TranscriptWord(text: "um", start: 3, end: 4))
        // Beyond the end of the audio (whisper reported 6.0 s for a 4.89 s clip): clamped.
        let c = a.trim(TranscriptWord(text: "x", start: 5.5, end: 9))
        #expect(c.start == 5.5 && c.end == 6)
        let d = a.trim(TranscriptWord(text: "y", start: 7, end: 8))
        #expect(d.start == 6 && d.end == 6)
        let n = a.trim(TranscriptWord(text: "z", start: -1, end: 0.5))
        #expect(n.start == 0 && n.end == 0.5)
    }

    @Test func compactionShortensSilencesAndMapsBack() {
        let x = speechLike([(3, 0), (1, 0.3), (2, 0), (1, 0.3), (3, 0)])  // 10 s
        let a = SpeechActivity(x, sampleRate: 16_000)
        let c = Compaction(x, sampleRate: 16_000, regions: a.regions())
        #expect(c.pieces.count == 2)
        guard c.pieces.count == 2 else { return }
        // Two 1.4 s pieces (1 s + 0.2 s padding each side) and one 0.3 s gap.
        #expect(abs(Double(c.samples.count) / 16_000 - 3.1) < 0.02)
        #expect(c.pieces[0].compact == 0 && abs(c.pieces[0].original - 2.8) < 0.01)
        #expect(abs(c.pieces[1].compact - 1.7) < 0.01 && abs(c.pieces[1].original - 5.8) < 0.01)
        // Inside a piece: shifted.
        #expect(abs(c.original(0.5, isStart: true) - 3.3) < 0.01)
        #expect(abs(c.original(2.0, isStart: false) - 6.1) < 0.01)
        // Inside the gap: a start goes to the next piece, an end to the previous one.
        #expect(abs(c.original(1.5, isStart: true) - 5.8) < 0.01)
        #expect(abs(c.original(1.5, isStart: false) - 4.2) < 0.01)
        // Past the end: the end of the last piece.
        #expect(abs(c.original(99, isStart: true) - 7.2) < 0.01)
        let w = c.original([TranscriptWord(text: "a", start: 1.3, end: 1.9)])
        #expect(abs(w[0].start - 4.1) < 0.01 && abs(w[0].end - 6.0) < 0.01)
        // A word wholly inside the gap never ends before it starts.
        let g = c.original([TranscriptWord(text: "b", start: 1.45, end: 1.55)])
        #expect(g[0].end >= g[0].start)
        // No regions: nothing kept, identity map.
        let e = Compaction(x, sampleRate: 16_000, regions: [])
        #expect(e.samples.isEmpty && e.original(1.25, isStart: true) == 1.25)
    }
}
