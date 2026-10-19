// Public interface of Captions (agent "captions", M10), frozen by coordination/CONTRACTS.md.
// Changing anything here needs an API_CHANGE message and the lead's approval.

import Foundation
import MediaEngine
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
    public static func parseSRT(_ text: String) throws -> [CaptionCue] { throw CaptionsError.notImplemented }
    public static func parseVTT(_ text: String) throws -> [CaptionCue] { throw CaptionsError.notImplemented }
    public static func srt(_ cues: [CaptionCue]) -> String { "" }
    public static func vtt(_ cues: [CaptionCue]) -> String { "WEBVTT\n" }
}
