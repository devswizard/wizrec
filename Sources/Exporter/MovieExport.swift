import AVFoundation
import AudioEngine
import CoreMedia
import CoreVideo
import Foundation
import MediaEngine
import RenderEngine
import VideoToolbox

/// Video codec of a movie export.
enum VideoCodec: Equatable {
    case h264(bitrate: Int?)
    case hevc(bitrate: Int?)
    case proRes422, proRes422HQ, proRes4444

    var avCodec: AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        case .proRes422: .proRes422
        case .proRes422HQ: .proRes422HQ
        case .proRes4444: .proRes4444
        }
    }

    var isProRes: Bool {
        switch self {
        case .proRes422, .proRes422HQ, .proRes4444: true
        default: false
        }
    }

    /// Automatic average bitrate, bits/s: 0.12 (H.264) / 0.07 (HEVC) bits per pixel per frame,
    /// e.g. 7.5 / 4.4 Mbit/s at 1080p30; at least 1 Mbit/s.
    static func automaticBitrate(hevc: Bool, width: Int, height: Int, fps: Double) -> Int {
        let bpp = hevc ? 0.07 : 0.12
        return max(1_000_000, Int(Double(width * height) * max(fps, 1) * bpp))
    }

    /// AVAssetWriterInput output settings for a `width`×`height` stream at `fps`, BT.709 tagged.
    func outputSettings(width: Int, height: Int, fps: Double) -> [String: Any] {
        var s: [String: Any] = [
            AVVideoCodecKey: avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        switch self {
        case .h264(let b):
            s[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: b ?? Self.automaticBitrate(hevc: false, width: width, height: height, fps: fps),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoAllowFrameReorderingKey: true,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
            ] as [String: Any]
        case .hevc(let b):
            s[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: b ?? Self.automaticBitrate(hevc: true, width: width, height: height, fps: fps),
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoAllowFrameReorderingKey: true,
            ] as [String: Any]
        default:
            break
        }
        return s
    }
}

/// A rendered output frame handed between pipeline stages.
// @unchecked: each buffer is owned by exactly one stage at a time (allocated by the session,
// filled by one render call, then appended to the writer); nothing touches it concurrently.
struct PixelBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

extension ExportSession {
    /// Frames rendered ahead of the writer (render n+1, n+2 while n is encoded).
    static let pipelineDepth = 6
    /// Audio is kept this far ahead of video so the writer can interleave.
    static let audioLead = 0.5

    /// Writes a movie: video from the render path, plus the project mix when available.
    func writeMovie(to url: URL, fileType: AVFileType, codec: VideoCodec, resolved r: ResolvedExport) async throws {
        let timing = r.timing
        let frameCount = timing.frameCount
        guard frameCount > 0 else { throw ExportError.failed("no frames in range") }
        let w = Int(r.size.width), h = Int(r.size.height)

        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = fileType == .mp4
        writer.movieTimeScale = timing.timescale
        let fps = timing.fps.double
        let video = AVAssetWriterInput(mediaType: .video,
                                       outputSettings: codec.outputSettings(width: w, height: h, fps: fps))
        video.expectsMediaDataInRealTime = false
        video.mediaTimeScale = timing.timescale
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        guard writer.canAdd(video) else { throw ExportError.failed("cannot add \(codec.avCodec.rawValue) video") }
        writer.add(video)

        var feed: AudioFeed?
        var audio: AVAssetWriterInput?
        if let mixer = try await makeMixer() {
            let f = AudioFeed(mixer: mixer, editRate: scene.timebase.editRate, range: r.range, format: await mixer.format)
            let settings = codec.isProRes
                ? AudioFeed.pcmSettings(sampleRate: f.sampleRate, channels: f.channels, bits: 24)
                : AudioFeed.aacSettings(sampleRate: f.sampleRate, channels: f.channels)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw ExportError.failed("cannot add audio") }
            writer.add(input)
            feed = f; audio = input
        }

        guard writer.startWriting() else {
            throw ExportError.failed(writer.error.map { "\($0)" } ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)
        var finished = false
        defer { if !finished { writer.cancelWriting() } }

        let renderer = OfflineRenderer(scene: scene, pool: pool)
        var inFlight: [Task<PixelBox, any Error>] = []
        defer { for t in inFlight { t.cancel() } }
        var nextToSchedule = 0

        func schedule() throws {
            while inFlight.count < Self.pipelineDepth, nextToSchedule < frameCount {
                guard let pool = adaptor.pixelBufferPool else { throw ExportError.failed("no pixel buffer pool") }
                var out: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
                guard let pb = out else { throw ExportError.failed("pixel buffer allocation") }
                Self.tagBT709(pb)
                let box = PixelBox(buffer: pb)
                let ticks = timing.ticks(frame: nextToSchedule)
                inFlight.append(Task {
                    nonisolated(unsafe) let target = box.buffer
                    try await renderer.render(at: ticks, into: target)
                    return box
                })
                nextToSchedule += 1
            }
        }

        for n in 0..<frameCount {
            if isCancelled { throw ExportError.cancelled }
            try schedule()
            let box = try await inFlight.removeFirst().value
            try schedule()
            let pts = timing.presentationTime(frame: n)
            // Keep audio a little ahead so the writer can interleave.
            if var f = feed, let audio {
                try await feedAudio(&f, into: audio, writer: writer, until: pts.seconds + Self.audioLead)
                feed = f
            }
            while !video.isReadyForMoreMediaData {
                try checkWriter(writer)
                if var f = feed, let audio, !f.isFinished, audio.isReadyForMoreMediaData {
                    try await appendAudioChunk(&f, into: audio)
                    feed = f
                } else {
                    try await pause()
                }
            }
            nonisolated(unsafe) let buffer = box.buffer
            guard adaptor.append(buffer, withPresentationTime: pts) else {
                throw ExportError.failed(writer.error.map { "\($0)" } ?? "append frame \(n)")
            }
            report(Double(n + 1) / Double(frameCount) * 0.99)
        }
        video.markAsFinished()
        if var f = feed, let audio {
            try await feedAudio(&f, into: audio, writer: writer, until: .infinity)
            audio.markAsFinished()
        }
        let end = max(timing.duration, feed.map { CMTime(value: $0.totalSamples, timescale: CMTimeScale($0.sampleRate)) } ?? .zero)
        writer.endSession(atSourceTime: end)
        try await finish(writer)
        finished = true
    }

    /// Appends audio chunks until `seconds` of output audio are written (or the feed ends).
    func feedAudio(_ feed: inout AudioFeed, into input: AVAssetWriterInput, writer: AVAssetWriter,
                   until seconds: Double) async throws {
        while !feed.isFinished, feed.writtenSeconds < seconds {
            while !input.isReadyForMoreMediaData {
                try checkWriter(writer)
                try await pause()
            }
            try await appendAudioChunk(&feed, into: input)
        }
    }

    func appendAudioChunk(_ feed: inout AudioFeed, into input: AVAssetWriterInput) async throws {
        if isCancelled { throw ExportError.cancelled }
        guard let chunk = try await feed.nextChunk() else { return }
        let sb = try AudioFeed.sampleBuffer(planes: chunk.channels, start: chunk.start, sampleRate: feed.sampleRate)
        guard input.append(sb) else { throw ExportError.failed("audio append failed") }
    }

    func checkWriter(_ writer: AVAssetWriter) throws {
        if isCancelled { throw ExportError.cancelled }
        if writer.status == .failed || writer.status == .cancelled {
            throw ExportError.failed(writer.error.map { "\($0)" } ?? "writer status \(writer.status.rawValue)")
        }
    }

    /// `finishWriting` bridged to async; throws if the file did not complete.
    func finish(_ writer: AVAssetWriter) async throws {
        nonisolated(unsafe) let w = writer
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            w.finishWriting { c.resume() }
        }
        guard writer.status == .completed else {
            throw ExportError.failed(writer.error.map { "\($0)" } ?? "writer status \(writer.status.rawValue)")
        }
    }

    /// Tags a rendered buffer with the output's BT.709 colour so the encoder converts RGB → YCbCr
    /// with the 709 matrix and applies no transfer-function conversion (values stay as previewed).
    static func tagBT709(_ pb: CVPixelBuffer) {
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }
}
