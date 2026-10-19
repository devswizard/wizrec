import Accelerate
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

    /// ProRes 4444 carries alpha; QuickTime stores it straight (not premultiplied).
    var hasAlpha: Bool { self == .proRes4444 }

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

/// Audio side of a movie export: the feed and its writer input (nil = no audio).
struct AudioPump {
    var feed: AudioFeed?
    let input: AVAssetWriterInput?
    var done: Bool
    init(feed: AudioFeed?, input: AVAssetWriterInput?) {
        self.feed = feed; self.input = input; done = feed == nil || input == nil
    }
}

/// Fails an export whose writer accepts nothing for `limit` seconds (instead of spinning forever
/// if AVAssetWriter's interleaving ever waits on input we cannot give it).
struct StallWatch {
    var last = Date()
    var limit: TimeInterval = 30
    mutating func progressed() { last = Date() }
    func check() throws {
        if Date().timeIntervalSince(last) > limit {
            throw ExportError.failed("writer stalled for \(Int(limit)) s")
        }
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
        if let mixer = makeMixer() {
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
                let straight = codec.hasAlpha
                inFlight.append(Task {
                    nonisolated(unsafe) let target = box.buffer
                    try await renderer.render(at: ticks, into: target)
                    if straight { Self.unpremultiply(target) }
                    return box
                })
                nextToSchedule += 1
            }
        }

        // AVAssetWriter interleaves its inputs: an input stops being ready while the other lags
        // (or is not marked finished). So never block on one input: feed whichever is ready, keep
        // audio ≤ `audioLead` s ahead, and mark audio finished as soon as its feed ends.
        var pump = AudioPump(feed: feed, input: audio)
        var stall = StallWatch()

        for n in 0..<frameCount {
            if isCancelled { throw ExportError.cancelled }
            try schedule()
            let box = try await inFlight.removeFirst().value
            try schedule()
            let pts = timing.presentationTime(frame: n)
            while true {
                try checkWriter(writer)
                if try await pumpAudio(&pump, until: pts.seconds + Self.audioLead) { stall.progressed(); continue }
                if video.isReadyForMoreMediaData { break }
                // The writer wants more audio before it takes more video: give it past the lead.
                if try await pumpAudio(&pump, until: .infinity) { stall.progressed(); continue }
                try stall.check()
                try await pause()
            }
            nonisolated(unsafe) let buffer = box.buffer
            guard adaptor.append(buffer, withPresentationTime: pts) else {
                throw ExportError.failed(writer.error.map { "\($0)" } ?? "append frame \(n)")
            }
            stall.progressed()
            report(Double(n + 1) / Double(frameCount) * 0.99)
        }
        video.markAsFinished()
        while !pump.done {
            try checkWriter(writer)
            if try await pumpAudio(&pump, until: .infinity) { stall.progressed(); continue }
            try stall.check()
            try await pause()
        }
        let end = max(timing.duration, pump.feed.map { CMTime(value: $0.totalSamples, timescale: CMTimeScale($0.sampleRate)) } ?? .zero)
        writer.endSession(atSourceTime: end)
        try await finish(writer)
        finished = true
    }

    /// Appends one audio chunk if the input is ready and audio is < `seconds` ahead, or marks the
    /// input finished once the feed is exhausted. Returns true when it did something.
    func pumpAudio(_ pump: inout AudioPump, until seconds: Double) async throws -> Bool {
        guard !pump.done, var f = pump.feed, let input = pump.input else { return false }
        if f.isFinished {
            input.markAsFinished()
            pump.done = true
            return true
        }
        guard f.writtenSeconds < seconds, input.isReadyForMoreMediaData else { return false }
        try await appendAudioChunk(&f, into: input)
        pump.feed = f
        return true
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

    /// Converts a rendered premultiplied BGRA buffer to straight alpha in place (ProRes 4444
    /// stores straight alpha; without this, half-transparent white decodes as half-transparent grey).
    static func unpremultiply(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        var buf = vImage_Buffer(data: base, height: vImagePixelCount(CVPixelBufferGetHeight(pb)),
                                width: vImagePixelCount(CVPixelBufferGetWidth(pb)),
                                rowBytes: CVPixelBufferGetBytesPerRow(pb))
        // Alpha is the 4th byte in BGRA as in RGBA; the colour order does not matter here.
        vImageUnpremultiplyData_RGBA8888(&buf, &buf, vImage_Flags(kvImageNoFlags))
        CVBufferSetAttachment(pb, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_StraightAlpha,
                              .shouldPropagate)
    }

    /// Tags a rendered buffer with the output's BT.709 colour so the encoder converts RGB → YCbCr
    /// with the 709 matrix and applies no transfer-function conversion (values stay as previewed).
    /// Open: whether Camtasia tags its exports BT.709 or sRGB (gamma differs in some players) is
    /// unresolved until the user's Camtasia reference exports arrive; do not change before then.
    static func tagBT709(_ pb: CVPixelBuffer) {
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }
}
