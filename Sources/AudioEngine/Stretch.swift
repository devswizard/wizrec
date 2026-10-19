// Pitch-preserving time stretch (WSOLA) for clips whose `scalar` ≠ 1.
//
// Output frames sit on a fixed grid anchored at the clip's first audible sample; frame k is
// centred at output sample n0 + k·hop and reads the input around its nominal analysis position
// a(k) (the clip's exact time mapping) shifted by δ(k) ∈ [−tolerance, tolerance]. δ(k) maximises
// the normalised cross-correlation with the natural continuation of frame k − 1. To keep any
// render range a pure function of the project (deterministic, chunk-seamless, bounded seek cost),
// the δ chain restarts with δ = 0 every `segmentFrames` frames (≈ 8 s of output).

import Accelerate
import Foundation

struct Stretcher: Sendable {
    /// Synthesis hop, samples (≈ 10 ms).
    let hop: Int
    /// Frame length = 2 · hop (periodic Hann; frames at hop spacing sum to exactly 1).
    let window: Int
    /// Maximum |δ|, samples (≈ 5 ms).
    let tolerance: Int
    /// Frames per δ chain before it restarts at δ = 0.
    let segmentFrames: Int
    let hann: [Float]

    init(sampleRate: Double) {
        hop = max(16, Int((sampleRate * 0.01).rounded()))
        window = 2 * hop
        tolerance = hop / 2
        segmentFrames = 800
        let n = window
        hann = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
    }

    /// δ for a frame: `template` (window samples) is the natural continuation of the previous frame;
    /// `region` (window + 2·tolerance samples) starts at the nominal position − tolerance.
    func bestOffset(template t: UnsafePointer<Float>, region r: UnsafePointer<Float>) -> Int {
        let n = window, lags = 2 * tolerance + 1
        // Fresh copies: vDSP results must not depend on the callers' pointer alignment.
        let template = [Float](UnsafeBufferPointer(start: t, count: n))
        let region = [Float](UnsafeBufferPointer(start: r, count: n + 2 * tolerance))
        var corr = [Float](repeating: 0, count: lags)
        vDSP_conv(region, 1, template, 1, &corr, 1, vDSP_Length(lags), vDSP_Length(n))
        // Sliding energy of the candidate windows.
        var e: Double = 0
        for i in 0..<n { e += Double(region[i]) * Double(region[i]) }
        var best = tolerance, bestScore = -Double.infinity
        var templateEnergy: Float = 0
        vDSP_svesq(template, 1, &templateEnergy, vDSP_Length(n))
        if templateEnergy < 1e-12 { return 0 }
        for j in 0..<lags {
            if j > 0 {
                let out = Double(region[j - 1]), inn = Double(region[j + n - 1])
                e += inn * inn - out * out
            }
            let score = Double(corr[j]) / (max(e, 0) + 1e-9).squareRoot()
            // Ties keep the smaller |δ| (deterministic).
            if score > bestScore + 1e-12 || (abs(score - bestScore) <= 1e-12 && abs(j - tolerance) < abs(best - tolerance)) {
                bestScore = score; best = j
            }
        }
        return best - tolerance
    }

    /// Overlap-adds frame `k` into `out` (`outStart` = output sample of `out[0]`), reading `input`
    /// (`inStart` = input sample of `input[0]`) at `pos − window/2`.
    func addFrame(center: Int64, pos: Int64, input: Signal, inStart: Int64, into out: inout Signal, outStart: Int64) {
        let half = Int64(window / 2)
        let dst0 = center - half - outStart, src0 = pos - half - inStart
        // Clip to both buffers.
        let lo = max(0, -dst0, -src0)
        let hi = min(Int64(window), Int64(out.count) - dst0, Int64(input.count) - src0)
        guard lo < hi else { return }
        if input.channelCount > out.channelCount { out.upmix(to: input.channelCount) }
        let n = Int(hi - lo)
        hann.withUnsafeBufferPointer { wp in
            guard let wb = wp.baseAddress else { return }
            for c in 0..<out.channelCount {
                let src = input.channels[min(c, input.channelCount - 1)]
                src.withUnsafeBufferPointer { sp in
                    out.channels[c].withUnsafeMutableBufferPointer { dp in
                        guard let sb = sp.baseAddress, let db = dp.baseAddress else { return }
                        let d = db + Int(dst0 + lo)
                        mulAdd(sb + Int(src0 + lo), wb + Int(lo), d, n)
                    }
                }
            }
        }
    }
}

/// Band-limited fractional resampler (Blackman-windowed sinc, unity DC gain) for pitch shifts.
/// Output sample k reads the input at k · ratio; a pure function of k, so chunk-seamless.
enum Resampler {
    /// Taps on each side of the read position, in input samples (wider as the cutoff drops).
    static func halfWidth(pitch p: Double) -> Int { Int((8 * max(1, p)).rounded(.up)) }

    /// Samples `[from, from + count)` of x(k · ratio); `input[0]` is input sample `inputStart`
    /// (zeros outside `input`). Low-passed at min(1, 1/ratio) of the input Nyquist.
    static func resample(_ input: Signal, inputStart: Int64, ratio p: Double, from: Int64, count: Int) -> Signal {
        let w = halfWidth(pitch: p), T = 2 * w
        let table = Self.table(ratio: p)
        var out = Signal.zeros(channels: input.channelCount, count: count)
        guard count > 0 else { return out }
        // Per output sample: normalised taps and the input index of the first tap.
        let taps = UnsafeMutablePointer<Float>.allocate(capacity: count * T)
        defer { taps.deallocate() }
        var bases = [Int](repeating: 0, count: count)
        table.withUnsafeBufferPointer { tp in
            guard let tab = tp.baseAddress else { return }
            for k in 0..<count {
                let x = Double(from + Int64(k)) * p
                let i0 = Int64(x.rounded(.down))
                // Taps at fraction (x − i0): linear between the two nearest tabulated rows.
                let f = (x - Double(i0)) * Double(phases)
                let r = min(phases - 1, Int(f)), u = Float(f - Double(r))
                let r0 = tab + r * T, r1 = r0 + T, d = taps + k * T
                var sum: Float = 0
                for t in 0..<T { let v = r0[t] + (r1[t] - r0[t]) * u; d[t] = v; sum += v }
                let norm: Float = sum != 0 ? 1 / sum : 1
                for t in 0..<T { d[t] *= norm }
                bases[k] = Int(i0 - Int64(w - 1) - inputStart)
            }
        }
        for c in 0..<input.channelCount {
            input.channels[c].withUnsafeBufferPointer { src in
                out.channels[c].withUnsafeMutableBufferPointer { dst in
                    guard let sb = src.baseAddress, let db = dst.baseAddress else { return }
                    let n = src.count
                    for k in 0..<count {
                        let base = bases[k], tk = taps + k * T
                        var y: Float = 0
                        if base >= 0 && base + T <= n {
                            let s = sb + base
                            for t in 0..<T { y += tk[t] * s[t] }
                        } else {
                            for t in 0..<T where base + t >= 0 && base + t < n { y += tk[t] * sb[base + t] }
                        }
                        db[k] = y
                    }
                }
            }
        }
        return out
    }

    /// Fraction steps tabulated per tap set.
    static let phases = 256

    /// Rows 0…phases of 2·halfWidth taps: row r holds the windowed-sinc weights of inputs
    /// i0 − w + 1 … i0 + w for a read position at fraction r/phases past i0.
    static func table(ratio p: Double) -> [Float] {
        let fc = min(1, 1 / p), w = halfWidth(pitch: p), T = 2 * w
        var tab = [Float](repeating: 0, count: (phases + 1) * T)
        for r in 0...phases {
            let frac = Double(r) / Double(phases)
            for t in 0..<T {
                let d = Double(t - w + 1) - frac
                guard abs(d) < Double(w) else { continue }
                let a = Double.pi * d * fc
                let s = d == 0 ? 1 : sin(a) / a
                let win = 0.42 + 0.5 * cos(Double.pi * d / Double(w)) + 0.08 * cos(2 * Double.pi * d / Double(w))
                tab[r * T + t] = Float(s * win)
            }
        }
        return tab
    }
}
