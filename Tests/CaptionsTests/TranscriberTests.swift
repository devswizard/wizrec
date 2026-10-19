import CoreGraphics
import CoreMedia
import Foundation
import MediaEngine
import Testing
@testable import Captions

/// Reports each chunk as one word: text = chunk length in samples, at 0.1–0.2 s into the chunk.
private struct FakeBackend: TranscriptionBackend {
    var id = "fake"
    var displayName = "Fake"
    var preferredFormat = PCMFormat(sampleRate: 1000, channels: 1)
    var maxChunkSeconds: Double? = 10
    func status(language: String?) async -> BackendStatus { .ready }
    func requestAccess() async -> BackendStatus { .ready }
    func transcribe(_ audio: PCMBuffer, language: String?) async throws -> [TranscriptWord] {
        #expect(audio.format.channels == 1 && audio.channels.count == 1)
        return [TranscriptWord(text: "\(audio.frameCount)", start: 0.1, end: 0.2, confidence: 0.5)]
    }
}

/// An audio-only source whose samples are `signal(t)` at any requested rate.
private final class FakeSource: MediaSource {
    let info: MediaInfo
    let seconds: Double
    init(seconds: Double) {
        self.seconds = seconds
        let d = CMTime(seconds: seconds, preferredTimescale: 1000)
        info = MediaInfo(url: URL(fileURLWithPath: "/fake.wav"), kind: .movie,
                         streams: [StreamInfo(index: 0, kind: .audio, codec: "pcm", sampleRate: 1000, channelCount: 2, duration: d)],
                         duration: d)
    }
    func frame(stream: Int, at time: CMTime) async throws -> VideoFrame { throw MediaError.notImplemented }
    func thumbnail(stream: Int, at time: CMTime, maxPixelSize: Int) async throws -> CGImage { throw MediaError.notImplemented }
    func audio(stream: Int, range: CMTimeRange, format: PCMFormat) async throws -> PCMBuffer {
        let n = Int((range.duration.seconds * format.sampleRate).rounded())
        let t0 = range.start.seconds
        // Loud everywhere except a silent gap at 8.5–8.7 s.
        let x: [Float] = (0..<n).map { i in
            let t = t0 + Double(i) / format.sampleRate
            return (8.5..<8.7).contains(t) ? 0 : (i % 2 == 0 ? 0.5 : -0.5)
        }
        return PCMBuffer(format: format, startTime: range.start, frameCount: n,
                         channels: Array(repeating: x, count: format.channels))
    }
}

@Suite struct TranscriberTests {
    @Test func chunksCutAtQuietestPoint() {
        var x = [Float](repeating: 0.5, count: 25_000)
        for i in 8_500..<8_700 { x[i] = 0 }
        let c = Transcriber.chunks(x, sampleRate: 1000, maxSeconds: 10, searchSeconds: 5)
        #expect(c.first?.lowerBound == 0 && c.last?.upperBound == 25_000)
        #expect(zip(c, c.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
        #expect(c.allSatisfy { $0.count <= 10_000 })
        #expect((8_500...8_700).contains(c[0].upperBound))
        #expect(Transcriber.chunks(x, sampleRate: 1000, maxSeconds: nil, searchSeconds: 5) == [0..<25_000])
        #expect(Transcriber.chunks([], sampleRate: 1000, maxSeconds: 10, searchSeconds: 5).isEmpty)
    }

    @Test func mixdownAndResample() {
        let pcm = PCMBuffer(format: PCMFormat(sampleRate: 2, channels: 2), startTime: .zero, frameCount: 2,
                            channels: [[1, 0], [0, 1]])
        #expect(Transcriber.mixdown(pcm) == [0.5, 0.5])
        #expect(Transcriber.resample([0, 1, 2, 3], from: 4, to: 2) == [0, 2])
        #expect(Transcriber.resample([0, 2], from: 1, to: 2) == [0, 1, 2, 2])
    }

    @Test func transcribesStreamInChunksOnStreamAxis() async throws {
        let src = FakeSource(seconds: 25)
        let progress = ProgressLog()
        let words = try await Transcriber(backend: FakeBackend())
            .transcribe(src, stream: 0, language: "en", progress: { progress.add($0) })
        #expect(words.count == 3)
        let lengths = words.compactMap { Int($0.text) }
        #expect(lengths.reduce(0, +) == 25_000)
        // Each word sits 0.1 s into its chunk, on the stream's axis.
        var start = 0.0
        for (w, n) in zip(words, lengths) {
            #expect(abs(w.start - (start + 0.1)) < 1e-9 && abs(w.end - (start + 0.2)) < 1e-9)
            start += Double(n) / 1000
        }
        #expect(progress.values == [1.0 / 3, 2.0 / 3, 1])
        // A sub-range keeps stream time.
        let part = try await Transcriber(backend: FakeBackend())
            .transcribe(src, stream: 0, range: CMTimeRange(start: CMTime(value: 3, timescale: 1), duration: CMTime(value: 2, timescale: 1)),
                        language: nil)
        #expect(part.count == 1 && abs(part[0].start - 3.1) < 1e-9)
        await #expect(throws: CaptionsError.self) { try await Transcriber(backend: FakeBackend()).transcribe(src, stream: 4, language: nil) }
    }

    @Test func localeMapping() {
        let supported: Set<Locale> = [Locale(identifier: "en-US"), Locale(identifier: "en-GB"), Locale(identifier: "bn-IN"),
                                      Locale(identifier: "zh_CN")]
        #expect(AppleSpeechRecognizer.locale(for: "en-GB", supported: supported)?.identifier == "en-GB")
        #expect(AppleSpeechRecognizer.locale(for: "zh-CN", supported: supported)?.identifier == "zh-CN")
        #expect(AppleSpeechRecognizer.locale(for: "bn", supported: supported)?.identifier == "bn-IN")
        #expect(["en-US", "en-GB"].contains(AppleSpeechRecognizer.locale(for: "en", supported: supported)?.identifier ?? ""))
        #expect(AppleSpeechRecognizer.locale(for: "fr", supported: supported) == nil)
        #expect(TranscriptionBackends.backend(id: "apple-speech") != nil)
        #expect(AppleSpeechRecognizer().preferredFormat == PCMFormat(sampleRate: 16_000, channels: 1))
    }
}

private final class ProgressLog: @unchecked Sendable {
    // @unchecked: only touched under `lock`.
    private let lock = NSLock()
    private var v: [Double] = []
    func add(_ x: Double) { lock.lock(); v.append(x); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return v }
}

/// Real Apple Speech. Needs the Speech Recognition permission for the test runner, so it runs only
/// with `WIZREC_SPEECH_TESTS=1` (never by default).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WIZREC_SPEECH_TESTS"] == "1"))
struct AppleSpeechLiveTests {
    @Test func transcribesSynthesizedSpeech() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-speech-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("say.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", file.path, "The quick brown fox jumps over the lazy dog."]
        try say.run(); say.waitUntilExit()
        let backend = AppleSpeechRecognizer()
        var status = await backend.status(language: "en-US")
        if status == .needsPermission { status = await backend.requestAccess() }
        try #require(status == .ready, "status \(status)")
        let source = try await MediaPool(diskCacheDirectory: nil).source(for: file)
        let words = try await Transcriber(backend: backend).transcribe(source, stream: 0, language: "en-US")
        let text = words.map { $0.text.lowercased() }.joined(separator: " ")
        #expect(text.contains("quick") && text.contains("fox"))
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start })
    }
}
