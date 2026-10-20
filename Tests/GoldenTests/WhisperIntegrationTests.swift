import AVFoundation
import Captions
import CoreMedia
import Foundation
import MediaEngine
import Testing
import TestGenKit
import TimelineEngine
import TSCProjKit

// S3-QA-1: whisper.cpp backend (S3-CAP-1) end to end with a fake `whisper-cli`
// (a shell script writing canned JSON): project media → Transcriber →
// ApplyTranscription → save → reopen → byte-identical undo. Temp dirs only.

/// whisper-cli `-oj -ojf` output: "Hello" 0–0.5 s, "world." 0.5–1.0 s, "again" 2.0–2.4 s.
private let canned = """
{"result": {"language": "en"}, "transcription": [
 {"offsets": {"from": 0, "to": 500}, "text": " Hello", "tokens": [{"text": " Hello", "offsets": {"from": 0, "to": 500}, "p": 0.9}]},
 {"offsets": {"from": 500, "to": 1000}, "text": " world.", "tokens": [{"text": " world.", "offsets": {"from": 500, "to": 1000}, "p": 0.8}]},
 {"offsets": {"from": 2000, "to": 2400}, "text": " again"}
]}
"""

/// A fake `whisper-cli` and models directory in `dir`. The script records its
/// arguments, copies its input WAV and writes `canned` to `<-of>.json`.
private struct FakeWhisperCLI {
    let dir: URL
    var bin: URL { dir.appendingPathComponent("bin", isDirectory: true) }
    var models: URL { dir.appendingPathComponent("models", isDirectory: true) }

    /// `body`: shell run after argument parsing (`$here`, `$f`, `$of` set); default copies
    /// the input WAV and writes `canned`.
    init(in dir: URL, models names: [String] = ["small"], fail: Bool = false, body custom: String? = nil) throws {
        self.dir = dir
        let fm = FileManager.default
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: models, withIntermediateDirectories: true)
        for n in names { try Data("ggml".utf8).write(to: models.appendingPathComponent("ggml-\(n).bin")) }
        try Data(canned.utf8).write(to: bin.appendingPathComponent("canned.json"))
        let body = fail ? "echo 'error: failed to load model' >&2; exit 3"
            : custom ?? #"cp "$f" "$here/input.wav"; cp "$here/canned.json" "$of.json""#
        let script = """
        #!/bin/sh
        here="$(cd "$(dirname "$0")" && pwd)"
        of=""; f=""; prev=""
        for a in "$@"; do
          [ "$prev" = "-of" ] && of="$a"
          [ "$prev" = "-f" ] && f="$a"
          prev="$a"
        done
        printf '%s\\n' "$@" > "$here/args.txt"
        \(body)

        """
        let exe = bin.appendingPathComponent("whisper-cli")
        try Data(script.utf8).write(to: exe)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
    }

    var recognizer: WhisperCppRecognizer { WhisperCppRecognizer(modelsDirectory: models, searchDirectories: [bin]) }

    func args() -> [String] {
        ((try? String(contentsOf: bin.appendingPathComponent("args.txt"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    var inputWAV: URL { bin.appendingPathComponent("input.wav") }
}

@Suite(.serialized) @MainActor struct WhisperIntegrationTests {

    /// Project with a 4 s 48 kHz mono WAV source (one audio track) on track 0 at 1 s.
    private func project(in dir: URL) throws -> (ProjectBundle, source: Int64, wav: URL, chain: EditChain) {
        let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("wh.cmproj"), width: 320, height: 180)
        let pcm = (0..<192_000).map { Float(sin(Double($0) * 0.05) * 0.3) }
        let wav = dir.appendingPathComponent("speech.wav")
        try AudioSignals.writeWAV(pcm, to: wav)
        let chain = EditChain(bundle.project)
        let add = AddSource(SourceDescriptor(src: try bundle.importFile(wav), lastModified: Date(timeIntervalSince1970: 1_792_000_000), tracks: [
            .init(type: 2, editRate: 48_000, rangeEnd: 192_000, width: 0, height: 0, sampleRate: Rational(48_000), bitDepth: 16, channelCount: 1),
        ]))
        try chain.run(add)
        let source = try #require(add.sourceID)
        try chain.run(InsertClip(sourceID: source, track: 0, start: frames(30)))
        return (bundle, source, bundle.resolve(try #require(bundle.project.source(id: source))), EditChain(bundle.project))
    }

    /// Fake whisper → words on the stream axis → ApplyTranscription → save → reopen: the
    /// transcript reads back frame-rounded; undo restores the bytes; the fake got 16 kHz mono
    /// for the whole source and `-l en` for "en-GB".
    @Test func whisperTranscriptionSaveReopenUndo() async throws {
        let dir = try scratchDir("whisper-int")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (bundle, source, wav, chain) = try project(in: dir)
        let fake = try FakeWhisperCLI(in: dir.appendingPathComponent("fake"))
        #expect(await fake.recognizer.status(language: "en-GB") == .ready)

        let media = try await MediaPool(diskCacheDirectory: nil).source(for: wav)
        let stream = try #require(media.info.streams.first { $0.kind == .audio })
        let words = try await Transcriber(backend: fake.recognizer).transcribe(media, stream: stream.index, language: "en-GB")
        #expect(words.map(\.text) == ["Hello", "world.", "again"])
        let args = fake.args()
        #expect(args.firstIndex(of: "-l").map { args[$0 + 1] } == "en")
        let input = try Data(contentsOf: fake.inputWAV)
        let expectedBytes: Int = 44 + 2 * 64_000
        #expect(input.count == expectedBytes, "4 s at 16 kHz mono 16-bit")

        let before = chain.project.serialized()
        try chain.run(ApplyTranscription(sourceID: source, track: 0, words: words))
        let stored = Transcript.words(in: chain.project, sourceID: source, track: 0)
        #expect(stored.map(\.text) == ["Hello", "world.", "again"])
        for (a, b) in zip(stored, words) { #expect(abs(a.start - b.start) <= 1.0 / 30 + 1e-9, "\(a.text)") }

        try bundle.saveWithBackup()
        let reopened = try ProjectBundle(url: bundle.directory)
        #expect(reopened.project.serialized() == chain.project.serialized())
        #expect(Transcript.words(in: reopened.project, sourceID: source, track: 0) == stored)
        #expect(ProjectInvariants.check(reopened.project).isEmpty)

        // Re-transcribing a sub-range replaces the transcript; words shift onto the stream axis.
        let range = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 48_000),
                                duration: CMTime(seconds: 3, preferredTimescale: 48_000))
        let later = try await Transcriber(backend: fake.recognizer).transcribe(media, stream: stream.index, range: range, language: nil)
        #expect(abs(later[0].start - 1) < 1e-3 && abs(later[2].start - 3) < 1e-3)
        #expect(fake.args().firstIndex(of: "-l").map { fake.args()[$0 + 1] } == "auto")
        try chain.run(ApplyTranscription(sourceID: source, track: 0, words: later))
        try chain.run(RemoveTranscription(sourceID: source, track: 0))
        try chain.expectUndoRedoWalk()
        try chain.undoAll()
        #expect(chain.project.serialized() == before)
    }

    /// No model, or a failing binary: the transcription throws and the project is never touched.
    @Test func whisperFailuresLeaveProjectUntouched() async throws {
        let dir = try scratchDir("whisper-fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, _, wav, chain) = try project(in: dir)
        let before = chain.project.serialized()
        let media = try await MediaPool(diskCacheDirectory: nil).source(for: wav)
        let stream = try #require(media.info.streams.first { $0.kind == .audio })

        let noModel = try FakeWhisperCLI(in: dir.appendingPathComponent("nomodel"), models: [])
        guard case .modelMissing = await noModel.recognizer.status(language: nil) else {
            Issue.record("expected modelMissing"); return
        }
        await #expect(throws: CaptionsError.self) {
            _ = try await Transcriber(backend: noModel.recognizer).transcribe(media, stream: stream.index, language: nil)
        }
        let failing = try FakeWhisperCLI(in: dir.appendingPathComponent("failing"), fail: true)
        await #expect(throws: (any Error).self) {
            _ = try await Transcriber(backend: failing.recognizer).transcribe(media, stream: stream.index, language: nil)
        }
        #expect(chain.project.serialized() == before)
    }
}

/// Fake whisper body for the timing tests: copies the input and answers "Hello" at 0.2–0.8 s and
/// "again" 0.8–0.2 s before the end of *its input* (so on a compacted buffer, inside the second
/// burst only after the times are mapped back).
private let endRelativeBody = #"""
cp "$f" "$here/input.wav"
sz=$(stat -f %z "$f"); ms=$(( (sz - 44) * 1000 / 32000 ))
printf '{"result":{"language":"en"},"transcription":[{"offsets":{"from":200,"to":800},"text":" Hello"},{"offsets":{"from":%d,"to":%d},"text":" again"}]}' $((ms - 800)) $((ms - 200)) > "$of.json"
"""#

/// S5-QA-1 / captions6: whisper timing fixes (energy compaction + time remap, silent audio, VAD
/// model) through a project with a fake `whisper-cli`: tone 0–1 s, silence 1–4 s, tone 4–5 s.
@Suite(.serialized) @MainActor struct WhisperTimingIntegrationTests {
    private func project(in dir: URL, silent: Bool = false)
        throws -> (ProjectBundle, source: Int64, wav: URL, chain: EditChain) {
        let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("wt.cmproj"), width: 320, height: 180)
        let pcm = (0..<240_000).map { i -> Float in
            let t = Double(i) / 48_000
            return !silent && (t < 1 || t >= 4) ? Float(sin(Double(i) * 0.05) * 0.3) : 0
        }
        let wav = dir.appendingPathComponent("bursts.wav")
        try AudioSignals.writeWAV(pcm, to: wav)
        let setup = EditChain(bundle.project)
        let add = AddSource(SourceDescriptor(src: try bundle.importFile(wav), lastModified: Date(timeIntervalSince1970: 1_792_000_000), tracks: [
            .init(type: 2, editRate: 48_000, rangeEnd: 240_000, width: 0, height: 0, sampleRate: Rational(48_000), bitDepth: 16, channelCount: 1),
        ]))
        try setup.run(add)
        let source = try #require(add.sourceID)
        try setup.run(InsertClip(sourceID: source, track: 0, start: frames(30)))
        return (bundle, source, bundle.resolve(try #require(bundle.project.source(id: source))), EditChain(bundle.project))
    }

    private func audio(_ wav: URL) async throws -> (any MediaSource, Int) {
        let media = try await MediaPool(diskCacheDirectory: nil).source(for: wav)
        let stream = try #require(media.info.streams.first { $0.kind == .audio })
        return (media, stream.index)
    }

    /// No VAD model: whisper gets a compacted buffer (the 3 s pause shortened), and the word it
    /// places near the end of that buffer comes back inside the second burst (4–5 s), not in
    /// the pause. Then ApplyTranscription → save → reopen → undo.
    @Test func compactedTimesMapBackThroughProject() async throws {
        let dir = try scratchDir("whisper-timing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (bundle, source, wav, chain) = try project(in: dir)
        let fake = try FakeWhisperCLI(in: dir.appendingPathComponent("fake"), body: endRelativeBody)
        #expect(fake.recognizer.resolvedVADModel() == nil)
        let (media, stream) = try await audio(wav)
        let words = try await Transcriber(backend: fake.recognizer).transcribe(media, stream: stream, language: "en")
        #expect(fake.args().contains("--vad") == false)

        let inputSeconds = Double(try Data(contentsOf: fake.inputWAV).count - 44) / 32_000
        print(String(format: "whisper timing: compacted input %.2f s of 5.00 s; words %@", inputSeconds,
                     words.map { String(format: "%@ %.3f–%.3f", $0.text, $0.start, $0.end) }.joined(separator: ", ")))
        #expect(inputSeconds < 3.5, "pause not compacted: whisper got \(inputSeconds) s")
        #expect(words.map(\.text) == ["Hello", "again"])
        if words.count == 2 {
            #expect(words[0].start >= 0 && words[0].end <= 1.05, "Hello at \(words[0].start)–\(words[0].end)")
            #expect(words[1].start >= 3.95 && words[1].end <= 5.0, "again at \(words[1].start)–\(words[1].end) (should be in 4–5 s)")
        }

        let before = chain.project.serialized()
        try chain.run(ApplyTranscription(sourceID: source, track: 0, words: words))
        let stored = Transcript.words(in: chain.project, sourceID: source, track: 0)
        #expect(stored.map(\.text) == words.map(\.text))
        for (a, b) in zip(stored, words) { #expect(abs(a.start - b.start) <= 1.0 / 30 + 1e-9, "\(a.text)") }
        try bundle.saveWithBackup()
        let reopened = try ProjectBundle(url: bundle.directory)
        #expect(Transcript.words(in: reopened.project, sourceID: source, track: 0) == stored)
        #expect(ProjectInvariants.check(reopened.project).isEmpty)
        try chain.undoAll()
        #expect(chain.project.serialized() == before)
    }

    /// A Silero model installed: `--vad -vm <model>` is passed, the buffer is not compacted, and
    /// the VAD model is not offered as a transcription model.
    @Test func vadModelIsPassedAndNotListed() async throws {
        let dir = try scratchDir("whisper-vad")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, _, wav, _) = try project(in: dir)
        let fake = try FakeWhisperCLI(in: dir.appendingPathComponent("fake"), models: ["small", "silero-v5.1.2"],
                                      body: endRelativeBody)
        #expect(WhisperCppRecognizer.installedModels(in: fake.models).map(\.name) == ["small"])
        #expect(fake.recognizer.resolvedVADModel()?.name == "silero-v5.1.2")
        let (media, stream) = try await audio(wav)
        let words = try await Transcriber(backend: fake.recognizer).transcribe(media, stream: stream, language: nil)
        let args = fake.args()
        #expect(args.contains("--vad"))
        #expect(args.firstIndex(of: "-vm").map { args[$0 + 1].hasSuffix("ggml-silero-v5.1.2.bin") } == true)
        #expect(try Data(contentsOf: fake.inputWAV).count == 44 + 2 * 80_000, "VAD path sends the whole 5 s")
        #expect(words.map(\.text) == ["Hello", "again"])

        // useVAD off (the preference): back to compaction.
        var off = fake.recognizer
        off.useVAD = false
        _ = try await Transcriber(backend: off).transcribe(media, stream: stream, language: nil)
        #expect(!fake.args().contains("--vad"))
    }

    /// Silent audio never reaches whisper (it hallucinates on silence): no words, no process run,
    /// project untouched.
    @Test func silentAudioSkipsWhisper() async throws {
        let dir = try scratchDir("whisper-silent")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, _, wav, chain) = try project(in: dir, silent: true)
        let before = chain.project.serialized()
        let fake = try FakeWhisperCLI(in: dir.appendingPathComponent("fake"), body: endRelativeBody)
        let (media, stream) = try await audio(wav)
        let words = try await Transcriber(backend: fake.recognizer).transcribe(media, stream: stream, language: nil)
        #expect(words.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fake.bin.appendingPathComponent("args.txt").path),
                "whisper-cli ran on silent audio")
        #expect(chain.project.serialized() == before)
    }
}

/// S5-QA-1: real whisper.cpp (`whisper-cli` + an installed ggml model) end to end through a
/// project: `say` speech → 48 kHz WAV imported into a bundle → clip at 1 s → Transcriber →
/// ApplyTranscription → save → reopen → undo. Opt in with `WIZREC_WHISPER_TESTS=1`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["WIZREC_WHISPER_TESTS"] == "1",
                             "set WIZREC_WHISPER_TESTS=1 (needs whisper-cli and a ggml model)"))
@MainActor struct WhisperLiveIntegrationTests {
    @Test func liveWhisperThroughProject() async throws {
        let recognizer = WhisperCppRecognizer.fromDefaults()
        guard recognizer.isAvailable else {
            Issue.record("whisper.cpp not available: \(await recognizer.status(language: nil))")
            return
        }
        let dir = try scratchDir("whisper-live-int")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("speech.wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["--data-format=LEI16@48000", "-o", wav.path,
                         "The quick brown fox jumps over the lazy dog. Then it runs home."]
        try say.run(); say.waitUntilExit()
        #expect(say.terminationStatus == 0)
        let samples = try Int64(AVAudioFile(forReading: wav).length)
        #expect(samples > 48_000, "say produced \(samples) samples")

        let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("live.cmproj"), width: 320, height: 180)
        let setup = EditChain(bundle.project)
        let add = AddSource(SourceDescriptor(src: try bundle.importFile(wav), lastModified: Date(timeIntervalSince1970: 1_792_000_000), tracks: [
            .init(type: 2, editRate: 48_000, rangeEnd: samples, width: 0, height: 0, sampleRate: Rational(48_000), bitDepth: 16, channelCount: 1),
        ]))
        try setup.run(add)
        let source = try #require(add.sourceID)
        try setup.run(InsertClip(sourceID: source, track: 0, start: frames(30)))
        let chain = EditChain(bundle.project)
        let before = chain.project.serialized()

        let file = bundle.resolve(try #require(bundle.project.source(id: source)))
        let media = try await MediaPool(diskCacheDirectory: nil).source(for: file)
        let stream = try #require(media.info.streams.first { $0.kind == .audio })
        let started = Date()
        let words = try await Transcriber(backend: recognizer).transcribe(media, stream: stream.index, language: "en-US")
        let seconds = Double(samples) / 48_000
        print(String(format: "whisper live: %.1f s audio in %.1f s: ", seconds, Date().timeIntervalSince(started))
              + words.map(\.text).joined(separator: " "))

        let normalised = Set(words.map { $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) })
        for w in ["quick", "brown", "fox", "lazy", "dog"] {
            #expect(normalised.contains(w), "missing \"\(w)\" in \(words.map(\.text))")
        }
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start })
        #expect(words.allSatisfy { $0.start >= 0 && $0.end <= seconds + 0.5 && $0.start <= $0.end })

        try chain.run(ApplyTranscription(sourceID: source, track: 0, words: words))
        let stored = Transcript.words(in: chain.project, sourceID: source, track: 0)
        #expect(stored.map(\.text) == words.map(\.text))
        try bundle.saveWithBackup()
        let reopened = try ProjectBundle(url: bundle.directory)
        #expect(Transcript.words(in: reopened.project, sourceID: source, track: 0) == stored)
        #expect(ProjectInvariants.check(reopened.project).isEmpty)
        try chain.expectUndoRedoWalk()
        try chain.undoAll()
        #expect(chain.project.serialized() == before)
    }
}
