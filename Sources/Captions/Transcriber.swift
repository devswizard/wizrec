import CoreMedia
import Foundation
import MediaEngine

/// Whether a transcription backend can run right now. Checking never shows system UI.
public enum BackendStatus: Sendable, Equatable {
    case ready
    /// Permission was never asked; `requestAccess()` asks (may show system UI).
    case needsPermission
    /// The user (or a policy) refused permission.
    case permissionDenied
    /// A model or on-device language pack is missing; the string says which.
    case modelMissing(String)
    /// The backend has no recogniser for this language (BCP-47).
    case languageUnsupported(String)
    /// Anything else (service down, binary missing); the string says what.
    case unavailable(String)
}

/// A pluggable local speech-to-text engine: Apple Speech (`AppleSpeechRecognizer`) now, whisper.cpp
/// later. `Transcriber` feeds it mono PCM in `preferredFormat`, at most `maxChunkSeconds` per call,
/// and shifts the returned word times (seconds from the start of the buffer) onto the stream.
///
/// A whisper.cpp backend would be `id` `"whisper.cpp"`, 16 kHz mono, `maxChunkSeconds` 30, and
/// report `.modelMissing` until a ggml model exists in the models directory.
public protocol TranscriptionBackend: SpeechRecognizer {
    /// Stable identifier for preferences, e.g. `"apple-speech"`, `"whisper.cpp"`.
    var id: String { get }
    /// Name shown in the UI.
    var displayName: String { get }
    /// Mono PCM format the backend wants (channels is always 1).
    var preferredFormat: PCMFormat { get }
    /// Longest audio per `transcribe` call, seconds; nil = any length.
    var maxChunkSeconds: Double? { get }
    /// Whether `transcribe` can run for `language` (BCP-47, nil = the backend's default). Never prompts.
    func status(language: String?) async -> BackendStatus
    /// Asks for the permission the backend needs (may show system UI) and returns the new status.
    func requestAccess() async -> BackendStatus
}

/// The backends built into this build, most preferred first.
public enum TranscriptionBackends {
    public static var all: [any TranscriptionBackend] { [AppleSpeechRecognizer()] }

    /// The backend with `id`, if built in.
    public static func backend(id: String) -> (any TranscriptionBackend)? { all.first { $0.id == id } }
}

/// Runs a backend over a whole audio stream: decode → mono → chunks cut at quiet points →
/// `transcribe` → words on the stream's time axis (seconds of source media time, the axis
/// `ApplyTranscription` expects).
public struct Transcriber: Sendable {
    public var backend: any TranscriptionBackend
    /// A chunk boundary is placed at the quietest 20-ms window within this many seconds before
    /// the chunk limit, so words are rarely cut in half.
    public var boundarySearchSeconds: Double

    public init(backend: any TranscriptionBackend, boundarySearchSeconds: Double = 5) {
        self.backend = backend; self.boundarySearchSeconds = boundarySearchSeconds
    }

    /// Words of `stream` of `source` within `range` (stream time; nil = the whole stream), sorted by
    /// start, times in seconds of stream time. `progress` receives 0…1 after each chunk. Checks for
    /// task cancellation between chunks.
    public func transcribe(_ source: any MediaSource, stream: Int, range: CMTimeRange? = nil, language: String?,
                           progress: (@Sendable (Double) -> Void)? = nil) async throws -> [TranscriptWord] {
        guard let info = source.info.streams.first(where: { $0.index == stream }), info.kind == .audio else {
            throw CaptionsError.parse("stream \(stream) is not audio")
        }
        let r = range ?? CMTimeRange(start: .zero, duration: info.duration)
        let format = PCMFormat(sampleRate: backend.preferredFormat.sampleRate, channels: 1)
        let pcm = try await source.audio(stream: stream, range: r, format: format)
        return try await transcribe(pcm, language: language, progress: progress)
    }

    /// Words of a decoded buffer (any channel count; mixed down to mono), seconds on the buffer's
    /// `startTime` axis.
    public func transcribe(_ pcm: PCMBuffer, language: String?,
                           progress: (@Sendable (Double) -> Void)? = nil) async throws -> [TranscriptWord] {
        let rate = backend.preferredFormat.sampleRate
        var mono = Self.mixdown(pcm)
        if pcm.format.sampleRate != rate { mono = Self.resample(mono, from: pcm.format.sampleRate, to: rate) }
        let origin = pcm.startTime.isNumeric ? pcm.startTime.seconds : 0
        let chunks = Self.chunks(mono, sampleRate: rate, maxSeconds: backend.maxChunkSeconds,
                                 searchSeconds: boundarySearchSeconds)
        var out: [TranscriptWord] = []
        for (i, c) in chunks.enumerated() {
            try Task.checkCancellation()
            let buf = PCMBuffer(format: PCMFormat(sampleRate: rate, channels: 1), startTime: .zero,
                                frameCount: c.count, channels: [Array(mono[c])])
            let offset = origin + Double(c.lowerBound) / rate
            let words = try await backend.transcribe(buf, language: language)
            out += words.map { w in
                var w = w; w.end = max(w.end, w.start) + offset; w.start += offset; return w
            }
            progress?(Double(i + 1) / Double(chunks.count))
        }
        return out.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
    }

    /// Average of all channels.
    static func mixdown(_ pcm: PCMBuffer) -> [Float] {
        guard let first = pcm.channels.first else { return [] }
        guard pcm.channels.count > 1 else { return first }
        let n = pcm.channels.map(\.count).min() ?? 0
        let k = 1 / Float(pcm.channels.count)
        return (0..<n).map { i in pcm.channels.reduce(0) { $0 + $1[i] } * k }
    }

    /// Linear-interpolation resampling (only used when a source hands back another rate).
    static func resample(_ x: [Float], from a: Double, to b: Double) -> [Float] {
        guard a > 0, b > 0, !x.isEmpty else { return x }
        let n = Int((Double(x.count) * b / a).rounded())
        return (0..<n).map { i in
            let p = Double(i) * a / b
            let j = min(Int(p), x.count - 1), f = Float(p - Double(j))
            return j + 1 < x.count ? x[j] * (1 - f) + x[j + 1] * f : x[j]
        }
    }

    /// Consecutive sample ranges covering `x`, each at most `maxSeconds` long (nil = one chunk). Each
    /// cut sits at the centre of the quietest 20-ms window in the last `searchSeconds` of the chunk
    /// (the latest such window on ties).
    static func chunks(_ x: [Float], sampleRate: Double, maxSeconds: Double?, searchSeconds: Double) -> [Range<Int>] {
        guard let maxSeconds, maxSeconds > 0 else { return x.isEmpty ? [] : [0..<x.count] }
        let limit = max(Int(maxSeconds * sampleRate), 1)
        let search = min(max(Int(searchSeconds * sampleRate), 0), limit / 2)
        let win = max(Int(0.02 * sampleRate), 1)
        var out: [Range<Int>] = []
        var cursor = 0
        while x.count - cursor > limit {
            let hi = cursor + limit, lo = hi - search
            var cut = hi
            if search >= win {
                var best = Float.infinity
                var s = lo
                while s + win <= hi {
                    var e: Float = 0
                    for i in s..<(s + win) { e += x[i] * x[i] }
                    if e <= best { best = e; cut = s + win / 2 }  // ties: latest, for longer chunks
                    s += win / 2
                }
            }
            out.append(cursor..<cut)
            cursor = cut
        }
        if cursor < x.count { out.append(cursor..<x.count) }
        return out
    }
}
