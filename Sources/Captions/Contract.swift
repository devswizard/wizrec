// Public interface of Captions (agent "captions", M10), frozen by coordination/CONTRACTS.md.
// Changing anything here needs an API_CHANGE message and the lead's approval.

import Foundation
import MediaEngine
import TSCProjKit

// `TranscriptWord` (one recognised word, seconds of source media time) lives in CaptionLayout
// (approved API_CHANGE, 2026-10-19) and is re-exported here, so `import Captions` still provides it.
@_exported import CaptionLayout

public enum CaptionsError: Error, Sendable, Equatable {
    case notImplemented
    case modelUnavailable(String)
    case permissionDenied
    case parse(String)
}

/// Local speech-to-text. Implementations: Apple Speech (on-device) and whisper.cpp.
public protocol SpeechRecognizer: Sendable {
    /// Words for mono `audio`; `language` BCP-47 or nil for auto-detect.
    func transcribe(_ audio: PCMBuffer, language: String?) async throws -> [TranscriptWord]
}

/// One caption cue, seconds of timeline time.
public struct CaptionCue: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

/// SRT / WebVTT import and export.
public enum SubtitleFile {
    /// Plain-text cues of an SRT file (markup stripped); see `SubtitleDocument.parseSRT` for tolerance.
    public static func parseSRT(_ text: String) throws -> [CaptionCue] { try SubtitleDocument.parseSRT(text).captionCues }
    /// Plain-text cues of a WebVTT file (markup stripped, entities decoded).
    public static func parseVTT(_ text: String) throws -> [CaptionCue] { try SubtitleDocument.parseVTT(text).captionCues }
    /// SRT, cues numbered from 1, millisecond times.
    public static func srt(_ cues: [CaptionCue]) -> String {
        SubtitleDocument(format: .srt, blocks: cues.enumerated().map { i, c in
            .cue(.init(identifier: String(i + 1), start: c.start, end: c.end, rawText: SubtitleFile.payload(c.text)))
        }).text()
    }
    /// WebVTT; text is escaped (`&`, `<`, `>`).
    public static func vtt(_ cues: [CaptionCue]) -> String {
        SubtitleDocument(format: .vtt, blocks: cues.map { c in
            .cue(.init(start: c.start, end: c.end, rawText: SubtitleFile.payload(SubtitleMarkup.escapeVTT(c.text))))
        }).text()
    }
}
