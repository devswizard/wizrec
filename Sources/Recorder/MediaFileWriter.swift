import AVFoundation
import CoreMedia
import Foundation

/// Writes one single-track media file in real time: a video MP4 (H.264/HEVC) or an AAC M4A.
///
/// The track is configured lazily from the first sample's format description, the session
/// starts at recording time 0, and every sample is appended at the recording time the caller
/// gives (already stitched by `RecordingClock`). Real-time: when the encoder is not ready the
/// sample is dropped and counted, never queued.
// @unchecked Sendable: all mutable state (writer, input, counters) is guarded by `lock`.
final class MediaFileWriter: @unchecked Sendable {
    enum Kind: Sendable, Equatable {
        /// Variable-frame-rate video; `frameRate` only tunes the encoder (bitrate, key frames).
        case video(codec: VideoCodec, frameRate: Int)
        case audio
    }

    enum WriterError: Error, Equatable, CustomStringConvertible {
        case unsupportedFormat(String)
        case failed(String)
        /// `finishWriting` did not call back within `seconds` s; the file was abandoned and removed.
        case encoderStalled(seconds: Int)

        var description: String {
            switch self {
            case .unsupportedFormat(let m): "unsupported format: \(m)"
            case .failed(let m): m
            case .encoderStalled(let s):
                "the encoder stopped responding for \(s) s; the file was not finished and was removed"
            }
        }
    }

    let url: URL
    let kind: Kind
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var error: Error?
    private var finished = false
    private var _appended = 0
    private var _dropped = 0
    private var _lastTime: CMTime?

    /// When false (tests, offline feeds) `append` waits for the encoder instead of dropping.
    let realTime: Bool
    /// `finishWriting` must call back within this many seconds, else `finish` throws
    /// `WriterError.encoderStalled`.
    let finishTimeout: TimeInterval
    /// Test seam: wraps the AVAssetWriter that `finish` talks to (e.g. one that never finishes).
    private let wrapWriter: (@Sendable (AVAssetWriter) -> any MediaWriterControl)?

    /// Default `finishTimeout`, seconds.
    static let defaultFinishTimeout: TimeInterval = 60
    /// How long a failed writer's `cancelWriting` is awaited before it is left running, seconds.
    static let cancelTimeout: TimeInterval = 10

    init(url: URL, kind: Kind, realTime: Bool = true, finishTimeout: TimeInterval = MediaFileWriter.defaultFinishTimeout,
         wrapWriter: (@Sendable (AVAssetWriter) -> any MediaWriterControl)? = nil) {
        self.url = url
        self.kind = kind
        self.realTime = realTime
        self.finishTimeout = finishTimeout
        self.wrapWriter = wrapWriter
    }

    /// Samples written so far.
    var appendedCount: Int { lock.withLock { _appended } }
    /// Samples dropped because the encoder was busy or the time was not increasing.
    var droppedCount: Int { lock.withLock { _dropped } }

    /// Appends `sample` at recording time `time` (its PTS is rewritten; durations are kept).
    func append(_ sample: CMSampleBuffer, at time: CMTime) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, error == nil, CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample) else { return }
        if let last = _lastTime, time < last || (time == last && kind != .audio) { _dropped += 1; return }
        if writer == nil {
            do { try setUp(from: sample) } catch { self.error = error; return }
        }
        guard let writer, let input else { return }
        guard writer.status == .writing else {
            if writer.status == .failed { error = writer.error ?? WriterError.failed("writer failed") }
            return
        }
        if !realTime {
            var waited = 0
            while !input.isReadyForMoreMediaData, writer.status == .writing, waited < 2_000 { usleep(1_000); waited += 1 }
        }
        guard input.isReadyForMoreMediaData else { _dropped += 1; return }
        guard let timed = retime(sample, to: time) else { _dropped += 1; return }
        if input.append(timed) {
            _appended += 1
            _lastTime = time
        } else {
            error = writer.error ?? WriterError.failed("append failed")
        }
    }

    /// Ends the track at recording time `end` and closes the file. Returns false (and leaves no
    /// file) when nothing was ever appended. Waits at most `finishTimeout` seconds for the
    /// encoder: a stuck one throws `WriterError.encoderStalled` and the file is removed.
    func finish(at end: CMTime) async throws -> Bool {
        let state: (AVAssetWriter, AVAssetWriterInput)? = lock.withLock {
            finished = true
            guard let writer, let input else { return nil }
            return (writer, input)
        }
        let control: (any MediaWriterControl)? = state.map { wrapWriter?($0.0) ?? $0.0 }
        if let error = lock.withLock({ self.error }) {
            if let control { await MediaWriterWait.cancel(control, timeout: Self.cancelTimeout) }
            throw WriterError.failed(String(describing: error))
        }
        guard let (writer, input) = state, let control, control.status == .writing else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        input.markAsFinished()
        let last = lock.withLock { _lastTime } ?? .zero
        writer.endSession(atSourceTime: CMTimeMaximum(end, last))
        guard await MediaWriterWait.finish(control, timeout: finishTimeout) else {
            MediaWriterWait.abandon(control)
            try? FileManager.default.removeItem(at: url)
            throw WriterError.encoderStalled(seconds: Int(finishTimeout.rounded(.up)))
        }
        if control.status != .completed {
            throw WriterError.failed(control.error.map { String(describing: $0) } ?? "status \(control.status.rawValue)")
        }
        return true
    }

    // MARK: - Setup

    private func setUp(from sample: CMSampleBuffer) throws {
        guard let format = CMSampleBufferGetFormatDescription(sample) else {
            throw WriterError.unsupportedFormat("no format description")
        }
        try? FileManager.default.removeItem(at: url)
        let input: AVAssetWriterInput
        let fileType: AVFileType
        switch kind {
        case let .video(codec, frameRate):
            let dims = CMVideoFormatDescriptionGetDimensions(format)
            guard dims.width > 0, dims.height > 0 else { throw WriterError.unsupportedFormat("video size 0") }
            input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: Self.videoSettings(codec: codec, width: Int(dims.width), height: Int(dims.height), frameRate: frameRate)
            )
            fileType = .mp4
        case .audio:
            guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
                throw WriterError.unsupportedFormat("not audio")
            }
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings(source: asbd), sourceFormatHint: format)
            fileType = .m4a
        }
        input.expectsMediaDataInRealTime = realTime
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = true
        guard writer.canAdd(input) else { throw WriterError.unsupportedFormat("cannot add input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw WriterError.failed(writer.error.map { String(describing: $0) } ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
    }

    /// Encoder settings for screen/camera video. Bitrate scales with pixels × fps
    /// (≈ 9.3 Mbit/s for 1080p30 H.264; HEVC 60 % of that). BT.709 colour tags.
    static func videoSettings(codec: VideoCodec, width: Int, height: Int, frameRate: Int) -> [String: Any] {
        let fps = max(1, frameRate)
        let bitsPerPixel = codec == .h264 ? 0.15 : 0.09
        let bitrate = max(1_000_000, Int(Double(width * height * fps) * bitsPerPixel))
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
            AVVideoAllowFrameReorderingKey: false,
        ]
        if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        return [
            AVVideoCodecKey: codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }

    /// AAC settings: source sample rate (capped at 48 kHz), mono or stereo, 64 kbit/s per channel.
    static func audioSettings(source: AudioStreamBasicDescription) -> [String: Any] {
        let channels = min(2, max(1, Int(source.mChannelsPerFrame)))
        let rate = source.mSampleRate > 0 ? min(48_000, source.mSampleRate) : 48_000
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 64_000 * channels,
            AVChannelLayoutKey: layoutData,
        ]
    }
}

/// Copy of `sample` whose first PTS is `time`; every timing entry shifts by the same delta and
/// decode timestamps are dropped (no frame reordering in our captures).
func retime(_ sample: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
    var count: CMItemCount = 0
    guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
          count > 0 else { return nil }
    var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
    guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count) == noErr
    else { return nil }
    let first = infos[0].presentationTimeStamp
    let delta = first.isNumeric ? time - first : .zero
    for i in infos.indices {
        infos[i].presentationTimeStamp = infos[i].presentationTimeStamp.isNumeric ? infos[i].presentationTimeStamp + delta : time
        infos[i].decodeTimeStamp = .invalid
    }
    var out: CMSampleBuffer?
    let status = CMSampleBufferCreateCopyWithNewTiming(
        allocator: kCFAllocatorDefault, sampleBuffer: sample,
        sampleTimingEntryCount: count, sampleTimingArray: &infos, sampleBufferOut: &out
    )
    return status == noErr ? out : nil
}

/// Video path of one file: host-time frames → `VideoFrameGate` → writer.
// @unchecked Sendable: `gate` is guarded by `lock`; clock and writer are thread-safe.
final class VideoPipeline: @unchecked Sendable {
    let clock: RecordingClock
    let writer: MediaFileWriter
    private let lock = NSLock()
    private var gate = VideoFrameGate<CMSampleBuffer>()

    init(clock: RecordingClock, writer: MediaFileWriter) {
        self.clock = clock
        self.writer = writer
    }

    /// A captured frame whose PTS is on the host clock.
    func receive(_ frame: CMSampleBuffer, hostTime: CMTime) {
        lock.withLock {
            for (f, t) in gate.offer(frame, hostTime: hostTime, timeline: clock.stitcher) { writer.append(f, at: t) }
        }
    }

    /// Call right after the clock starts or resumes.
    func activate() {
        lock.withLock {
            for (f, t) in gate.activate(timeline: clock.stitcher) { writer.append(f, at: t) }
        }
    }
}

/// Audio path of one file: host-time PCM buffers → stitched times → writer. A buffer that
/// straddles a pause or the stop is dropped whole (≤ one buffer, ~10–20 ms).
final class AudioPipeline: Sendable {
    let clock: RecordingClock
    let writer: MediaFileWriter

    init(clock: RecordingClock, writer: MediaFileWriter) {
        self.clock = clock
        self.writer = writer
    }

    func receive(_ buffer: CMSampleBuffer, hostTime: CMTime) {
        let duration = CMSampleBufferGetDuration(buffer)
        guard let t = clock.map(hostTime, duration: duration) else { return }
        writer.append(buffer, at: t)
    }
}

/// The parts of `AVAssetWriter` that `MediaFileWriter.finish` uses. Production passes the real
/// writer; tests inject one whose `finishWriting` never calls back.
protocol MediaWriterControl: AnyObject {
    var status: AVAssetWriter.Status { get }
    var error: (any Error)? { get }
    func finishWriting(completionHandler handler: @escaping @Sendable () -> Void)
    func cancelWriting()
}

extension AVAssetWriter: MediaWriterControl {}

/// Bounded waits on `AVAssetWriter` callbacks (board EXP11-1). The timer runs on a Dispatch
/// queue, so it fires even when the Swift cooperative pool is starved.
enum MediaWriterWait {
    /// Calls `finishWriting` and waits at most `timeout` seconds for its callback; true when it
    /// came in time. After a timeout, `abandon` the writer (a stuck writer may block a
    /// synchronous `cancelWriting` too).
    nonisolated(nonsending) static func finish(_ writer: any MediaWriterControl, timeout: TimeInterval) async -> Bool {
        nonisolated(unsafe) let w = writer
        return await bounded(timeout) { done in w.finishWriting { done() } }
    }

    /// Runs `cancelWriting` on a background queue and waits at most `timeout` seconds for it.
    @discardableResult
    nonisolated(nonsending) static func cancel(_ writer: any MediaWriterControl, timeout: TimeInterval) async -> Bool {
        nonisolated(unsafe) let w = writer
        return await bounded(timeout) { done in
            DispatchQueue.global(qos: .utility).async {
                w.cancelWriting()
                done()
            }
        }
    }

    /// Runs `cancelWriting` on a background queue without waiting.
    static func abandon(_ writer: any MediaWriterControl) {
        nonisolated(unsafe) let w = writer
        DispatchQueue.global(qos: .utility).async { w.cancelWriting() }
    }

    /// Runs `start`, which calls its argument once when the work is done. True when that
    /// happened within `timeout` seconds; a later call is ignored.
    nonisolated(nonsending) static func bounded(_ timeout: TimeInterval,
                                                _ start: (@escaping @Sendable () -> Void) -> Void) async -> Bool {
        let once = ResumeOnce()
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            once.arm(c)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(timeout, 0)) {
                once.resume(false)
            }
            start { once.resume(true) }
        }
    }
}

/// Resumes a continuation exactly once, from the work or the timer, whichever comes first.
// @unchecked Sendable: every stored property is read and written under `lock`.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var resumed = false

    func arm(_ c: CheckedContinuation<Bool, Never>) {
        lock.withLock { continuation = c }
    }

    func resume(_ value: Bool) {
        let c: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard !resumed else { return nil }
            resumed = true
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: value)
    }
}
