import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import Recorder

/// Synthetic capture buffers, so the writer pipeline is tested without any capture permission.
enum Synth {
    /// A BGRA frame filled with one grey level, PTS `time`, no duration (VFR, like ScreenCaptureKit).
    static func videoFrame(width: Int = 320, height: Int = 180, grey: UInt8, time: CMTime) -> CMSampleBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(grey), CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample
        )
        return sample!
    }

    /// `frames` of 16-bit interleaved PCM (440 Hz sine) at `rate`, PTS `time`.
    static func audioBuffer(frames: Int = 960, rate: Double = 48_000, channels: Int = 2, time: CMTime) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(2 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format
        )
        let bytes = frames * 2 * channels
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        var pcm = [Int16](repeating: 0, count: frames * channels)
        let start = CMTimeGetSeconds(time)
        for i in 0..<frames {
            let v = Int16(8000 * sin(2 * .pi * 440 * (start + Double(i) / rate)))
            for c in 0..<channels { pcm[i * channels + c] = v }
        }
        pcm.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes) }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(rate)), presentationTimeStamp: time, decodeTimeStamp: .invalid
        )
        CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: [2 * channels], sampleBufferOut: &sample
        )
        return sample!
    }
}

func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-rec-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// Presentation times (seconds) of every sample of the file's first track, and the file duration.
func readBack(_ url: URL, type: AVMediaType) async throws -> (pts: [Double], duration: Double, size: CGSize) {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: type).first)
    let size = type == .video ? try await track.load(.naturalSize) : .zero
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    reader.startReading()
    var pts: [Double] = []
    while let s = output.copyNextSampleBuffer() {
        if CMSampleBufferGetNumSamples(s) > 0 { pts.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(s))) }
    }
    let duration = CMTimeGetSeconds(try await asset.load(.duration))
    return (pts.sorted(), duration, size)
}

@Suite struct WriterPipelineTests {
    /// 30 fps frames from -0.5 s to 3 s; pause 1 s → 2 s; stop at 3 s ⇒ a 2 s file with no gap.
    @Test(arguments: [VideoCodec.h264, .hevc])
    func videoPauseIsStitched(codec: VideoCodec) async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = RecordingClock()
        let writer = MediaFileWriter(url: dir.appendingPathComponent("screen.mp4"), kind: .video(codec: codec, frameRate: 30), realTime: false)
        let pipe = VideoPipeline(clock: clock, writer: writer)
        func frames(_ from: Int, _ to: Int) {
            for k in from..<to { pipe.receive(Synth.videoFrame(grey: UInt8(k & 0xff), time: h(Double(k) / 30)), hostTime: h(Double(k) / 30)) }
        }
        frames(-15, 0)                // warm-up during the countdown: held, last one becomes t=0
        clock.start(at: h(0)); pipe.activate()
        frames(0, 30)
        clock.pause(at: h(1))
        frames(30, 60)                // dropped (last one held)
        clock.resume(at: h(2)); pipe.activate()
        frames(60, 90)
        let end = clock.stop(at: h(3))
        #expect(CMTimeGetSeconds(end) == 2)
        #expect(try await writer.finish(at: end))

        let r = try await readBack(writer.url, type: .video)
        #expect(abs(r.duration - 2) < 0.01)
        #expect(r.size == CGSize(width: 320, height: 180))
        #expect(r.pts.first == 0)
        let maxGap = zip(r.pts, r.pts.dropFirst()).map { $1 - $0 }.max() ?? 0
        #expect(maxGap < 1.0 / 30 + 0.002, "no gap across the pause")
        #expect((r.pts.last ?? 0) < 2)
        #expect(r.pts.count >= 58 && r.pts.count <= 60)
        #expect(writer.droppedCount == 0)
    }

    /// A static screen delivers no frame after the start: the held warm-up frame fills the file.
    @Test func staticScreenStillProducesAFile() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = RecordingClock()
        let writer = MediaFileWriter(url: dir.appendingPathComponent("s.mp4"), kind: .video(codec: .h264, frameRate: 30))
        let pipe = VideoPipeline(clock: clock, writer: writer)
        pipe.receive(Synth.videoFrame(grey: 99, time: h(-1)), hostTime: h(-1))
        clock.start(at: h(0)); pipe.activate()
        let end = clock.stop(at: h(1.5))
        #expect(try await writer.finish(at: end))
        let r = try await readBack(writer.url, type: .video)
        #expect(r.pts == [0])
        #expect(abs(r.duration - 1.5) < 0.01)
    }

    @Test func emptyWriterLeavesNoFile() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = MediaFileWriter(url: dir.appendingPathComponent("none.mp4"), kind: .video(codec: .h264, frameRate: 30))
        #expect(try await writer.finish(at: CMTime(value: 1, timescale: 1)) == false)
        #expect(!FileManager.default.fileExists(atPath: writer.url.path))
    }

    /// 20 ms PCM buffers from -0.2 s to 3 s, pause 1 → 2 s: a 2 s AAC file starting at 0.
    @Test func audioPauseIsStitched() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = RecordingClock()
        let writer = MediaFileWriter(url: dir.appendingPathComponent("mic.m4a"), kind: .audio, realTime: false)
        let pipe = AudioPipeline(clock: clock, writer: writer)
        func buffers(_ from: Int, _ to: Int) {
            for k in from..<to {
                let t = CMTime(value: Int64(k) * 960, timescale: 48_000) + h(0)
                pipe.receive(Synth.audioBuffer(time: t), hostTime: t)
            }
        }
        buffers(-10, 0)
        clock.start(at: h(0))
        buffers(0, 50)
        clock.pause(at: h(1))
        buffers(50, 100)
        clock.resume(at: h(2))
        buffers(100, 150)
        let end = clock.stop(at: h(3))
        #expect(try await writer.finish(at: end))
        #expect(writer.appendedCount == 100)
        let r = try await readBack(writer.url, type: .audio)
        #expect(abs(r.duration - 2) < 0.05)
        #expect((r.pts.first ?? 1) < 0.001)
    }

    @Test func retimeShiftsAllEntries() throws {
        let s = Synth.audioBuffer(time: h(5))
        let r = try #require(retime(s, to: CMTime(value: 3, timescale: 2)))
        #expect(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(r)) == 1.5)
        #expect(CMSampleBufferGetNumSamples(r) == 960)
        #expect(CMSampleBufferGetDuration(r) == CMSampleBufferGetDuration(s))
    }

    @Test func encoderSettings() {
        let v = MediaFileWriter.videoSettings(codec: .hevc, width: 1920, height: 1080, frameRate: 30)
        #expect(v[AVVideoCodecKey] as? AVVideoCodecType == .hevc)
        let c = v[AVVideoCompressionPropertiesKey] as? [String: Any]
        #expect(c?[AVVideoMaxKeyFrameIntervalKey] as? Int == 60)
        var mono = AudioStreamBasicDescription()
        mono.mSampleRate = 96_000; mono.mChannelsPerFrame = 1
        let a = MediaFileWriter.audioSettings(source: mono)
        #expect(a[AVSampleRateKey] as? Double == 48_000)
        #expect(a[AVNumberOfChannelsKey] as? Int == 1)
    }
}
