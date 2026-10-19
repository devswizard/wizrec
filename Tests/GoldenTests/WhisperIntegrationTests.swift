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

    init(in dir: URL, models names: [String] = ["small"], fail: Bool = false) throws {
        self.dir = dir
        let fm = FileManager.default
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: models, withIntermediateDirectories: true)
        for n in names { try Data("ggml".utf8).write(to: models.appendingPathComponent("ggml-\(n).bin")) }
        try Data(canned.utf8).write(to: bin.appendingPathComponent("canned.json"))
        let body = fail ? "echo 'error: failed to load model' >&2; exit 3"
            : #"cp "$f" "$here/input.wav"; cp "$here/canned.json" "$of.json""#
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
        #expect(input.count == 44 + 2 * 64_000, "4 s at 16 kHz mono 16-bit")

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
