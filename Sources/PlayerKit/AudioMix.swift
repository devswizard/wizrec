import CoreMedia
import Foundation
import MediaEngine
import RenderEngine

/// One source read that contributes to an output audio chunk.
public struct AudioMixPart: Sendable, Equatable {
    public var clipID: Int64
    public var url: URL
    /// Stream index (`trackNumber`).
    public var stream: Int
    /// Stream-time range to read.
    public var mediaRange: CMTimeRange
    /// Sample rate to request from `MediaSource.audio` so that `mediaRange` yields
    /// `frameCount` samples: output rate ÷ clip rate (speed changes resample; pitch follows, M1).
    public var requestSampleRate: Double
    /// First output sample (within the chunk) this part writes to.
    public var destOffset: Int
    /// Output samples this part covers.
    public var frameCount: Int
    /// Linear gain.
    public var gain: Double
}

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

/// Pure planning and mixing for the player's audio. Output time is counted in
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

    /// Reads needed to fill `chunk` from `segments` (as returned by `SceneModel.audioSegments(in:)`).
    public static func parts(for chunk: AudioChunk, segments: [AudioSegment], sampleRate: Double,
                             editRate: Int64) -> [AudioMixPart] {
        let span = tickRange(of: chunk, sampleRate: sampleRate, editRate: editRate)
        guard !span.isEmpty, editRate > 0, editRate <= Int64(Int32.max) else { return [] }
        let timescale = Int32(editRate)
        var out: [AudioMixPart] = []
        for s in segments {
            let lo = max(span.lowerBound, s.timelineRange.lowerBound)
            let hi = min(span.upperBound, s.timelineRange.upperBound)
            guard lo < hi, s.gain > 0 else { continue }
            let a = sample(atTicks: lo, originTicks: chunk.originTicks, sampleRate: sampleRate, editRate: editRate)
            let b = sample(atTicks: hi, originTicks: chunk.originTicks, sampleRate: sampleRate, editRate: editRate)
            let dest = Int(a - chunk.startSample)
            let count = min(Int(b - a), chunk.frameCount - dest)
            guard count > 0, dest >= 0 else { continue }
            let rate = s.rate.isFinite && s.rate > 0 ? s.rate : 1
            let offset = CMTime(value: lo - s.timelineRange.lowerBound, timescale: timescale)
            let length = CMTime(value: hi - lo, timescale: timescale)
            let start = s.mediaStart + (rate == 1 ? offset : CMTimeMultiplyByFloat64(offset, multiplier: rate))
            let dur = rate == 1 ? length : CMTimeMultiplyByFloat64(length, multiplier: rate)
            out.append(AudioMixPart(clipID: s.clipID, url: s.url, stream: s.stream,
                                    mediaRange: CMTimeRange(start: start, duration: dur),
                                    requestSampleRate: sampleRate / rate,
                                    destOffset: dest, frameCount: count, gain: s.gain))
        }
        return out
    }

    /// Sums `inputs` (each a part and the PCM read for it) into `channels` × `frameCount` samples.
    /// Inputs shorter than their part are zero-padded; longer ones truncated. Output is clamped to ±1.
    public static func mix(_ inputs: [(AudioMixPart, PCMBuffer)], frameCount: Int, channels: Int) -> [[Float]] {
        var out = [[Float]](repeating: [Float](repeating: 0, count: frameCount), count: channels)
        for (part, pcm) in inputs {
            let g = Float(part.gain)
            let n = min(part.frameCount, pcm.frameCount, frameCount - part.destOffset)
            guard n > 0, part.destOffset >= 0 else { continue }
            for c in 0..<channels {
                guard !pcm.channels.isEmpty else { break }
                let src = pcm.channels[min(c, pcm.channels.count - 1)]
                let m = min(n, src.count)
                out[c].withUnsafeMutableBufferPointer { dst in
                    src.withUnsafeBufferPointer { s in
                        for i in 0..<m { dst[part.destOffset + i] += s[i] * g }
                    }
                }
            }
        }
        for c in 0..<channels {
            out[c].withUnsafeMutableBufferPointer { b in
                for i in b.indices { b[i] = min(1, max(-1, b[i])) }
            }
        }
        return out
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
