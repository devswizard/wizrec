import CoreMedia
import Foundation
import MediaEngine
import Testing
@testable import Captions

/// whisper-cli output for three words, a blank-audio annotation and a two-word segment
/// (Bengali "আমার সোনার" = "my golden"), in the shape of `-oj -ojf -ml 1 -sow`.
private let cannedJSON = """
{
  "systeminfo": "fake",
  "model": {"type": "small", "multilingual": true},
  "params": {"model": "ggml-small.bin", "language": "bn", "translate": false},
  "result": {"language": "bn"},
  "transcription": [
    {"timestamps": {"from": "00:00:00,000", "to": "00:00:00,500"}, "offsets": {"from": 0, "to": 500},
     "text": " Hello", "tokens": [
       {"text": "[_BEG_]", "offsets": {"from": 0, "to": 0}, "id": 50364, "p": 0.1},
       {"text": " Hello", "offsets": {"from": 0, "to": 500}, "id": 2425, "p": 0.9}]},
    {"timestamps": {"from": "00:00:00,500", "to": "00:00:01,000"}, "offsets": {"from": 500, "to": 1000},
     "text": " world.", "tokens": [
       {"text": " world", "offsets": {"from": 500, "to": 900}, "id": 1002, "p": 0.8},
       {"text": ".", "offsets": {"from": 900, "to": 1000}, "id": 13, "p": 0.6}]},
    {"timestamps": {"from": "00:00:01,000", "to": "00:00:02,000"}, "offsets": {"from": 1000, "to": 2000},
     "text": " [BLANK_AUDIO]"},
    {"timestamps": {"from": "00:00:02,000", "to": "00:00:03,000"}, "offsets": {"from": 2000, "to": 3000},
     "text": " আমার সোনার"}
  ]
}
"""

/// A temporary directory with a fake `whisper-cli` shell script and a models directory.
private struct FakeWhisper {
    let dir: URL
    var bin: URL { dir.appendingPathComponent("bin", isDirectory: true) }
    var models: URL { dir.appendingPathComponent("models", isDirectory: true) }
    var exe: URL { bin.appendingPathComponent("whisper-cli") }

    /// `body` runs after `$of` (the `-of` value) and `$here` (the script directory) are set.
    init(body: String, json: String = cannedJSON, models names: [String] = ["small"]) throws {
        let fm = FileManager.default
        dir = fm.temporaryDirectory.appendingPathComponent("wizrec-fake-whisper-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("models"), withIntermediateDirectories: true)
        for n in names { try Data("ggml".utf8).write(to: models.appendingPathComponent("ggml-\(n).bin")) }
        try Data(json.utf8).write(to: bin.appendingPathComponent("canned.json"))
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
        try Data(script.utf8).write(to: exe)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
    }

    /// Writes the canned JSON, copies the input WAV, reports progress on stderr.
    static let ok = """
    cp "$f" "$here/input.wav"
    echo "whisper_print_progress_callback: progress =  50%" >&2
    echo "whisper_print_progress_callback: progress = 100%" >&2
    cp "$here/canned.json" "$of.json"
    """

    func recognizer(model: String? = nil) -> WhisperCppRecognizer {
        WhisperCppRecognizer(model: model, modelsDirectory: models, searchDirectories: [bin])
    }

    func args() -> [String] {
        ((try? String(contentsOf: bin.appendingPathComponent("args.txt"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func remove() { try? FileManager.default.removeItem(at: dir) }
}

private func tone(seconds: Double, rate: Double = 48_000, channels: Int = 2, start: Double = 0) -> PCMBuffer {
    let n = Int(seconds * rate)
    let x = (0..<n).map { Float(sin(Double($0) * 0.05) * 0.3) }
    return PCMBuffer(format: PCMFormat(sampleRate: rate, channels: channels),
                     startTime: CMTime(seconds: start, preferredTimescale: 48_000), frameCount: n,
                     channels: Array(repeating: x, count: channels))
}

/// Collects progress values from any thread.
private final class Progress: @unchecked Sendable {  // @unchecked: `values` is guarded by `lock`
    private let lock = NSLock()
    private var _values: [Double] = []
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return _values }
    func add(_ v: Double) { lock.lock(); _values.append(v); lock.unlock() }
}

@Suite struct WhisperCppTests {
    @Test func parsesWordsSkipsAnnotationsAndSplitsMultiWordSegments() throws {
        let w = try WhisperCppRecognizer.parseJSON(Data(cannedJSON.utf8))
        #expect(w.map(\.text) == ["Hello", "world.", "আমার", "সোনার"])
        #expect(w[0].start == 0 && w[0].end == 0.5)
        #expect(abs(w[0].confidence - 0.9) < 1e-9)  // [_BEG_] ignored
        #expect(abs(w[1].confidence - 0.7) < 1e-9)
        #expect(w[2].confidence == 1)  // no tokens
        #expect(w[2].start == 2 && w[3].end == 3)
        #expect(w[2].end == w[3].start && w[2].end > 2 && w[2].end < 3)
    }

    @Test func toleratesInvalidUTF8AndRejectsGarbage() throws {
        var d = Data(#"{"transcription":[{"offsets":{"from":0,"to":100},"text":" ok","tokens":[{"text":""#.utf8)
        d.append(0xE0)  // the first byte of a three-byte character, alone
        d.append(contentsOf: Array(#"","p":0.5}]},{"offsets":{"from":100,"to":200},"text":" x"#.utf8))
        d.append(0xA6)
        d.append(contentsOf: Array(#""}]}"#.utf8))
        let w = try WhisperCppRecognizer.parseJSON(d)
        #expect(w.map(\.text) == ["ok"])  // the broken word is dropped
        #expect(throws: CaptionsError.self) { try WhisperCppRecognizer.parseJSON(Data("[]".utf8)) }
        #expect(throws: CaptionsError.self) { try WhisperCppRecognizer.parseJSON(Data("{}".utf8)) }
        #expect(try WhisperCppRecognizer.parseJSON(Data(#"{"transcription":[]}"#.utf8)).isEmpty)
    }

    @Test func languageArgument() {
        #expect(WhisperCppRecognizer.whisperLanguage(nil) == "auto")
        #expect(WhisperCppRecognizer.whisperLanguage("") == "auto")
        #expect(WhisperCppRecognizer.whisperLanguage("bn-IN") == "bn")
        #expect(WhisperCppRecognizer.whisperLanguage("en_US") == "en")
        #expect(WhisperCppRecognizer.whisperLanguage("BN") == "bn")
    }

    @Test func progressLines() {
        #expect(WhisperCppRecognizer.progress(fromLine: "whisper_print_progress_callback: progress =  42%") == 0.42)
        #expect(WhisperCppRecognizer.progress(fromLine: "whisper_init: loading model") == nil)
    }

    @Test func modelsAndPreference() throws {
        let f = try FakeWhisper(body: "", models: ["base.en", "medium", "small-q5_1", "tiny"])
        defer { f.remove() }
        try Data().write(to: f.models.appendingPathComponent("ggml-empty.bin"))  // zero bytes: ignored
        try Data("x".utf8).write(to: f.models.appendingPathComponent("notes.txt"))
        let all = WhisperCppRecognizer.installedModels(in: f.models)
        #expect(all.map(\.name) == ["base.en", "medium", "small-q5_1", "tiny"])
        #expect(all[0].isEnglishOnly && !all[1].isEnglishOnly)
        #expect(WhisperCppRecognizer.preferredModel(in: all)?.name == "small-q5_1")
        #expect(WhisperCppRecognizer.preferredModel(in: Array(all.dropFirst(2)))?.name == "small-q5_1")
        #expect(WhisperCppRecognizer.preferredModel(in: [all[0]])?.name == "base.en")
        #expect(WhisperCppRecognizer.preferredModel(in: []) == nil)
        #expect(f.recognizer(model: "tiny").resolvedModel()?.name == "tiny")
        #expect(f.recognizer(model: "large").resolvedModel() == nil)
        #expect(WhisperCppRecognizer.installedModels(in: f.dir.appendingPathComponent("nope")).isEmpty)
    }

    @Test func locatesBinary() throws {
        let f = try FakeWhisper(body: "")
        defer { f.remove() }
        let other = f.dir.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let old = other.appendingPathComponent("whisper-cpp")
        try FileManager.default.copyItem(at: f.exe, to: old)
        // The current name wins over the old one, whatever the directory order.
        #expect(WhisperCppRecognizer.locateBinary(explicit: nil, in: [other, f.bin]) == f.exe)
        #expect(WhisperCppRecognizer.locateBinary(explicit: nil, in: [other]) == old)
        #expect(WhisperCppRecognizer.locateBinary(explicit: old, in: [f.bin]) == old)
        #expect(WhisperCppRecognizer.locateBinary(explicit: f.models, in: [f.bin]) == nil)  // not executable file
        #expect(WhisperCppRecognizer.locateBinary(explicit: nil, in: []) == nil)
        let dirs = WhisperCppRecognizer.defaultSearchDirectories(environment: ["PATH": "/a:/opt/homebrew/bin"])
        #expect(dirs.map(\.path) == ["/a", "/opt/homebrew/bin", "/usr/local/bin"])
    }

    @Test func statusDegradesGracefully() async throws {
        let f = try FakeWhisper(body: "", models: [])
        defer { f.remove() }
        let none = WhisperCppRecognizer(modelsDirectory: f.models, searchDirectories: [])
        guard case .unavailable = await none.status(language: nil) else { Issue.record("binary missing"); return }
        #expect(!none.isAvailable)
        #expect(none.displayName == "whisper.cpp")
        let noModel = f.recognizer()
        guard case .modelMissing = await noModel.status(language: nil) else { Issue.record("model missing"); return }
        #expect(!noModel.isAvailable)
        await #expect(throws: CaptionsError.self) { _ = try await noModel.transcribe(tone(seconds: 1), language: nil) }

        try Data("ggml".utf8).write(to: f.models.appendingPathComponent("ggml-base.en.bin"))
        #expect(f.recognizer().isAvailable)
        #expect(f.recognizer().displayName == "whisper.cpp (base.en)")
        #expect(await f.recognizer().status(language: "en-US") == .ready)
        #expect(await f.recognizer().status(language: nil) == .ready)
        #expect(await f.recognizer().status(language: "bn") == .languageUnsupported("bn"))
        #expect(await f.recognizer().requestAccess() == .ready)
        guard case .modelMissing = await f.recognizer(model: "small").status(language: nil) else {
            Issue.record("chosen model missing"); return
        }
        let bad = WhisperCppRecognizer(binary: f.models, modelsDirectory: f.models)
        guard case .unavailable = await bad.status(language: nil) else { Issue.record("bad binary"); return }
    }

    @Test func fromDefaults() {
        let name = "wizrec-whisper-tests-\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: name) else { Issue.record("defaults"); return }
        defer { d.removePersistentDomain(forName: name) }
        #expect(WhisperCppRecognizer.fromDefaults(d).binary == nil)
        #expect(WhisperCppRecognizer.fromDefaults(d).model == nil)
        d.set("", forKey: WhisperSettings.binaryPathKey)
        #expect(WhisperCppRecognizer.fromDefaults(d).binary == nil)
        d.set("/x/whisper-cli", forKey: WhisperSettings.binaryPathKey)
        d.set("medium", forKey: WhisperSettings.modelKey)
        #expect(WhisperCppRecognizer.fromDefaults(d).binary?.path == "/x/whisper-cli")
        #expect(WhisperCppRecognizer.fromDefaults(d).model == "medium")
        #expect(TranscriptionBackends.preferred(d).id == "apple-speech")
        d.set("whisper.cpp", forKey: WhisperSettings.backendKey)
        #expect(TranscriptionBackends.preferred(d).id == "whisper.cpp")
        #expect(TranscriptionBackends.backend(id: "whisper.cpp") != nil)
    }

    @Test func transcribesThroughFakeBinary() async throws {
        let f = try FakeWhisper(body: FakeWhisper.ok)
        defer { f.remove() }
        let progress = Progress()
        // Starts at 10 s of stream time: words land on the stream axis.
        let words = try await Transcriber(backend: f.recognizer())
            .transcribe(tone(seconds: 2, start: 10), language: "bn-BD") { progress.add($0) }
        #expect(words.map(\.text) == ["Hello", "world.", "আমার", "সোনার"])
        #expect(abs(words[0].start - 10) < 1e-6 && abs(words[3].end - 13) < 1e-6)

        let args = f.args()
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        #expect(value("-l") == "bn")
        #expect(value("-ml") == "1")
        #expect(value("-m")?.hasSuffix("ggml-small.bin") == true)
        #expect(args.contains("-oj") && args.contains("-ojf") && args.contains("-sow") && args.contains("-pp"))
        // The temporary directory is gone afterwards.
        if let of = value("-of") { #expect(!FileManager.default.fileExists(atPath: (of as NSString).deletingLastPathComponent)) }

        let wav = try Data(contentsOf: f.bin.appendingPathComponent("input.wav"))
        #expect(wav.count == 44 + 2 * 32_000)  // 2 s, 16 kHz, mono, 16-bit
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        let rate = wav[24..<28].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        let channels = Int(wav[22]) | Int(wav[23]) << 8
        #expect(rate == 16_000 && channels == 1)

        #expect(progress.values.contains(0.5))
        #expect(progress.values.last == 1)
        #expect(zip(progress.values, progress.values.dropFirst()).allSatisfy { $0 <= $1 })

        _ = try await f.recognizer().transcribe(tone(seconds: 1, rate: 16_000, channels: 1), language: nil)
        #expect(f.args().firstIndex(of: "-l").map { f.args()[$0 + 1] } == "auto")
        #expect(try await f.recognizer().transcribe(tone(seconds: 0), language: nil).isEmpty)
    }

    @Test func reportsProcessFailure() async throws {
        let f = try FakeWhisper(body: #"echo "error: failed to open model" >&2; exit 3"#)
        defer { f.remove() }
        do {
            _ = try await f.recognizer().transcribe(tone(seconds: 1), language: nil)
            Issue.record("expected failure")
        } catch CaptionsError.modelUnavailable(let m) {
            #expect(m.contains("exit 3") && m.contains("failed to open model"))
        }
    }

    @Test func cancellationTerminatesProcess() async throws {
        let f = try FakeWhisper(body: #"echo $$ > "$here/pid"; exec sleep 30"#)
        defer { f.remove() }
        let r = f.recognizer()
        let task = Task { try await r.transcribe(tone(seconds: 1), language: nil) }
        let pidFile = f.bin.appendingPathComponent("pid")
        var pid: Int32?
        for _ in 0..<100 where pid == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
            pid = (try? String(contentsOf: pidFile, encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let started = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(started) < 5)
        guard let pid else { Issue.record("fake whisper never started"); return }
        var gone = false
        for _ in 0..<50 where !gone {
            gone = kill(pid, 0) != 0
            if !gone { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        #expect(gone)
    }

    /// Real whisper.cpp on a short spoken clip. Opt in with `WIZREC_WHISPER_TESTS=1`; needs
    /// `whisper-cli` and a model. `WIZREC_WHISPER_AUDIO` may point at any audio file (default: the
    /// `say` voice reading a sentence).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIZREC_WHISPER_TESTS"] == "1"))
    func liveWhisper() async throws {
        let r = WhisperCppRecognizer.fromDefaults()
        guard r.isAvailable else {
            print("whisper.cpp live test skipped: \(await r.status(language: nil))")
            return
        }
        let env = ProcessInfo.processInfo.environment
        var url: URL
        if let path = env["WIZREC_WHISPER_AUDIO"] {
            url = URL(fileURLWithPath: path)
        } else {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-whisper-live-\(UUID().uuidString).aiff")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-o", url.path, "The quick brown fox jumps over the lazy dog."]
            try say.run(); say.waitUntilExit()
        }
        let media = try await MediaPool(diskCacheDirectory: nil).source(for: url)
        guard let stream = media.info.streams.first(where: { $0.kind == .audio }) else {
            Issue.record("no audio stream"); return
        }
        let words = try await Transcriber(backend: r).transcribe(media, stream: stream.index,
                                                                 language: env["WIZREC_WHISPER_LANG"])
        print("whisper.cpp:", words.map(\.text).joined(separator: " "))
        #expect(!words.isEmpty)
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start })
    }
}
