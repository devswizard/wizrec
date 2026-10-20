import Foundation
import MediaEngine

/// A ggml whisper model file found on disk, e.g. `ggml-small.bin` → name `"small"`.
public struct WhisperModel: Sendable, Equatable, Hashable {
    /// File name without the `ggml-` prefix and `.bin` extension (`"small"`, `"large-v3-turbo"`, `"base.en"`).
    public var name: String
    public var url: URL
    /// File size, bytes.
    public var bytes: Int64
    /// English-only models (`*.en`) cannot transcribe other languages.
    public var isEnglishOnly: Bool { name.hasSuffix(".en") }
    public init(name: String, url: URL, bytes: Int64) { self.name = name; self.url = url; self.bytes = bytes }
}

/// Preference keys the app stores whisper.cpp settings under (`UserDefaults.standard`).
public enum WhisperSettings {
    /// String: path to a `whisper-cli` executable; empty or missing = search PATH and Homebrew.
    public static let binaryPathKey = "captions.whisper.binaryPath"
    /// String: model name (`WhisperModel.name`); empty or missing = the preferred installed model.
    public static let modelKey = "captions.whisper.model"
    /// String: id of the transcription backend to use (`"apple-speech"`, `"whisper.cpp"`).
    public static let backendKey = "captions.backend"
    /// Bool: use whisper's Silero voice-activity detection when a `ggml-silero-*.bin` model is
    /// installed; missing = true.
    public static let vadKey = "captions.whisper.vad"
}

/// A backend that reports progress inside one `transcribe` call; `Transcriber` uses it when present.
public protocol ProgressReportingBackend: TranscriptionBackend {
    /// Like `transcribe(_:language:)`; `progress` receives 0…1 while the call runs.
    func transcribe(_ audio: PCMBuffer, language: String?,
                    progress: (@Sendable (Double) -> Void)?) async throws -> [TranscriptWord]
}

/// whisper.cpp (MIT) run as a subprocess: the `whisper-cli` executable, found at run time, with a
/// ggml model from `~/Library/Application Support/WizRec/models/`. Nothing is linked into WizRec.
///
/// - Audio: 16 kHz mono, written as a 16-bit WAV to a temporary directory, at most
///   `maxChunkSeconds` per process run (the model loads once per run).
/// - Output: `--output-json-full` with `--max-len 1 --split-on-word`, so each segment is one word;
///   times are seconds from the start of the buffer, `confidence` the mean token probability (0–1).
/// - Timing [WizRec]: whisper alone puts words inside long pauses (measured with 1.9.5 and
///   `ggml-small`: sentence starts up to 3 s early). With a Silero model installed and `useVAD`,
///   whisper's `--vad` skips silences; otherwise the audio is compacted around energy-detected
///   speech (`SpeechActivity`, `Compaction`) and times mapped back. Either way each word is then
///   trimmed to its voiced frames and clamped to the buffer. Audio without any voiced frame
///   returns no words and never runs whisper (it hallucinates text on silence).
/// - Language: BCP-47 or bare code; only the language subtag goes to whisper (`"bn-IN"` → `bn`);
///   nil = auto-detect (`-l auto`).
/// - Cancellation terminates the process.
public struct WhisperCppRecognizer: ProgressReportingBackend {
    public let id = "whisper.cpp"
    public var displayName: String {
        resolvedModel().map { "whisper.cpp (\($0.name))" } ?? "whisper.cpp"
    }
    public var preferredFormat: PCMFormat { PCMFormat(sampleRate: 16_000, channels: 1) }
    /// Five minutes per process run: model load is amortised, progress still moves.
    public var maxChunkSeconds: Double? { 300 }

    /// Explicit executable; nil = search `searchDirectories` for `whisper-cli` (then `whisper-cpp`).
    public var binary: URL?
    /// Model name (`WhisperModel.name`); nil = `preferredModel(in:)`.
    public var model: String?
    public var modelsDirectory: URL
    /// Directories searched for the executable, in order.
    public var searchDirectories: [URL]
    /// Threads passed to `-t`; nil = whisper's default (4, the fastest measured on an M3 Pro).
    public var threads: Int?
    /// Pass `--vad` with the installed Silero model (`installedVADModels`) when there is one.
    public var useVAD: Bool

    public init(binary: URL? = nil, model: String? = nil,
                modelsDirectory: URL = WhisperCppRecognizer.defaultModelsDirectory,
                searchDirectories: [URL] = WhisperCppRecognizer.defaultSearchDirectories(), threads: Int? = nil,
                useVAD: Bool = true) {
        self.binary = binary; self.model = model; self.modelsDirectory = modelsDirectory
        self.searchDirectories = searchDirectories; self.threads = threads; self.useVAD = useVAD
    }

    /// A recognizer configured from the app's preferences (`WhisperSettings` keys).
    public static func fromDefaults(_ defaults: UserDefaults = .standard) -> WhisperCppRecognizer {
        let path = defaults.string(forKey: WhisperSettings.binaryPathKey).flatMap { $0.isEmpty ? nil : $0 }
        let model = defaults.string(forKey: WhisperSettings.modelKey).flatMap { $0.isEmpty ? nil : $0 }
        let vad = defaults.object(forKey: WhisperSettings.vadKey) == nil || defaults.bool(forKey: WhisperSettings.vadKey)
        return WhisperCppRecognizer(binary: path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
                                    model: model, useVAD: vad)
    }

    // MARK: Discovery

    /// `~/Library/Application Support/WizRec/models/`.
    public static var defaultModelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("WizRec/models", isDirectory: true)
    }

    /// `$PATH` entries, then `/opt/homebrew/bin` and `/usr/local/bin` (an app launched from Finder
    /// has a minimal PATH).
    public static func defaultSearchDirectories(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> [URL] {
        var dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        for d in ["/opt/homebrew/bin", "/usr/local/bin"] where !dirs.contains(d) { dirs.append(d) }
        return dirs.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Executable names tried in each directory: the current one, then the old Homebrew name.
    public static let binaryNames = ["whisper-cli", "whisper-cpp"]

    /// The executable to run: `explicit` when it is executable, else the first match in `directories`.
    public static func locateBinary(explicit: URL?, in directories: [URL]) -> URL? {
        if let explicit { return isExecutable(explicit) ? explicit : nil }
        for name in binaryNames {
            for d in directories {
                let u = d.appendingPathComponent(name)
                if isExecutable(u) { return u }
            }
        }
        return nil
    }

    /// An executable file (directories have the x bit too, so they are excluded).
    private static func isExecutable(_ u: URL) -> Bool {
        var dir: ObjCBool = false
        let fm = FileManager.default
        return fm.fileExists(atPath: u.path, isDirectory: &dir) && !dir.boolValue && fm.isExecutableFile(atPath: u.path)
    }

    /// Transcription models: `ggml-*.bin` files in `directory`, sorted by name. Voice-activity
    /// models (`ggml-silero-*.bin`, see `installedVADModels`) are not transcription models and are
    /// left out, so a settings picker never offers them.
    public static func installedModels(in directory: URL = defaultModelsDirectory) -> [WhisperModel] {
        ggmlFiles(in: directory).filter { !isVADModelName($0.name) }
    }

    /// Silero voice-activity models (`ggml-silero-*.bin`) in `directory`, sorted by name.
    public static func installedVADModels(in directory: URL = defaultModelsDirectory) -> [WhisperModel] {
        ggmlFiles(in: directory).filter { isVADModelName($0.name) }
    }

    /// The VAD model used for `--vad`: the last (newest-versioned by name) silero model, if any.
    public static func preferredVADModel(in models: [WhisperModel]) -> WhisperModel? { models.last }

    static func isVADModelName(_ name: String) -> Bool { name.lowercased().hasPrefix("silero") }

    /// Non-empty `ggml-*.bin` files in `directory`, sorted by name.
    private static func ggmlFiles(in directory: URL) -> [WhisperModel] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return []
        }
        return files.compactMap { u -> WhisperModel? in
            let f = u.lastPathComponent
            guard f.hasPrefix("ggml-"), f.hasSuffix(".bin"), f.count > 9 else { return nil }
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
            guard size > 0 else { return nil }
            return WhisperModel(name: String(f.dropFirst(5).dropLast(4)), url: u, bytes: Int64(size))
        }.sorted { $0.name < $1.name }
    }

    /// Multilingual models first, in an accuracy/speed order that suits laptops.
    static let preference = ["small", "large-v3-turbo", "medium", "large-v3", "large-v2", "large", "base", "tiny"]

    /// Large multilingual models first, for languages other than English. Measured 2026-10-20 on
    /// Bengali (macOS `say` voice Piya, `-l bn`): `small` writes Devanagari script (0 % Bengali
    /// letters; 33–54 % character error after `bengaliScript`), `large-v3-turbo` writes Bengali
    /// script (98–99 %; 17–37 % character error) in 2.8 s for 5–7 s of audio.
    static let nonEnglishPreference = ["large-v3-turbo", "large-v3", "large-v2", "large", "medium"] + preference

    /// The model used when none is chosen. English, auto-detect (`nil`/`auto`) and unknown
    /// languages: the first of `small`, `large-v3-turbo`, `medium`, `large-v3`, … that is
    /// installed. Any other language: multilingual models only, the first of `large-v3-turbo`,
    /// `large-v3`, `large-v2`, `large`, `medium`, then the same order. Quantised variants such as
    /// `small-q5_1` count. Else the first installed model.
    public static func preferredModel(in models: [WhisperModel], language: String? = nil) -> WhisperModel? {
        let lang = whisperLanguage(language)
        let english = lang == "en" || lang == "auto"
        let order = english ? preference : nonEnglishPreference
        let pool = english ? models : models.filter { !$0.isEnglishOnly }
        for p in order {
            if let m = pool.first(where: { $0.name == p }) ?? pool.first(where: { $0.name.hasPrefix(p + "-q") }) {
                return m
            }
        }
        return pool.first ?? models.first
    }

    /// The executable that would run, nil when none is found.
    public func resolvedBinary() -> URL? { Self.locateBinary(explicit: binary, in: searchDirectories) }

    /// The model that would load for `language` (BCP-47 or bare code; nil = auto-detect), nil
    /// when it (or any model) is missing. A chosen `model` always wins.
    public func resolvedModel(language: String? = nil) -> WhisperModel? {
        let all = Self.installedModels(in: modelsDirectory)
        if let model { return all.first { $0.name == model } }
        return Self.preferredModel(in: all, language: language)
    }

    /// The Silero model `--vad` would use, nil when `useVAD` is off or none is installed.
    public func resolvedVADModel() -> WhisperModel? {
        useVAD ? Self.preferredVADModel(in: Self.installedVADModels(in: modelsDirectory)) : nil
    }

    /// True when both the executable and a model are present. Never prompts.
    public var isAvailable: Bool { resolvedBinary() != nil && resolvedModel() != nil }

    /// whisper's language argument: the lowercased language subtag, `auto` for nil/empty/`auto`.
    public static func whisperLanguage(_ language: String?) -> String {
        guard let l = language?.trimmingCharacters(in: .whitespaces), !l.isEmpty else { return "auto" }
        return l.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? "auto"
    }

    // MARK: TranscriptionBackend

    public func status(language: String?) async -> BackendStatus { statusNow(language: language) }

    func statusNow(language: String?) -> BackendStatus {
        guard resolvedBinary() != nil else {
            if let binary { return .unavailable("\(binary.path) is not an executable") }
            return .unavailable("whisper-cli not found (install whisper.cpp, e.g. `brew install whisper-cpp`)")
        }
        guard let m = resolvedModel(language: language) else {
            if let model { return .modelMissing("ggml-\(model).bin in \(modelsDirectory.path)") }
            return .modelMissing("a ggml model (e.g. ggml-small.bin) in \(modelsDirectory.path)")
        }
        let lang = Self.whisperLanguage(language)
        if m.isEnglishOnly, lang != "en", lang != "auto" { return .languageUnsupported(language ?? lang) }
        return .ready
    }

    /// No permission is involved; returns the current status.
    public func requestAccess() async -> BackendStatus { statusNow(language: nil) }

    public func transcribe(_ audio: PCMBuffer, language: String?) async throws -> [TranscriptWord] {
        try await transcribe(audio, language: language, progress: nil)
    }

    public func transcribe(_ audio: PCMBuffer, language: String?,
                           progress: (@Sendable (Double) -> Void)?) async throws -> [TranscriptWord] {
        switch statusNow(language: language) {
        case .ready: break
        case .modelMissing(let m): throw CaptionsError.modelUnavailable(m)
        case .languageUnsupported(let l): throw CaptionsError.modelUnavailable("the English-only model cannot transcribe \(l)")
        case .unavailable(let m): throw CaptionsError.modelUnavailable(m)
        case .needsPermission, .permissionDenied: throw CaptionsError.permissionDenied
        }
        guard let exe = resolvedBinary(), let model = resolvedModel(language: language) else {
            throw CaptionsError.modelUnavailable("whisper.cpp")
        }
        try Task.checkCancellation()
        let samples = Transcriber.mixdown(audio)
        guard !samples.isEmpty else { return [] }
        let rate = audio.format.sampleRate
        let mono = rate == 16_000 ? samples : Transcriber.resample(samples, from: rate, to: 16_000)
        let activity = SpeechActivity(mono, sampleRate: 16_000)
        guard activity.hasSpeech else { progress?(1); return [] }
        let vad = resolvedVADModel()
        let compaction = vad == nil ? Compaction(mono, sampleRate: 16_000, regions: activity.regions()) : nil

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("wizrec-whisper-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("audio.wav")
        try Self.wav16(compaction?.samples ?? mono, sampleRate: 16_000).write(to: wav)
        let prefix = dir.appendingPathComponent("out")

        var args = ["-m", model.url.path, "-f", wav.path, "-l", Self.whisperLanguage(language),
                    "-oj", "-ojf", "-of", prefix.path, "-ml", "1", "-sow", "-pp"]
        if let threads, threads > 0 { args += ["-t", String(threads)] }
        if let vad { args += ["--vad", "-vm", vad.url.path] }
        let result = try await WhisperProcess.run(exe, arguments: args, progress: progress)
        try Task.checkCancellation()
        let json = prefix.appendingPathExtension("json")
        guard result.status == 0, let data = try? Data(contentsOf: json) else {
            let tail = result.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CaptionsError.modelUnavailable("whisper-cli failed (exit \(result.status))"
                                                 + (tail.isEmpty ? "" : ": \(tail)"))
        }
        progress?(1)
        var words = try Self.parseJSON(data)
        if Self.whisperLanguage(language) == "bn" {
            words = words.map { var w = $0; w.text = Self.bengaliScript(w.text); return w }
        }
        if let compaction { words = compaction.original(words) }
        return words.map(activity.trim)
    }

    // MARK: Audio and output

    /// A canonical 44-byte-header PCM WAV, 16-bit little-endian mono.
    static func wav16(_ x: [Float], sampleRate: Int) -> Data {
        var d = Data(capacity: 44 + x.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(x.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in x {
            let v = Int16((max(-1, min(1, s.isFinite ? s : 0)) * 32_767).rounded())
            u16(UInt16(bitPattern: v))
        }
        return d
    }

    /// Words of whisper-cli's JSON (`-oj`, optionally `-ojf`). Each segment's text is split on
    /// whitespace; a segment of several words shares its time span by character count. Segments
    /// that are only a bracketed annotation (`[BLANK_AUDIO]`, `(music)`) are dropped. Confidence =
    /// mean `p` of the segment's non-special tokens (1 without `-ojf`). Invalid UTF-8 (partial
    /// multi-byte tokens) is replaced, not fatal.
    public static func parseJSON(_ data: Data) throws -> [TranscriptWord] {
        let clean = Data(String(decoding: data, as: UTF8.self).utf8)
        guard let root = (try? JSONSerialization.jsonObject(with: clean)) as? [String: Any] else {
            throw CaptionsError.parse("whisper-cli output is not a JSON object")
        }
        guard let segments = root["transcription"] as? [[String: Any]] else {
            throw CaptionsError.parse("whisper-cli output has no transcription array")
        }
        var out: [TranscriptWord] = []
        for seg in segments {
            guard let text = seg["text"] as? String,
                  let offsets = seg["offsets"] as? [String: Any],
                  let from = number(offsets["from"]), let to = number(offsets["to"]) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !isAnnotation(trimmed), !trimmed.contains("\u{FFFD}") else { continue }
            let start = from / 1000, end = max(to, from) / 1000
            var confidence = 1.0
            if let tokens = seg["tokens"] as? [[String: Any]] {
                let ps = tokens.filter { !(($0["text"] as? String) ?? "").hasPrefix("[_") }.compactMap { number($0["p"]) }
                if !ps.isEmpty { confidence = min(1, max(0, ps.reduce(0, +) / Double(ps.count))) }
            }
            let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            let total = Double(words.reduce(0) { $0 + $1.count })
            var t = start, used = 0.0
            for w in words {
                used += Double(w.count)
                let e = total > 0 ? start + (end - start) * used / total : end
                out.append(TranscriptWord(text: w, start: t, end: e, confidence: confidence))
                t = e
            }
        }
        return out
    }

    /// `text` with Devanagari letters moved to the Bengali block [WizRec]. whisper models often
    /// write Bengali speech in Devanagari (all of `small`'s output, a word's first letter with
    /// `large-v3-turbo`); the two blocks share a layout, so U+09xx = U+08xx + 0x80 wherever that
    /// Bengali code point exists. व (U+0935), and the unassigned U+09B5 whisper sometimes emits,
    /// become ব (U+09AC). Danda and other unmapped characters are kept. Only for `-l bn`
    /// (Assamese differs in র/ৰ, ৱ).
    public static func bengaliScript(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            switch u.value {
            case 0x0935, 0x09B5:
                out.append("\u{09AC}")
            case 0x0900...0x097F:
                if let b = Unicode.Scalar(u.value + 0x80), b.properties.generalCategory != .unassigned {
                    out.append(b)
                } else {
                    out.append(u)
                }
            default:
                out.append(u)
            }
        }
        return String(out)
    }

    static func isAnnotation(_ s: String) -> Bool {
        (s.hasPrefix("[") && s.hasSuffix("]")) || (s.hasPrefix("(") && s.hasSuffix(")"))
            || (s.hasPrefix("*") && s.hasSuffix("*") && s.count > 1)
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// Progress percentage from a whisper-cli stderr line
    /// (`whisper_print_progress_callback: progress =  42%`), 0…1.
    static func progress(fromLine line: Substring) -> Double? {
        guard let r = line.range(of: "progress =") else { return nil }
        let digits = line[r.upperBound...].drop { $0 == " " }.prefix { $0.isNumber }
        return Double(digits).map { min(1, max(0, $0 / 100)) }
    }
}

/// Runs one whisper-cli process, draining stdout/stderr, terminating it on task cancellation.
enum WhisperProcess {
    struct Result { var status: Int32; var stderrTail: String }

    static func run(_ exe: URL, arguments: [String], progress: (@Sendable (Double) -> Void)?) async throws -> Result {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Result, any Error>) in
                box.start(exe, arguments: arguments, progress: progress, continuation: c)
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// Owns the process and resumes the continuation exactly once.
// @unchecked Sendable: every stored property is read and written only under `lock`; pipe handlers,
// the termination handler and cancellation each arrive on their own threads.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var continuation: CheckedContinuation<WhisperProcess.Result, any Error>?
    private var cancelled = false
    private var stderrBuffer = Data()
    private var stderrTail = ""
    private var lastProgress = -1.0

    func start(_ exe: URL, arguments: [String], progress: (@Sendable (Double) -> Void)?,
               continuation c: CheckedContinuation<WhisperProcess.Result, any Error>) {
        lock.lock()
        if cancelled { lock.unlock(); c.resume(throwing: CancellationError()); return }
        continuation = c
        lock.unlock()

        let p = Process()
        p.executableURL = exe
        p.arguments = arguments
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        out.fileHandleForReading.readabilityHandler = { h in
            if h.availableData.isEmpty { h.readabilityHandler = nil }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.stderr(d, progress)
        }
        p.terminationHandler = { [weak self] p in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            if let rest = try? err.fileHandleForReading.readToEnd(), !rest.isEmpty { self?.stderr(rest, progress) }
            self?.finished(p.terminationStatus)
        }
        do {
            lock.lock()
            if cancelled { lock.unlock(); return }  // `cancel()` already resumed the continuation
            process = p
            try p.run()
            lock.unlock()
        } catch {
            lock.unlock()
            finish(.failure(CaptionsError.modelUnavailable("cannot run \(exe.path): \(error.localizedDescription)")))
        }
    }

    private func stderr(_ d: Data, _ progress: (@Sendable (Double) -> Void)?) {
        lock.lock()
        stderrBuffer.append(d)
        var updates: [Double] = []
        while let nl = stderrBuffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = String(decoding: stderrBuffer[stderrBuffer.startIndex..<nl], as: UTF8.self)
            stderrBuffer.removeSubrange(stderrBuffer.startIndex...nl)
            guard !line.isEmpty else { continue }
            if let v = WhisperCppRecognizer.progress(fromLine: line[...]) {
                if v > lastProgress { lastProgress = v; updates.append(v) }
            } else {
                stderrTail = String((stderrTail + "\n" + line).suffix(600))
            }
        }
        lock.unlock()
        for u in updates { progress?(min(u, 0.99)) }
    }

    private func finished(_ status: Int32) {
        lock.lock(); let dead = cancelled; let tail = stderrTail; lock.unlock()
        finish(dead ? .failure(CancellationError()) : .success(.init(status: status, stderrTail: tail)))
    }

    private func finish(_ r: Result<WhisperProcess.Result, any Error>) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(with: r)
    }

    func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        if let p, p.isRunning { p.terminate() }
        finish(.failure(CancellationError()))
    }
}
