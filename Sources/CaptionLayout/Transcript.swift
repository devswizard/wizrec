// CaptionLayout: pure, Sendable dynamic-caption layout and state, plus transcript decoding.
// Depends on TSCProjKit only, so RenderEngine can import it (API_CHANGE approved 2026-10-19).

import Foundation
import TSCProjKit

/// One recognised word, times in seconds of the source's media time.
public struct TranscriptWord: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    /// 0–1.
    public var confidence: Double
    public init(text: String, start: Double, end: Double, confidence: Double = 1) {
        self.text = text; self.start = start; self.end = end; self.confidence = confidence
    }
}

/// Reads the word transcription stored on a source track (`docs/specs/captions.md` §2):
/// `sourceTracks[j].parameters.transcription.keyframes`, one `{time, value}` per word, `time` in
/// project ticks on the source's media axis; a keyframe with `value: ""` closes the previous word.
public enum Transcript {
    /// Words of `track`, seconds of source media time. A word ends at the next keyframe; the last
    /// word (when no `""` closes it) ends at the track's duration (`range`/`editRate`), or 1 s after
    /// its start when the track has no usable range. Keyframes are read in time order; empty
    /// `value`s produce no word. Times use `editRate` (the project's, ticks per second).
    public static func words(_ track: SourceTrack, editRate: Int64) -> [TranscriptWord] {
        let kfs = track.object["parameters"]?.object?["transcription"]?.object?["keyframes"]?.array?.items
            .compactMap(\.object) ?? []
        let rate = Double(max(editRate, 1))
        let marks: [(t: Double, text: String)] = kfs.compactMap { k in
            guard let t = k["time"]?.double else { return nil }
            return (t / rate, k["value"]?.string ?? "")
        }
        .enumerated().sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
        let duration = track.durationSeconds
        var out: [TranscriptWord] = []
        for (i, m) in marks.enumerated() where !m.text.isEmpty {
            let end: Double
            if i + 1 < marks.count { end = marks[i + 1].t } else if duration > m.t { end = duration } else { end = m.t + 1 }
            out.append(TranscriptWord(text: m.text, start: m.t, end: max(end, m.t)))
        }
        return out
    }

    /// Whether the track carries `transcriptionSet: true`.
    public static func isSet(_ track: SourceTrack) -> Bool { track.object["transcriptionSet"]?.bool ?? false }
}
