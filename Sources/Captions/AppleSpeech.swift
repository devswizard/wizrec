import AVFoundation
import Foundation
import MediaEngine
import Speech

/// Apple's Speech framework (`SFSpeechRecognizer`), on-device by default. Needs the Speech
/// Recognition permission: the app's Info.plist must carry `NSSpeechRecognitionUsageDescription`,
/// and a process without it is killed by the system on `requestAccess()`. Nothing here runs in the
/// default test suite (see `WIZREC_SPEECH_TESTS`).
///
/// Language: BCP-47 (`"en-US"`, `"bn-IN"`); a bare language code (`"en"`, as in
/// `captionAttributes.lang`) picks that language's first supported region; nil = the user's locale.
/// Word times are seconds from the start of the buffer; `confidence` is 0–1 (0 when Speech gives none).
public struct AppleSpeechRecognizer: TranscriptionBackend {
    public let id = "apple-speech"
    public var displayName: String { requiresOnDevice ? "Apple Speech (on device)" : "Apple Speech" }
    public var preferredFormat: PCMFormat { PCMFormat(sampleRate: 16_000, channels: 1) }
    /// Speech handles long buffers on device, but results arrive only at the end; one-minute chunks
    /// keep memory flat and progress moving.
    public var maxChunkSeconds: Double? { 60 }
    /// Never send audio off the machine (the default). When false, Speech may use Apple's servers.
    public var requiresOnDevice: Bool

    public init(requiresOnDevice: Bool = true) { self.requiresOnDevice = requiresOnDevice }

    public func status(language: String?) async -> BackendStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: return .needsPermission
        case .denied, .restricted: return .permissionDenied
        case .authorized: return recognizerStatus(language)
        @unknown default: return .unavailable("unknown authorization status")
        }
    }

    public func requestAccess() async -> BackendStatus {
        _ = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        return await status(language: nil)
    }

    private func recognizerStatus(_ language: String?) -> BackendStatus {
        guard let locale = Self.locale(for: language), let r = SFSpeechRecognizer(locale: locale) else {
            return .languageUnsupported(language ?? Locale.current.identifier)
        }
        if requiresOnDevice && !r.supportsOnDeviceRecognition {
            return .modelMissing("on-device speech for \(locale.identifier) (System Settings ▸ Keyboard ▸ Dictation)")
        }
        return r.isAvailable ? .ready : .unavailable("speech recognition is not available right now")
    }

    /// The Speech locale for a BCP-47 tag or bare language code; nil when Speech has none.
    public static func locale(for language: String?, supported: Set<Locale> = SFSpeechRecognizer.supportedLocales())
        -> Locale? {
        let ids = supported.map { $0.identifier.replacingOccurrences(of: "_", with: "-") }.sorted()
        let want = (language ?? Locale.current.identifier).replacingOccurrences(of: "_", with: "-")
        if let exact = ids.first(where: { $0.caseInsensitiveCompare(want) == .orderedSame }) { return Locale(identifier: exact) }
        let lang = want.split(separator: "-").first.map(String.init)?.lowercased() ?? want.lowercased()
        // Prefer the user's region for that language, then the first one alphabetically.
        let region = Locale.current.region?.identifier ?? ""
        let same = ids.filter { $0.split(separator: "-").first.map { $0.lowercased() } == lang }
        return (same.first { $0.hasSuffix("-" + region) } ?? same.first).map { Locale(identifier: $0) }
    }

    public func transcribe(_ audio: PCMBuffer, language: String?) async throws -> [TranscriptWord] {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw CaptionsError.permissionDenied }
        switch recognizerStatus(language) {
        case .ready: break
        case .modelMissing(let m): throw CaptionsError.modelUnavailable(m)
        case .languageUnsupported(let l): throw CaptionsError.modelUnavailable("no speech recogniser for \(l)")
        case .unavailable(let m): throw CaptionsError.modelUnavailable(m)
        case .needsPermission, .permissionDenied: throw CaptionsError.permissionDenied
        }
        guard let locale = Self.locale(for: language), let recognizer = SFSpeechRecognizer(locale: locale),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: audio.format.sampleRate,
                                         channels: 1, interleaved: false) else {
            throw CaptionsError.modelUnavailable("no speech recogniser")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = requiresOnDevice
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        let samples = Transcriber.mixdown(audio)
        let slice = 16_384
        var at = 0
        while at < samples.count {
            let n = min(slice, samples.count - at)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
                  let dst = buf.floatChannelData?[0] else { throw CaptionsError.modelUnavailable("audio buffer") }
            samples.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                dst.update(from: base + at, count: n)
            }
            buf.frameLength = AVAudioFrameCount(n)
            request.append(buf)
            at += n
        }
        request.endAudio()

        let state = RecognitionState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<[TranscriptWord], any Error>) in
                state.start(c)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        state.finish(.success(result.bestTranscription.segments.map { s in
                            TranscriptWord(text: s.substring, start: s.timestamp, end: s.timestamp + s.duration,
                                           confidence: Double(s.confidence))
                        }))
                    } else if let error {
                        // "No speech detected" ends silent chunks with an error; that is an empty result.
                        let ns = error as NSError
                        if ns.domain == "kAFAssistantErrorDomain", ns.code == 1110 { state.finish(.success([])) }
                        else { state.finish(.failure(error)) }
                    }
                }
                state.attach(task)
            }
        } onCancel: {
            state.cancel()
        }
    }
}

/// Resumes the continuation exactly once and cancels the Speech task on Swift task cancellation.
// @unchecked Sendable: every stored property is read and written only under `lock`; Speech calls the
// result handler on its own queue and cancellation arrives on another thread.
private final class RecognitionState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[TranscriptWord], any Error>?
    private var task: SFSpeechRecognitionTask?
    private var cancelled = false

    func start(_ c: CheckedContinuation<[TranscriptWord], any Error>) {
        lock.lock(); continuation = c; let dead = cancelled; lock.unlock()
        if dead { finish(.failure(CancellationError())) }
    }

    func attach(_ t: SFSpeechRecognitionTask) {
        lock.lock(); task = t; let dead = cancelled; lock.unlock()
        if dead { t.cancel() }
    }

    func finish(_ r: Result<[TranscriptWord], any Error>) {
        lock.lock(); let c = continuation; continuation = nil; task = nil; lock.unlock()
        c?.resume(with: r)
    }

    func cancel() {
        lock.lock(); cancelled = true; let t = task; lock.unlock()
        t?.cancel()
        finish(.failure(CancellationError()))
    }
}
