import CoreMedia
import Foundation
import MediaEngine
import RenderEngine

/// A chunk of output audio: `frameCount` samples starting at output sample
/// `startSample`, where output sample 0 sits at timeline tick `originTicks`.
public struct AudioChunk: Sendable, Equatable {
    public var originTicks: Int64
    public var startSample: Int64
    public var frameCount: Int

    public init(originTicks: Int64, startSample: Int64, frameCount: Int) {
        self.originTicks = originTicks; self.startSample = startSample; self.frameCount = frameCount
    }
}

/// Sample/tick maths for the player's audio chunks. Output time is counted in
/// samples at `sampleRate` from a playback origin; timeline time in ticks.
public enum AudioMix {
    /// Timeline tick of output sample `sample` (relative to `originTicks`), rounded to the nearest tick.
    /// Exact when `editRate` is a multiple of `sampleRate` (705600000 is, for 44.1/48 kHz).
    public static func ticks(ofSample sample: Int64, originTicks: Int64, sampleRate: Double, editRate: Int64) -> Int64 {
        let r = Int64(sampleRate)
        if Double(r) == sampleRate, r > 0, editRate % r == 0 {
            return originTicks + sample * (editRate / r)
        }
        return originTicks + Int64((Double(sample) * Double(editRate) / sampleRate).rounded())
    }

    /// Output sample (relative to the origin) at timeline tick `ticks`, rounded to the nearest sample.
    public static func sample(atTicks ticks: Int64, originTicks: Int64, sampleRate: Double, editRate: Int64) -> Int64 {
        let r = Int64(sampleRate)
        let d = ticks - originTicks
        if Double(r) == sampleRate, r > 0, editRate % r == 0 {
            let k = editRate / r
            return d >= 0 ? (d + k / 2) / k : -((-d + k / 2) / k)
        }
        return Int64((Double(d) * sampleRate / Double(editRate)).rounded())
    }

    /// Timeline span of `chunk`, ticks.
    public static func tickRange(of chunk: AudioChunk, sampleRate: Double, editRate: Int64) -> Range<Int64> {
        let a = ticks(ofSample: chunk.startSample, originTicks: chunk.originTicks, sampleRate: sampleRate, editRate: editRate)
        let b = ticks(ofSample: chunk.startSample + Int64(chunk.frameCount), originTicks: chunk.originTicks,
                      sampleRate: sampleRate, editRate: editRate)
        return a..<max(a, b)
    }

    /// `ticks` moved to the nearest output-sample boundary (sample k at tick k · editRate / rate).
    public static func alignedTicks(_ ticks: Int64, sampleRate: Double, editRate: Int64) -> Int64 {
        let k = sample(atTicks: ticks, originTicks: 0, sampleRate: sampleRate, editRate: editRate)
        return self.ticks(ofSample: k, originTicks: 0, sampleRate: sampleRate, editRate: editRate)
    }

    /// `pcm` as exactly `channels` × `frameCount` samples: zero-padded or truncated, mono
    /// duplicated to every channel, extra channels dropped, clamped to ±1.
    public static func fit(_ pcm: PCMBuffer, frameCount: Int, channels: Int) -> [[Float]] {
        var out = [[Float]](repeating: [Float](repeating: 0, count: frameCount), count: channels)
        guard !pcm.channels.isEmpty else { return out }
        for c in 0..<channels {
            let src = pcm.channels[min(c, pcm.channels.count - 1)]
            let n = min(frameCount, src.count, max(0, pcm.frameCount))
            for i in 0..<n { out[c][i] = min(1, max(-1, src[i])) }
        }
        return out
    }
}
