import AVFoundation
import AudioEngine
import CFFmpeg
import Foundation

/// Audio-only containers written through AVAssetWriter.
enum AudioFileKind {
    /// AAC in MPEG-4 audio.
    case m4a
    /// 16-bit little-endian PCM WAVE.
    case wav
}

extension ExportSession {
    /// Writes the project mix over `range` as m4a (AAC) or wav (16-bit PCM).
    func writeAudioFile(to url: URL, kind: AudioFileKind, range: Range<Int64>) async throws {
        let mixer = requireMixer(lossy: kind == .m4a)
        var feed = AudioFeed(mixer: mixer, editRate: scene.timebase.editRate, range: range, format: await mixer.format)
        let fileType: AVFileType = kind == .m4a ? .m4a : .wav
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let settings = kind == .m4a
            ? AudioFeed.aacSettings(sampleRate: feed.sampleRate, channels: feed.channels)
            : AudioFeed.pcmSettings(sampleRate: feed.sampleRate, channels: feed.channels, bits: 16)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw ExportError.failed("cannot add audio input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw ExportError.failed(writer.error.map { "\($0)" } ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)
        var finished = false
        defer { if !finished { writer.cancelWriting() } }
        let total = Double(max(feed.totalSamples, 1))
        while !feed.isFinished {
            while !input.isReadyForMoreMediaData {
                try checkWriter(writer)
                try await pause()
            }
            try await appendAudioChunk(&feed, into: input)
            report(Double(feed.writtenSeconds * Double(feed.sampleRate)) / total * 0.99)
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: feed.totalSamples, timescale: CMTimeScale(feed.sampleRate)))
        try await finish(writer)
        finished = true
    }

    /// Writes the project mix over `range` as MP3 (libavcodec `libmp3lame`, CBR per `MP3Encoder.bitrate`,
    /// libavformat mp3 muxer with a Xing/LAME header for exact length and gapless delay).
    func writeMP3(to url: URL, range: Range<Int64>) async throws {
        let mixer = requireMixer(lossy: true)
        var feed = AudioFeed(mixer: mixer, editRate: scene.timebase.editRate, range: range, format: await mixer.format)
        let enc = try MP3Encoder(url: url, sampleRate: feed.sampleRate, channels: feed.channels,
                                 bitrate: MP3Encoder.bitrate(sampleRate: feed.sampleRate))
        let total = Double(max(feed.totalSamples, 1))
        while let chunk = try await feed.nextChunk() {
            if isCancelled { throw ExportError.cancelled }
            try enc.write(chunk.channels)
            report(feed.writtenSeconds * Double(feed.sampleRate) / total * 0.99)
        }
        try enc.finish()
    }
}

/// Minimal libavcodec/libavformat MP3 writer. Not thread-safe; one per file.
final class MP3Encoder {
    private var fmt: UnsafeMutablePointer<AVFormatContext>?
    private var ctx: UnsafeMutablePointer<AVCodecContext>?
    private var stream: UnsafeMutablePointer<AVStream>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private let channels: Int
    private let frameSize: Int
    /// Samples not yet sent to the encoder (one partial frame at most).
    private var pending: [[Float]]
    private var pts: Int64 = 0
    private var headerWritten = false
    private var finished = false

    /// CBR bitrate, bits/s: 192 k for MPEG-1 rates (≥ 32 kHz), 128 k for MPEG-2 (16–24 kHz,
    /// max 160 k), 64 k for MPEG-2.5 (≤ 12 kHz, max 64 k).
    static func bitrate(sampleRate: Int) -> Int {
        sampleRate >= 32_000 ? 192_000 : sampleRate >= 16_000 ? 128_000 : 64_000
    }

    init(url: URL, sampleRate: Int, channels: Int, bitrate: Int) throws {
        self.channels = channels
        pending = Array(repeating: [], count: channels)
        guard let codec = avcodec_find_encoder_by_name("libmp3lame") else {
            throw ExportError.failed("libmp3lame encoder not available in this FFmpeg build")
        }
        var f: UnsafeMutablePointer<AVFormatContext>?
        var rc = avformat_alloc_output_context2(&f, nil, "mp3", url.path)
        guard rc >= 0, let f else { throw ExportError.failed("mp3 muxer: \(Self.err(rc))") }
        fmt = f
        guard let c = avcodec_alloc_context3(codec) else { throw ExportError.failed("mp3 codec context") }
        ctx = c
        c.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP
        c.pointee.sample_rate = Int32(sampleRate)
        c.pointee.bit_rate = Int64(bitrate)
        av_channel_layout_default(&c.pointee.ch_layout, Int32(channels))
        c.pointee.time_base = AVRational(num: 1, den: Int32(sampleRate))
        rc = avcodec_open2(c, codec, nil)
        guard rc >= 0 else { throw ExportError.failed("libmp3lame open: \(Self.err(rc))") }
        frameSize = max(Int(c.pointee.frame_size), 1)
        guard let s = avformat_new_stream(f, nil) else { throw ExportError.failed("mp3 stream") }
        stream = s
        rc = avcodec_parameters_from_context(s.pointee.codecpar, c)
        guard rc >= 0 else { throw ExportError.failed("mp3 parameters: \(Self.err(rc))") }
        s.pointee.time_base = c.pointee.time_base
        rc = avio_open(&f.pointee.pb, url.path, AVIO_FLAG_WRITE)
        guard rc >= 0 else { throw ExportError.failed("open \(url.lastPathComponent): \(Self.err(rc))") }
        rc = avformat_write_header(f, nil)
        guard rc >= 0 else { throw ExportError.failed("mp3 header: \(Self.err(rc))") }
        headerWritten = true
        frame = av_frame_alloc()
        packet = av_packet_alloc()
        guard frame != nil, packet != nil else { throw ExportError.failed("mp3 frame alloc") }
    }

    deinit {
        if let f = fmt {
            if f.pointee.pb != nil { avio_closep(&f.pointee.pb) }
            avformat_free_context(f)
        }
        avcodec_free_context(&ctx)
        av_frame_free(&frame)
        av_packet_free(&packet)
    }

    static func err(_ code: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        av_strerror(code, &buf, buf.count)
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Queues planar samples, encoding every full frame.
    func write(_ planes: [[Float]]) throws {
        for c in 0..<channels { pending[c].append(contentsOf: c < planes.count ? planes[c] : []) }
        while pending[0].count >= frameSize { try encodeFrame(count: frameSize) }
    }

    /// Encodes the remaining samples, drains the encoder and writes the trailer.
    func finish() throws {
        guard !finished else { return }
        if !pending[0].isEmpty { try encodeFrame(count: pending[0].count) }
        try send(nil)
        guard let f = fmt else { return }
        let rc = av_write_trailer(f)
        guard rc >= 0 else { throw ExportError.failed("mp3 trailer: \(Self.err(rc))") }
        avio_closep(&f.pointee.pb)
        finished = true
    }

    private func encodeFrame(count: Int) throws {
        guard let frame, let ctx else { return }
        av_frame_unref(frame)
        frame.pointee.nb_samples = Int32(count)
        frame.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
        frame.pointee.sample_rate = ctx.pointee.sample_rate
        av_channel_layout_copy(&frame.pointee.ch_layout, &ctx.pointee.ch_layout)
        var rc = av_frame_get_buffer(frame, 0)
        guard rc >= 0 else { throw ExportError.failed("mp3 frame buffer: \(Self.err(rc))") }
        rc = av_frame_make_writable(frame)
        guard rc >= 0 else { throw ExportError.failed("mp3 frame writable: \(Self.err(rc))") }
        for c in 0..<channels {
            guard let plane = frame.pointee.extended_data[c] else { continue }
            plane.withMemoryRebound(to: Float.self, capacity: count) { dst in
                pending[c].withUnsafeBufferPointer { src in
                    for i in 0..<count { dst[i] = src[i] }
                }
            }
            pending[c].removeFirst(count)
        }
        frame.pointee.pts = pts
        pts += Int64(count)
        try send(frame)
    }

    private func send(_ frame: UnsafeMutablePointer<AVFrame>?) throws {
        guard let ctx, let packet, let fmt, let stream else { return }
        var rc = avcodec_send_frame(ctx, frame)
        guard rc >= 0 else { throw ExportError.failed("mp3 encode: \(Self.err(rc))") }
        while true {
            rc = avcodec_receive_packet(ctx, packet)
            if rc == -EAGAIN || rc == Self.eof { break }
            guard rc >= 0 else { throw ExportError.failed("mp3 encode: \(Self.err(rc))") }
            av_packet_rescale_ts(packet, ctx.pointee.time_base, stream.pointee.time_base)
            packet.pointee.stream_index = stream.pointee.index
            rc = av_interleaved_write_frame(fmt, packet)
            guard rc >= 0 else { throw ExportError.failed("mp3 write: \(Self.err(rc))") }
        }
    }

    /// `AVERROR_EOF`.
    private static let eof: Int32 = -Int32(bitPattern: UInt32(0x45) | UInt32(0x4F) << 8 | UInt32(0x46) << 16 | UInt32(0x20) << 24)
}
