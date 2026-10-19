import CoreMedia
import Foundation
import MediaEngine
import RenderEngine
import Testing
@testable import PlayerKit

private let E: Int64 = 705_600_000
private let R = 44100.0
private let k = E / 44100   // ticks per sample
private let url = URL(fileURLWithPath: "/tmp/a.m4a")

private func seg(_ lo: Int64, _ hi: Int64, media: CMTime = .zero, rate: Double = 1, gain: Double = 1) -> AudioSegment {
    AudioSegment(clipID: 1, url: url, stream: 2, timelineRange: lo..<hi, mediaStart: media, rate: rate, gain: gain)
}

@Suite struct AudioMixTests {
    @Test func samplesAndTicksAreExactAtCamtasiaRate() {
        #expect(AudioMix.ticks(ofSample: 44100, originTicks: 7, sampleRate: R, editRate: E) == E + 7)
        #expect(AudioMix.sample(atTicks: E + 7, originTicks: 7, sampleRate: R, editRate: E) == 44100)
        #expect(AudioMix.sample(atTicks: k / 2 + 1, originTicks: 0, sampleRate: R, editRate: E) == 1)
        // Old frame-based timebase: rounded, not exact.
        #expect(AudioMix.ticks(ofSample: 44100, originTicks: 0, sampleRate: R, editRate: 30) == 30)
    }

    @Test func chunkWindowCoversSegmentPartially() {
        // Chunk = samples [11025, 22050) after an origin at 2 s; segment from 2.3 s to 2.4 s.
        let origin = 2 * E
        let chunk = AudioChunk(originTicks: origin, startSample: 11025, frameCount: 11025)
        let span = AudioMix.tickRange(of: chunk, sampleRate: R, editRate: E)
        #expect(span == (origin + 11025 * k)..<(origin + 22050 * k))
        let lo = origin + E * 3 / 10, hi = origin + E * 4 / 10
        let parts = AudioMix.parts(for: chunk, segments: [seg(lo, hi, media: CMTime(value: 5, timescale: 1))],
                                   sampleRate: R, editRate: E)
        #expect(parts.count == 1)
        let p = parts[0]
        #expect(p.destOffset == 13230 - 11025)
        #expect(p.frameCount == 4410)
        #expect(p.mediaRange.start == CMTime(value: 5, timescale: 1))
        #expect(p.mediaRange.duration == CMTime(value: E / 10, timescale: Int32(E)))
        #expect(p.requestSampleRate == R)
    }

    @Test func segmentStartingBeforeChunkReadsFromOffset() {
        let chunk = AudioChunk(originTicks: 0, startSample: 44100, frameCount: 4410)   // 1.0–1.1 s
        let parts = AudioMix.parts(for: chunk, segments: [seg(0, 10 * E, media: CMTime(value: 3, timescale: 1))],
                                   sampleRate: R, editRate: E)
        #expect(parts.count == 1)
        #expect(parts[0].destOffset == 0)
        #expect(parts[0].frameCount == 4410)
        #expect(parts[0].mediaRange.start.seconds == 4)
        #expect(abs(parts[0].mediaRange.duration.seconds - 0.1) < 1e-9)
    }

    @Test func spedUpClipReadsMoreMediaAndResamples() {
        let chunk = AudioChunk(originTicks: 0, startSample: 0, frameCount: 44100)
        let parts = AudioMix.parts(for: chunk, segments: [seg(0, E, rate: 2)], sampleRate: R, editRate: E)
        #expect(parts.count == 1)
        #expect(abs(parts[0].mediaRange.duration.seconds - 2) < 1e-6)
        #expect(parts[0].requestSampleRate == R / 2)   // 2 s of media → 44100 output samples
        #expect(parts[0].frameCount == 44100)
    }

    @Test func silentAndOutsideSegmentsAreSkipped() {
        let chunk = AudioChunk(originTicks: 0, startSample: 0, frameCount: 4410)
        let parts = AudioMix.parts(for: chunk, segments: [seg(0, E, gain: 0), seg(2 * E, 3 * E)],
                                   sampleRate: R, editRate: E)
        #expect(parts.isEmpty)
    }

    @Test func mixesWithGainPaddingAndClamp() {
        func part(_ off: Int, _ n: Int, _ g: Double) -> AudioMixPart {
            AudioMixPart(clipID: 1, url: url, stream: 0, mediaRange: CMTimeRange(start: .zero, duration: .zero),
                         requestSampleRate: R, destOffset: off, frameCount: n, gain: g)
        }
        func pcm(_ v: Float, _ n: Int, ch: Int = 1) -> PCMBuffer {
            PCMBuffer(format: PCMFormat(sampleRate: R, channels: ch), startTime: .zero, frameCount: n,
                      channels: Array(repeating: Array(repeating: v, count: n), count: ch))
        }
        let out = AudioMix.mix([(part(0, 4, 0.5), pcm(0.4, 4)),
                                (part(2, 4, 1), pcm(0.9, 3)),        // short read: zero-padded
                                (part(6, 10, 1), pcm(0.25, 10))],    // past the end: truncated
                               frameCount: 8, channels: 2)
        #expect(out.count == 2)
        #expect(out[0] == out[1])                       // mono source fills both channels
        #expect(abs(out[0][0] - 0.2) < 1e-6)
        #expect(abs(out[0][2] - 1.0) < 1e-6)            // 0.2 + 0.9 = 1.1 → clamped
        #expect(abs(out[0][4] - 0.9) < 1e-6)
        #expect(out[0][5] == 0)
        #expect(abs(out[0][7] - 0.25) < 1e-6)
    }
}
