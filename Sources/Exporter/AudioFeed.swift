import AVFoundation
import AudioEngine
import CoreMedia
import Foundation
import MediaEngine

/// Pulls the project mix in fixed sample chunks over an export range.
///
/// Sample `i` of the output is timeline time `range.lowerBound + i · editRate / sampleRate`
/// (output time `i / sampleRate` s), so audio and video share one exact origin.
struct AudioFeed {
    let mixer: AudioMixer
    let editRate: Int64
    let range: Range<Int64>
    let sampleRate: Int
    let channels: Int
    /// Total samples to write.
    let totalSamples: Int64
    /// Next sample to fetch.
    private(set) var next: Int64 = 0
    /// Samples per chunk (0.5 s).
    let chunk: Int64

    init(mixer: AudioMixer, editRate: Int64, range: Range<Int64>, format: MixFormat) {
        self.mixer = mixer; self.editRate = max(1, editRate); self.range = range
        sampleRate = max(1, Int(format.sampleRate.rounded()))
        channels = max(1, format.channels)
        totalSamples = FrameTiming.mulDiv(range.upperBound - range.lowerBound, Int64(sampleRate), self.editRate)
        chunk = Int64(max(1, sampleRate / 2))
    }

    var isFinished: Bool { next >= totalSamples }

    /// Output time of the next chunk's first sample.
    var nextTime: CMTime { CMTime(value: next, timescale: CMTimeScale(sampleRate)) }

    /// Output seconds written so far.
    var writtenSeconds: Double { Double(next) / Double(sampleRate) }

    /// Timeline ticks of output sample `i` (rounded down).
    func ticks(sample i: Int64) -> Int64 {
        range.lowerBound + FrameTiming.mulDiv(i, editRate, Int64(sampleRate))
    }

    /// The next chunk as planar Float32 of exactly the expected length, or nil when done.
    mutating func nextChunk() async throws -> (start: Int64, channels: [[Float]])? {
        guard next < totalSamples else { return nil }
        let a = next, b = min(next + chunk, totalSamples)
        let n = Int(b - a)
        let pcm = try await mixer.render(ticks(sample: a)..<ticks(sample: b))
        var planes: [[Float]] = []
        for c in 0..<channels {
            var p = c < pcm.channels.count ? pcm.channels[c] : [Float](repeating: 0, count: n)
            if p.count > n { p.removeLast(p.count - n) }
            if p.count < n { p.append(contentsOf: repeatElement(0, count: n - p.count)) }
            planes.append(p)
        }
        next = b
        return (a, planes)
    }

    /// Interleaved Float32 LPCM sample buffer for `planes` starting at output sample `start`.
    static func sampleBuffer(planes: [[Float]], start: Int64, sampleRate: Int) throws -> CMSampleBuffer {
        let ch = planes.count
        let n = planes.first?.count ?? 0
        guard ch > 0, n > 0 else { throw ExportError.failed("empty audio chunk") }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * ch), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * ch),
            mChannelsPerFrame: UInt32(ch), mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                                    magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                    formatDescriptionOut: &fmt)
        guard status == noErr, let fmt else { throw ExportError.failed("audio format description \(status)") }
        var interleaved = [Float](repeating: 0, count: n * ch)
        for c in 0..<ch {
            planes[c].withUnsafeBufferPointer { src in
                for i in 0..<n { interleaved[i * ch + c] = src[i] }
            }
        }
        let bytes = interleaved.count * 4
        var block: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
                                                    blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                    dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                    blockBufferOut: &block)
        guard status == noErr, let block else { throw ExportError.failed("audio block buffer \(status)") }
        status = interleaved.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: bytes)
        }
        guard status == noErr else { throw ExportError.failed("audio copy \(status)") }
        var sb: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: n,
            presentationTimeStamp: CMTime(value: start, timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sb)
        guard status == noErr, let sb else { throw ExportError.failed("audio sample buffer \(status)") }
        return sb
    }

    /// `AVChannelLayoutKey` data for `channels` (mono / stereo / discrete).
    static func channelLayoutData(_ channels: Int) -> Data {
        var layout = AudioChannelLayout()
        switch channels {
        case 1: layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        case 2: layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        default: layout.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        }
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }

    /// AAC bitrate, bits/s: ≈ 96 kbit/s per channel (≥ 128 kbit/s), capped at what Apple's AAC-LC
    /// encoder accepts at `sampleRate` (per channel: 160 k from 44.1 kHz, 96 k at 32 kHz, 64 k at
    /// 22.05/24 kHz, 48 k at 16 kHz, 32 k at 11.025/12 kHz, 24 k at 8 kHz; measured with
    /// `kAudioConverterApplicableEncodeBitRates`). Above the cap the writer fails on first append.
    static func aacBitrate(sampleRate: Int, channels: Int) -> Int {
        let ch = max(1, channels)
        let perChannelCap = switch sampleRate {
        case 44_100...: 160_000
        case 32_000...: 96_000
        case 22_050...: 64_000
        case 16_000...: 48_000
        case 11_025...: 32_000
        default: 24_000
        }
        return min(max(128_000, 96_000 * ch), perChannelCap * ch)
    }

    /// AAC output settings (`aacBitrate`). `sampleRate` must be an AAC rate (`lossyRates`).
    static func aacSettings(sampleRate: Int, channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: aacBitrate(sampleRate: sampleRate, channels: channels),
            AVChannelLayoutKey: channelLayoutData(channels),
        ]
    }

    /// Integer little-endian LPCM output settings.
    static func pcmSettings(sampleRate: Int, channels: Int, bits: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: bits,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVChannelLayoutKey: channelLayoutData(channels),
        ]
    }
}
