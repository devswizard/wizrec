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

/// Audio side of a movie export: where chunks come from and their writer input (nil = no audio).
struct AudioPump {
    enum Source {
        /// Mixed inline by the writer loop (the serial path).
        case inline(AudioFeed)
        /// Mixed ahead on a separate task.
        case prefetched(AudioPrefetch)
    }
    var source: Source?
    let input: AVAssetWriterInput?
    var done: Bool
    /// Samples handed to the writer so far, and in total.
    var written: Int64 = 0
    let total: Int64
    let sampleRate: Int

    init(feed: AudioFeed?, input: AVAssetWriterInput?, prefetch: Bool, depth: Int) {
        self.input = input
        total = feed?.totalSamples ?? 0
        sampleRate = feed?.sampleRate ?? 1
        if let feed, input != nil {
            source = prefetch ? .prefetched(AudioPrefetch(feed: feed, capacity: depth)) : .inline(feed)
        }
        done = source == nil
    }

    /// Output seconds handed to the writer so far.
    var writtenSeconds: Double { Double(written) / Double(sampleRate) }

    /// Stops a prefetch task (no-op for the inline source).
    func cancel() {
        if case .prefetched(let p) = source { p.cancel() }
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

extension ExportSession {
    /// Frames rendered ahead of the writer (render n+1, n+2 while n is encoded).
    static let pipelineDepth = 6
    /// Audio is kept this far ahead of video so the writer can interleave.
    static let audioLead = 0.5
    /// Audio chunks (0.5 s each) mixed ahead of the writer on their own task.
    static let audioPrefetchDepth = 8
    /// True mixes audio inline in the writer loop instead of on a prefetch task (tests compare the two).
    @TaskLocal static var serialAudio = false

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
        if let mixer = makeMixer(lossy: !codec.isProRes) {
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

        // Frames render in order with `pipelineDepth` in flight (fetch n+1 while the GPU draws n
        // and the writer encodes n-1); RenderPipeline fetches strictly in frame order.
        let renderer = OfflineRenderer(scene: scene, pool: pool)
        nonisolated(unsafe) let bufferPool = adaptor.pixelBufferPool
        let pipe = renderer.pipeline(ticks: (0..<frameCount).map { timing.ticks(frame: $0) },
                                     maxInFlight: Self.pipelineDepth) { _ in
            guard let bufferPool else { throw ExportError.failed("no pixel buffer pool") }
            var out: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, bufferPool, &out)
            guard let pb = out else { throw ExportError.failed("pixel buffer allocation") }
            Self.tagBT709(pb)
            return pb
        }
        var pipeDone = false
        defer { if !pipeDone { Task { await pipe.cancel() } } }
        let straight = codec.hasAlpha

        // AVAssetWriter interleaves its inputs: an input stops being ready while the other lags
        // (or is not marked finished). So never block on one input: feed whichever is ready, keep
        // audio ≤ `audioLead` s ahead, and mark audio finished as soon as its feed ends.
        var pump = AudioPump(feed: feed, input: audio, prefetch: !Self.serialAudio, depth: Self.audioPrefetchDepth)
        defer { pump.cancel() }
        var stall = StallWatch()

        for n in 0..<frameCount {
            if isCancelled { throw ExportError.cancelled }
            guard let frame = try await pipe.next() else { throw ExportError.failed("render pipeline ended at frame \(n)") }
            if straight { Self.unpremultiply(frame.pixelBuffer) }
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
            guard adaptor.append(frame.pixelBuffer, withPresentationTime: pts) else {
                throw ExportError.failed(writer.error.map { "\($0)" } ?? "append frame \(n)")
            }
            stall.progressed()
            report(Double(n + 1) / Double(frameCount) * 0.99)
        }
        pipeDone = true
        video.markAsFinished()
        while !pump.done {
            try checkWriter(writer)
            if try await pumpAudio(&pump, until: .infinity) { stall.progressed(); continue }
            try stall.check()
            try await pause()
        }
        let end = max(timing.duration, pump.source == nil ? .zero : CMTime(value: pump.total, timescale: CMTimeScale(pump.sampleRate)))
        writer.endSession(atSourceTime: end)
        try await finish(writer)
        finished = true
    }

    /// Appends one audio chunk if the input is ready and audio is < `seconds` ahead, or marks the
    /// input finished once all samples are written. Returns true when it did something.
    func pumpAudio(_ pump: inout AudioPump, until seconds: Double) async throws -> Bool {
        guard !pump.done, let source = pump.source, let input = pump.input else { return false }
        if pump.written >= pump.total {
            input.markAsFinished()
            pump.done = true
            return true
        }
        guard pump.writtenSeconds < seconds, input.isReadyForMoreMediaData else { return false }
        if isCancelled { throw ExportError.cancelled }
        let chunk: AudioChunk?
        switch source {
        case .inline(var f):
            chunk = try await f.nextChunk().map { c in
                AudioChunk(buffer: try AudioFeed.sampleBuffer(planes: c.channels, start: c.start, sampleRate: f.sampleRate),
                           samples: Int64(c.channels.first?.count ?? 0))
            }
            pump.source = .inline(f)
        case .prefetched(let p):
            chunk = try await p.next()
        }
        guard let chunk, chunk.samples > 0 else { throw ExportError.failed("audio mix ended early") }
        guard input.append(chunk.buffer) else { throw ExportError.failed("audio append failed") }
        pump.written += chunk.samples
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
