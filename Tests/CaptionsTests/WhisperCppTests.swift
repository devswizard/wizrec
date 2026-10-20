import CoreMedia
import Foundation
import MediaEngine
import Testing
import WizRecTestSupport
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
            .transcribe(tone(seconds: 3, start: 10), language: "bn-BD") { progress.add($0) }
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
        let expectedBytes3s: Int = 44 + 3 * 32_000
        #expect(wav.count == expectedBytes3s)  // 3 s, 16 kHz, mono, 16-bit (all voiced: nothing cut)
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
        let stopped = Date().timeIntervalSince(started)
        LoadGate.expect(stopped < 5, "cancel stopped whisper-cli within 5 s, took \(stopped) s")
        guard let pid else { Issue.record("fake whisper never started"); return }
        var gone = false
        for _ in 0..<50 where !gone {
            gone = kill(pid, 0) != 0
            if !gone { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        #expect(gone)
    }

    /// 8 s of 16 kHz mono: silence 0–3, speech 3–4, silence 4–6, speech 6–7, silence 7–8.
    private static func pausedSpeech() -> PCMBuffer {
        let x = speechLike([(3, 0), (1, 0.3), (2, 0), (1, 0.3), (1, 0)])
        return PCMBuffer(format: PCMFormat(sampleRate: 16_000, channels: 1), startTime: .zero,
                         frameCount: x.count, channels: [x])
    }

    /// whisper output on the compacted audio (pieces 2.8–4.2 s → 0–1.4 s, 5.8–7.2 s → 1.7–3.1 s):
    /// "dog." runs into the inserted gap, "Next" starts in it.
    private static let compactedJSON = """
    {"transcription": [
      {"offsets": {"from": 0, "to": 400}, "text": " The"},
      {"offsets": {"from": 400, "to": 1650}, "text": " dog."},
      {"offsets": {"from": 1650, "to": 2500}, "text": " Next"},
      {"offsets": {"from": 2500, "to": 9000}, "text": " end"}
    ]}
    """

    @Test func compactsSilencesAndMapsWordsBack() async throws {
        let f = try FakeWhisper(body: FakeWhisper.ok, json: Self.compactedJSON)
        defer { f.remove() }
        let words = try await f.recognizer().transcribe(Self.pausedSpeech(), language: "en")
        // whisper saw 3.1 s, not 8 s.
        let wav = try Data(contentsOf: f.bin.appendingPathComponent("input.wav"))
        #expect(abs(Double(wav.count - 44) / 32_000 - 3.1) < 0.01)
        #expect(!f.args().contains("--vad"))
        #expect(words.map(\.text) == ["The", "dog.", "Next", "end"])
        guard words.count == 4 else { return }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.015 }
        #expect(near(words[0].start, 2.98) && near(words[0].end, 3.2))   // onset, not padding
        #expect(near(words[1].start, 3.2) && near(words[1].end, 4.02))   // tail cut at the pause
        #expect(near(words[2].start, 5.98) && near(words[2].end, 6.6))   // start out of the gap
        #expect(near(words[3].start, 6.6) && near(words[3].end, 7.02))   // past the end: clamped, trimmed
        #expect(words.allSatisfy { $0.end >= $0.start && $0.end <= 8 })
    }

    @Test func silentAudioNeverRunsWhisper() async throws {
        let f = try FakeWhisper(body: FakeWhisper.ok)
        defer { f.remove() }
        let x = speechLike([(2, 0)])
        let silent = PCMBuffer(format: PCMFormat(sampleRate: 16_000, channels: 1), startTime: .zero,
                               frameCount: x.count, channels: [x])
        let progress = Progress()
        #expect(try await f.recognizer().transcribe(silent, language: nil) { progress.add($0) }.isEmpty)
        #expect(f.args().isEmpty)  // the fake never ran
        #expect(progress.values == [1])
    }

    @Test func usesSileroVADWhenInstalled() async throws {
        let f = try FakeWhisper(body: FakeWhisper.ok, json: Self.compactedJSON, models: ["small", "silero-v5.1.2"])
        defer { f.remove() }
        // The VAD file is not a transcription model.
        #expect(WhisperCppRecognizer.installedModels(in: f.models).map(\.name) == ["small"])
        #expect(WhisperCppRecognizer.installedVADModels(in: f.models).map(\.name) == ["silero-v5.1.2"])
        #expect(f.recognizer().resolvedVADModel()?.name == "silero-v5.1.2")
        let only = try FakeWhisper(body: "", models: ["silero-v5.1.2"])
        defer { only.remove() }
        guard case .modelMissing = await only.recognizer().status(language: nil) else {
            Issue.record("a VAD model alone is not a transcription model"); return
        }

        _ = try await f.recognizer().transcribe(Self.pausedSpeech(), language: "en")
        let args = f.args()
        #expect(args.contains("--vad"))
        #expect(args.firstIndex(of: "-vm").map { args[$0 + 1].hasSuffix("ggml-silero-v5.1.2.bin") } == true)
        // whisper gets the whole buffer: its VAD maps times itself.
        let wav = try Data(contentsOf: f.bin.appendingPathComponent("input.wav"))
        let expectedBytes8s: Int = 44 + 8 * 32_000
        #expect(wav.count == expectedBytes8s)

        var off = f.recognizer()
        off.useVAD = false
        #expect(off.resolvedVADModel() == nil)
        _ = try await off.transcribe(Self.pausedSpeech(), language: "en")
        #expect(!f.args().contains("--vad"))

        let name = "wizrec-whisper-vad-\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: name) else { Issue.record("defaults"); return }
        defer { d.removePersistentDomain(forName: name) }
        #expect(WhisperCppRecognizer.fromDefaults(d).useVAD)
        d.set(false, forKey: WhisperSettings.vadKey)
        #expect(!WhisperCppRecognizer.fromDefaults(d).useVAD)
    }

    @Test func prefersLargeMultilingualModelForOtherLanguages() {
        func models(_ names: [String]) -> [WhisperModel] {
            names.map { WhisperModel(name: $0, url: URL(fileURLWithPath: "/m/ggml-\($0).bin"), bytes: 1) }
        }
        let all = models(["base.en", "large-v3-turbo", "small"])
        #expect(WhisperCppRecognizer.preferredModel(in: all)?.name == "small")
        #expect(WhisperCppRecognizer.preferredModel(in: all, language: "en-US")?.name == "small")
        #expect(WhisperCppRecognizer.preferredModel(in: all, language: "auto")?.name == "small")
        #expect(WhisperCppRecognizer.preferredModel(in: all, language: "bn-BD")?.name == "large-v3-turbo")
        #expect(WhisperCppRecognizer.preferredModel(in: all, language: "de")?.name == "large-v3-turbo")
        #expect(WhisperCppRecognizer.preferredModel(in: models(["small", "large-v3-turbo-q5_0"]), language: "bn")?.name
                == "large-v3-turbo-q5_0")
        #expect(WhisperCppRecognizer.preferredModel(in: models(["large-v2", "large-v3", "small"]), language: "bn")?.name
                == "large-v3")
        #expect(WhisperCppRecognizer.preferredModel(in: models(["medium", "small"]), language: "bn")?.name == "medium")
        // English-only models are skipped for other languages while a multilingual one exists.
        #expect(WhisperCppRecognizer.preferredModel(in: models(["base.en", "tiny"]), language: "bn")?.name == "tiny")
        #expect(WhisperCppRecognizer.preferredModel(in: models(["base.en"]), language: "bn")?.name == "base.en")
        #expect(WhisperCppRecognizer.preferredModel(in: [], language: "bn") == nil)
    }

    @Test func resolvesModelPerLanguageThroughFakeBinary() async throws {
        let f = try FakeWhisper(body: FakeWhisper.ok, models: ["small", "large-v3-turbo", "silero-v5.1.2"])
        defer { f.remove() }
        func modelArg() -> String? { f.args().firstIndex(of: "-m").map { f.args()[$0 + 1] } }
        #expect(f.recognizer().resolvedModel()?.name == "small")
        #expect(f.recognizer().resolvedModel(language: "bn")?.name == "large-v3-turbo")
        #expect(await f.recognizer().status(language: "bn") == .ready)
        _ = try await f.recognizer().transcribe(tone(seconds: 3), language: "bn-IN")
        #expect(modelArg()?.hasSuffix("ggml-large-v3-turbo.bin") == true)
        _ = try await f.recognizer().transcribe(tone(seconds: 3), language: "en")
        #expect(modelArg()?.hasSuffix("ggml-small.bin") == true)
        _ = try await f.recognizer().transcribe(tone(seconds: 3), language: nil)
        #expect(modelArg()?.hasSuffix("ggml-small.bin") == true)
        // The setting override wins.
        _ = try await f.recognizer(model: "small").transcribe(tone(seconds: 3), language: "bn")
        #expect(modelArg()?.hasSuffix("ggml-small.bin") == true)
        #expect(f.recognizer(model: "small").resolvedModel(language: "bn")?.name == "small")
    }

    @Test func bengaliScriptFromDevanagari() {
        #expect(WhisperCppRecognizer.bengaliScript("अमार शोनार बंग्ला,") == "অমার শোনার বংগ্লা,")
        #expect(WhisperCppRecognizer.bengaliScript("आমার") == "আমার")  // mixed first letter (large-v3-turbo)
        #expect(WhisperCppRecognizer.bengaliScript("঵িদিয় विडियो") == "বিদিয় বিডিযো")
        #expect(WhisperCppRecognizer.bengaliScript("ভালোবাসি। OK 12") == "ভালোবাসি। OK 12")
        #expect(WhisperCppRecognizer.bengaliScript("शुन्दर।") == "শুন্দর।")  // danda kept
        #expect(WhisperCppRecognizer.bengaliScript("ॐ") == "ॐ")  // no Bengali counterpart: kept
    }

    @Test func bengaliOutputIsNormalisedOnlyForBengali() async throws {
        let json = #"{"transcription":[{"offsets":{"from":0,"to":900},"text":" अमार"},"#
            + #"{"offsets":{"from":900,"to":1800},"text":" शोनार"}]}"#
        let f = try FakeWhisper(body: FakeWhisper.ok, json: json)
        defer { f.remove() }
        let bn = try await f.recognizer().transcribe(tone(seconds: 2), language: "bn")
        #expect(bn.map(\.text) == ["অমার", "শোনার"])
        let hi = try await f.recognizer().transcribe(tone(seconds: 2), language: "hi")
        #expect(hi.map(\.text) == ["अमार", "शोनार"])
        let auto = try await f.recognizer().transcribe(tone(seconds: 2), language: nil)
        #expect(auto.map(\.text) == ["अमार", "शोनार"])
    }

    /// Real whisper.cpp. Opt in with `WIZREC_WHISPER_TESTS=1`; needs `whisper-cli` and a model.
    /// `WIZREC_WHISPER_AUDIO` may point at any audio file (default: the `say` voice reading a
    /// sentence), `WIZREC_WHISPER_LANG` sets its language.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIZREC_WHISPER_TESTS"] == "1"))
    func liveWhisper() async throws {
        let r = WhisperCppRecognizer.fromDefaults()
        guard r.isAvailable else {
            print("whisper.cpp live test skipped: \(await r.status(language: nil))")
            return
        }
        let env = ProcessInfo.processInfo.environment
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-whisper-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try env["WIZREC_WHISPER_AUDIO"].map { URL(fileURLWithPath: $0) }
            ?? Self.say("The quick brown fox jumps over the lazy dog.", to: dir.appendingPathComponent("en.aiff"))
        let pool = MediaPool(diskCacheDirectory: nil)
        let media = try await pool.source(for: url)
        guard let stream = media.info.streams.first(where: { $0.kind == .audio }) else {
            Issue.record("no audio stream"); return
        }
        let words = try await Transcriber(backend: r).transcribe(media, stream: stream.index,
                                                                 language: env["WIZREC_WHISPER_LANG"])
        print("whisper.cpp:", words.map(\.text).joined(separator: " "))
        #expect(!words.isEmpty)
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start })
        if env["WIZREC_WHISPER_AUDIO"] == nil {
            let text = words.map(\.text).joined(separator: " ").lowercased()
            #expect(text.contains("quick") && text.contains("fox") && text.contains("lazy"))
        }

        // Timing across pauses (both with whisper's VAD, when its model is installed, and with
        // WizRec's energy compaction): 3 s silence, sentence A, 2 s silence, sentence B, 1 s silence.
        // Two different sentences: whisper collapses an exact repeat.
        let rate = 16_000.0
        func decode(_ u: URL) async throws -> [Float] {
            let m = try await pool.source(for: u)
            guard let st = m.info.streams.first(where: { $0.kind == .audio }) else { return [] }
            return Transcriber.mixdown(try await m.audio(stream: st.index, range: CMTimeRange(start: .zero, duration: st.duration),
                                                         format: PCMFormat(sampleRate: rate, channels: 1)))
        }
        let a = try await decode(Self.say("The quick brown fox jumps over the lazy dog.", to: dir.appendingPathComponent("a.aiff")))
        let b = try await decode(Self.say("It is twelve o'clock and the sun is shining.", to: dir.appendingPathComponent("b.aiff")))
        func onset(_ x: [Float]) -> Double {
            guard let r = SpeechActivity(x, sampleRate: rate).regions().first, r.lowerBound > 0 else { return 0 }
            return r.lowerBound + SpeechActivity.padSeconds
        }
        func silence(_ s: Double) -> [Float] { Array(repeating: 0, count: Int(s * rate)) }
        let x = silence(3) + a + silence(2) + b + silence(1)
        let paused = PCMBuffer(format: PCMFormat(sampleRate: rate, channels: 1), startTime: .zero,
                               frameCount: x.count, channels: [x])
        let lenA = Double(a.count) / rate
        let truth = [3 + onset(a), 3 + lenA + 2 + onset(b)]
        for vad in [true, false] where !vad || r.resolvedVADModel() != nil {
            var rv = r
            rv.useVAD = vad
            let w = try await rv.transcribe(paused, language: "en")
            let firsts = [w.first, w.first { $0.start > 3 + lenA + 1 }].compactMap { $0?.start }
            print("whisper.cpp vad=\(vad) sentence starts:", firsts, "expected:", truth)
            print(w.map { "\($0.text)@\(($0.start * 100).rounded() / 100)-\(($0.end * 100).rounded() / 100)" }
                .joined(separator: " "))
            #expect(firsts.count == 2)
            for (a, b) in zip(firsts, truth) { #expect(abs(a - b) < 0.3, "vad=\(vad): \(a) vs \(b)") }
            // The last word of sentence A ends in the pause, not at sentence B.
            if let lastA = w.last(where: { $0.start < 3 + lenA + 1 }) {
                #expect(lastA.end < 3 + lenA + 0.3, "vad=\(vad): sentence A ends at \(lastA.end)")
            }
            #expect(w.allSatisfy { $0.end <= Double(x.count) / rate })
        }

        // Bengali, when a Bengali `say` voice exists (an Indian-Bengali voice, "Piya", on macOS 27).
        if env["WIZREC_WHISPER_AUDIO"] == nil, let voice = Self.voice(locale: "bn_") {
            let bn = try Self.say("আমার সোনার বাংলা, আমি তোমায় ভালোবাসি।", voice: voice,
                                  to: dir.appendingPathComponent("bn.aiff"))
            let m = try await pool.source(for: bn)
            guard let st = m.info.streams.first(where: { $0.kind == .audio }) else { Issue.record("bn audio"); return }
            let started = Date()
            let w = try await Transcriber(backend: r).transcribe(m, stream: st.index, language: "bn")
            let text = w.map(\.text).joined(separator: " ")
            print("whisper.cpp bn (\(r.resolvedModel(language: "bn")?.name ?? "?"), "
                  + "\(Date().timeIntervalSince(started)) s):", text)
            #expect(w.count >= 3)
            // Bengali script, not Devanagari (`bengaliScript`, and a large model when installed).
            let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }
            let bengali = letters.filter { (0x0980...0x09FF).contains($0.value) }.count
            #expect(Double(bengali) >= 0.9 * Double(letters.count), "\(bengali) of \(letters.count) letters are Bengali")
        }
    }

    /// Writes `text` spoken by `say` to `url`.
    private static func say(_ text: String, voice: String? = nil, to url: URL) throws -> URL {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = (voice.map { ["-v", $0] } ?? []) + ["-o", url.path, text]
        try p.run(); p.waitUntilExit()
        return url
    }

    /// The first `say` voice whose locale starts with `locale` (e.g. `"bn_"`).
    private static func voice(locale: String) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", "?"]
        p.standardOutput = out
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            if let i = cols.firstIndex(where: { $0.hasPrefix(locale) }), i > 0 {
                return cols[..<i].joined(separator: " ")
            }
        }
        return nil
    }
}
