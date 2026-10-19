import CoreMedia
import Foundation
import MediaEngine
import RenderEngine
import Testing
@testable import PlayerKit

private let E: Int64 = 705_600_000
private let R = 44100.0
private let k = E / 44100   // ticks per sample

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
    }

    @Test func alignsTicksToTheSampleGrid() {
        #expect(AudioMix.alignedTicks(5 * k, sampleRate: R, editRate: E) == 5 * k)
        #expect(AudioMix.alignedTicks(5 * k + k / 2 - 1, sampleRate: R, editRate: E) == 5 * k)
        #expect(AudioMix.alignedTicks(5 * k + k / 2 + 1, sampleRate: R, editRate: E) == 6 * k)
        // 30 fps frame boundaries are already on the 48 kHz and 44.1 kHz grids.
        let frame = E / 30
        #expect(AudioMix.alignedTicks(7 * frame, sampleRate: 48_000, editRate: E) == 7 * frame)
        #expect(AudioMix.alignedTicks(7 * frame, sampleRate: R, editRate: E) == 7 * frame)
    }

    @Test func fitsMixerOutputToTheChunk() {
        let mono = PCMBuffer(format: PCMFormat(sampleRate: R, channels: 1), startTime: .zero, frameCount: 3,
                             channels: [[0.5, -2, 0.25]])
        let out = AudioMix.fit(mono, frameCount: 5, channels: 2)
        #expect(out == [[0.5, -1, 0.25, 0, 0], [0.5, -1, 0.25, 0, 0]])
        let wide = PCMBuffer(format: PCMFormat(sampleRate: R, channels: 3), startTime: .zero, frameCount: 4,
                             channels: [[1, 1, 1, 1], [0.1, 0.2, 0.3, 0.4], [9, 9, 9, 9]])
        #expect(AudioMix.fit(wide, frameCount: 2, channels: 2) == [[1, 1], [0.1, 0.2]])
        let empty = PCMBuffer(format: PCMFormat(sampleRate: R, channels: 0), startTime: .zero, frameCount: 0, channels: [])
        #expect(AudioMix.fit(empty, frameCount: 2, channels: 2) == [[0, 0], [0, 0]])
    }
}

