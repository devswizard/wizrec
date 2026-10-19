// Planar Float32 sample blocks and the tick ↔ sample grid of a mix.

import Accelerate
import Foundation

/// Planar Float32 audio: one array per channel, all `count` long. One channel = mono
/// (expanded to every output channel when placed).
struct Signal: Sendable {
    var channels: [[Float]]
    var count: Int

    init(channels: [[Float]], count: Int) { self.channels = channels; self.count = count }

    static func zeros(channels: Int, count: Int) -> Signal {
        Signal(channels: Array(repeating: [Float](repeating: 0, count: count), count: max(1, channels)), count: count)
    }

    var channelCount: Int { channels.count }
    var bytes: Int { channels.count * count * MemoryLayout<Float>.size }

    /// Samples `[offset, offset + n)`; zeros where that runs past the ends.
    func slice(_ offset: Int, _ n: Int) -> Signal {
        if offset == 0 && n == count { return self }
        var out = Signal.zeros(channels: channelCount, count: n)
        let lo = max(0, offset), hi = min(count, offset + n)
        guard lo < hi else { return out }
        for c in 0..<channelCount {
            channels[c].withUnsafeBufferPointer { s in
                out.channels[c].withUnsafeMutableBufferPointer { d in
                    guard let sb = s.baseAddress, let db = d.baseAddress else { return }
                    (db + (lo - offset)).update(from: sb + lo, count: hi - lo)
                }
            }
        }
        return out
    }

    /// Writes `src` at `offset` (in place, no mixing).
    mutating func write(_ src: Signal, at offset: Int) {
        let n = min(src.count, count - offset)
        guard n > 0, offset >= 0 else { return }
        if src.channelCount > channelCount { upmix(to: src.channelCount) }
        for c in 0..<channelCount {
            let s = src.channels[min(c, src.channelCount - 1)]
            s.withUnsafeBufferPointer { sp in
                channels[c].withUnsafeMutableBufferPointer { dp in
                    guard let sb = sp.baseAddress, let db = dp.baseAddress else { return }
                    (db + offset).update(from: sb, count: n)
                }
            }
        }
    }

    /// `self[offset + i] += src[i] × gain[i]` (or × `scale` when `gain` is nil). Mono sources go to
    /// every channel; a stereo source into a mono signal widens it first.
    mutating func add(_ src: Signal, at offset: Int, gain: [Float]? = nil, scale: Float = 1) {
        let n = min(src.count, count - offset)
        guard n > 0, offset >= 0 else { return }
        if src.channelCount > channelCount { upmix(to: src.channelCount) }
        for c in 0..<channelCount {
            let s = src.channels[min(c, src.channelCount - 1)]
            s.withUnsafeBufferPointer { sp in
                channels[c].withUnsafeMutableBufferPointer { dp in
                    guard let sb = sp.baseAddress, let db = dp.baseAddress else { return }
                    if let gain {
                        gain.withUnsafeBufferPointer { gp in
                            guard let gb = gp.baseAddress else { return }
                            mulAdd(sb, gb, db + offset, n)
                        }
                    } else {
                        scaleAdd(sb, scale, db + offset, n)
                    }
                }
            }
        }
    }

    /// Duplicates a mono signal (or pads with copies of the last channel) to `n` channels.
    mutating func upmix(to n: Int) {
        guard n > channelCount, let last = channels.last else { return }
        channels += Array(repeating: last, count: n - channelCount)
    }

    /// `n` output channels: equal count as is; mono duplicated; otherwise even source channels feed
    /// even outputs and odd feed odd (stereo-pair downmix, averaged).
    func mapped(to n: Int) -> Signal {
        if channelCount == n { return self }
        if channelCount == 1 { var s = self; s.upmix(to: n); return s }
        if n == 1 { return monoMix() }
        var out = Signal.zeros(channels: n, count: count)
        for o in 0..<n {
            let srcs = stride(from: o, to: channelCount, by: n).map { $0 }
            guard !srcs.isEmpty else { continue }
            let g = 1 / Float(srcs.count)
            for c in srcs {
                channels[c].withUnsafeBufferPointer { sp in
                    out.channels[o].withUnsafeMutableBufferPointer { dp in
                        guard let sb = sp.baseAddress, let db = dp.baseAddress else { return }
                        scaleAdd(sb, g, db, count)
                    }
                }
            }
        }
        return out
    }

    /// Average of all channels, as one channel.
    func monoMix() -> Signal {
        guard channelCount > 1 else { return self }
        var out = [Float](repeating: 0, count: count)
        let g = 1 / Float(channelCount)
        for ch in channels {
            ch.withUnsafeBufferPointer { sp in
                out.withUnsafeMutableBufferPointer { dp in
                    guard let sb = sp.baseAddress, let db = dp.baseAddress else { return }
                    scaleAdd(sb, g, db, count)
                }
            }
        }
        return Signal(channels: [out], count: count)
    }

    mutating func scale(by k: Float) {
        guard k != 1 else { return }
        var g = k
        for c in 0..<channelCount {
            channels[c].withUnsafeMutableBufferPointer { p in
                guard let b = p.baseAddress else { return }
                vDSP_vsmul(b, 1, &g, b, 1, vDSP_Length(count))
            }
        }
    }

    /// Clamps every sample to ±`limit`.
    mutating func clip(to limit: Float) {
        var lo = -limit, hi = limit
        for c in 0..<channelCount {
            channels[c].withUnsafeMutableBufferPointer { p in
                guard let b = p.baseAddress else { return }
                vDSP_vclip(b, 1, &lo, &hi, b, 1, vDSP_Length(count))
            }
        }
    }

    /// Samples (over all channels) whose magnitude exceeds `limit`.
    func countAbove(_ limit: Float) -> Int {
        channels.reduce(0) { n, ch in n + ch.reduce(0) { $0 + (abs($1) > limit ? 1 : 0) } }
    }

    var isAllZero: Bool { channels.allSatisfy { $0.allSatisfy { $0 == 0 } } }
}

/// The sample grid of a mix: output sample `k` sits at timeline tick `k · editRate / rate`
/// (sample 0 = tick 0), so every node's samples line up with every other's.
struct SampleGrid: Sendable, Equatable {
    let editRate: Int64
    let rate: Int64

    /// Ticks per sample (16000 at 44.1 kHz, 14700 at 48 kHz with editRate 705600000).
    var ticksPerSample: Double { Double(editRate) / Double(rate) }

    /// First sample at or after tick `t`: ⌈t · rate / editRate⌉, exact for integer ticks.
    func sampleCeil(_ t: Int64) -> Int64 {
        let (p, o) = t.multipliedReportingOverflow(by: rate)
        guard !o, editRate > 0 else { return sampleCeil(Double(t)) }
        let q = p / editRate, r = p % editRate
        return r > 0 ? q + 1 : q
    }

    /// First sample at or after tick `t` (fractional ticks, e.g. half a transition); exact
    /// for whole ticks.
    func sampleCeil(_ t: Double) -> Int64 {
        if t == t.rounded(), abs(t) < 9e15 { return sampleCeil(Int64(t)) }
        return Int64((t * Double(rate) / Double(editRate)).rounded(.up))
    }

    /// Samples whose tick lies in `range`: render(a..<b) + render(b..<c) == render(a..<c).
    func samples(_ range: Range<Int64>) -> Range<Int64> {
        let a = sampleCeil(range.lowerBound), b = sampleCeil(range.upperBound)
        return a..<max(a, b)
    }

    /// Tick of sample `k` (exact when `editRate` is a multiple of `rate`).
    func ticks(_ k: Int64) -> Double {
        editRate % rate == 0 ? Double(k * (editRate / rate)) : Double(k) * ticksPerSample
    }
}

// Element-wise kernels in plain Swift: no fused multiply-add, so every sample rounds the same way
// wherever it sits in a buffer (vDSP's vector body and scalar tail can differ in the last bit,
// which would break sample-exact chunk seams).

/// `d[i] += s[i] · g[i]`.
@inline(__always) func mulAdd(_ s: UnsafePointer<Float>, _ g: UnsafePointer<Float>, _ d: UnsafeMutablePointer<Float>, _ n: Int) {
    for i in 0..<n { d[i] = d[i] + s[i] * g[i] }
}

/// `d[i] += s[i] · k`.
@inline(__always) func scaleAdd(_ s: UnsafePointer<Float>, _ k: Float, _ d: UnsafeMutablePointer<Float>, _ n: Int) {
    if k == 1 { for i in 0..<n { d[i] = d[i] + s[i] } } else { for i in 0..<n { d[i] = d[i] + s[i] * k } }
}

@inline(__always) func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
}
