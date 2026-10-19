// ITU-R BS.1770-4 loudness (EBU R128): K-weighting, 400 ms blocks every 100 ms, absolute
// (−70 LUFS) and relative (−10 LU) gates; true peak by 4× oversampling (Annex 2).
// Written from the published recommendation.

import CoreMedia
import Foundation
import MediaEngine

/// Biquad, direct form I, Double precision.
struct Biquad: Sendable {
    var b0, b1, b2, a1, a2: Double
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    init(b: (Double, Double, Double), a: (Double, Double)) {
        b0 = b.0; b1 = b.1; b2 = b.2; a1 = a.0; a2 = a.1
    }

    @inline(__always) mutating func step(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }

    /// BS.1770 stage 1 (high-shelf "pre-filter") for sample rate `fs`, from its analogue
    /// prototype (f0 1681.97 Hz, gain +4.0 dB, Q 0.7072) by the bilinear transform; equals the
    /// recommendation's 48 kHz coefficients.
    static func shelf(_ fs: Double) -> Biquad {
        let f0 = 1681.974450955533, g = 3.999843853973347, q = 0.7071752369554196
        let k = tan(Double.pi * f0 / fs)
        let vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        return Biquad(b: ((vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0),
                      a: (2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0))
    }

    /// BS.1770 stage 2 (RLB high-pass, f0 38.14 Hz, Q 0.5003).
    static func highPass(_ fs: Double) -> Biquad {
        let f0 = 38.13547087602444, q = 0.5003270373238773
        let k = tan(Double.pi * f0 / fs)
        let a0 = 1 + k / q + k * k
        return Biquad(b: (1, -2, 1), a: (2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0))
    }
}

/// Streaming BS.1770-4 meter. Feeding a signal in chunks gives the same result as one pass.
struct LoudnessMeter: Sendable {
    let sampleRate: Double
    let channels: Int
    /// Channel weights G_i (L, R, C = 1; surrounds 1.41; LFE 0). `dualMono` weights a mono
    /// channel 2 (the +3.01 dB Camtasia's `integratedLUFS` shows for mono sources [obs, media]).
    let weights: [Double]
    private var filters: [(Biquad, Biquad)]
    /// Samples per 100 ms sub-block.
    private let sub: Int
    private var subFill = 0
    private var subSum: [Double]
    /// Weighted channel-sum mean square of every complete 100 ms sub-block.
    private var subBlocks: [Double] = []

    init(sampleRate: Double, channels: Int, dualMono: Bool = false) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        switch self.channels {
        case 1: weights = [dualMono ? 2 : 1]
        case 5: weights = [1, 1, 1, 1.41, 1.41]
        case 6: weights = [1, 1, 1, 0, 1.41, 1.41]
        default: weights = Array(repeating: 1, count: self.channels)
        }
        filters = Array(repeating: (Biquad.shelf(sampleRate), Biquad.highPass(sampleRate)), count: self.channels)
        sub = max(1, Int((sampleRate / 10).rounded()))
        subSum = Array(repeating: 0, count: self.channels)
    }

    mutating func feed(_ chans: [[Float]], count: Int) {
        guard count > 0 else { return }
        var i = 0
        while i < count {
            let n = min(sub - subFill, count - i)
            for c in 0..<channels {
                guard c < chans.count, weights[c] != 0 else { continue }
                var (f1, f2) = filters[c]
                var s = 0.0
                chans[c].withUnsafeBufferPointer { p in
                    for j in i..<(i + n) {
                        let y = f2.step(f1.step(Double(p[j])))
                        s += y * y
                    }
                }
                filters[c] = (f1, f2)
                subSum[c] += s
            }
            subFill += n
            i += n
            if subFill == sub {
                var z = 0.0
                for c in 0..<channels { z += weights[c] * subSum[c] / Double(sub); subSum[c] = 0 }
                subBlocks.append(z)
                subFill = 0
            }
        }
    }

    /// Weighted mean-square energy of each 400 ms gating block (75 % overlap).
    var blockEnergies: [Double] {
        guard subBlocks.count >= 4 else { return [] }
        return (0...(subBlocks.count - 4)).map { i in
            (subBlocks[i] + subBlocks[i + 1] + subBlocks[i + 2] + subBlocks[i + 3]) / 4
        }
    }

    static func lufs(_ energy: Double) -> Double { energy > 0 ? -0.691 + 10 * log10(energy) : -.infinity }

    /// Gated integrated loudness, LUFS; `-.infinity` when no block passes the gates (silence,
    /// or shorter than 400 ms).
    var integrated: Double {
        let blocks = blockEnergies
        let abs = blocks.filter { Self.lufs($0) > -70 }
        guard !abs.isEmpty else { return -.infinity }
        let rel = Self.lufs(abs.reduce(0, +) / Double(abs.count)) - 10
        let gated = abs.filter { Self.lufs($0) > rel }
        guard !gated.isEmpty else { return -.infinity }
        return Self.lufs(gated.reduce(0, +) / Double(gated.count))
    }
}

/// True-peak meter: 4× oversampling (2× at ≥ 96 kHz, none at ≥ 192 kHz) with a 48-tap
/// windowed-sinc interpolator per BS.1770-4 Annex 2; the max of |oversampled| and |samples|.
struct TruePeakMeter: Sendable {
    let factor: Int
    /// Polyphase taps: `phases[p][j]` weights input `x[n − j]` for output phase p.
    private let phases: [[Float]]
    private let taps: Int
    /// Last `taps` input samples per channel, oldest first.
    private var history: [[Float]]
    private(set) var peak: Float = 0

    init(sampleRate: Double, channels: Int) {
        factor = sampleRate < 96_000 ? 4 : (sampleRate < 192_000 ? 2 : 1)
        taps = 12
        let L = factor, n = taps * L
        // Kaiser-like (Blackman) windowed sinc lowpass at the original Nyquist, centred at (n−1)/2.
        let mid = Double(n - 1) / 2
        var h = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let x = (Double(i) - mid) / Double(L)
            let sinc = x == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x)
            let w = 0.42 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1)) + 0.08 * cos(4 * Double.pi * Double(i) / Double(n - 1))
            h[i] = sinc * w
        }
        var ph: [[Float]] = []
        for p in 0..<L {
            let coeffs = stride(from: p, to: n, by: L).map { h[$0] }
            let sum = coeffs.reduce(0, +)
            ph.append(coeffs.map { Float($0 / (sum == 0 ? 1 : sum)) })
        }
        phases = ph
        history = Array(repeating: [Float](repeating: 0, count: taps), count: max(1, channels))
    }

    mutating func feed(_ chans: [[Float]], count: Int) {
        guard count > 0 else { return }
        for c in 0..<min(chans.count, history.count) {
            // ext = the last `taps` inputs (oldest first) followed by this chunk; output phase p at
            // input i is Σ_j phases[p][j] · x[i − j], i.e. a dot product over ext[i+1 … i+taps]
            // with the taps reversed.
            var ext = history[c]
            ext.append(contentsOf: chans[c].prefix(count))
            var pk = peak
            for x in chans[c].prefix(count) { pk = max(pk, abs(x)) }
            if factor > 1 {
                let rev = phases.map { Array($0.reversed()) }
                ext.withUnsafeBufferPointer { e in
                    guard let eb = e.baseAddress else { return }
                    for r in rev {
                        r.withUnsafeBufferPointer { rp in
                            guard let rb = rp.baseAddress else { return }
                            for i in 0..<count {
                                let w = eb + i + 1
                                var y: Float = 0
                                for j in 0..<taps { y += rb[j] * w[j] }
                                pk = max(pk, abs(y))
                            }
                        }
                    }
                }
            }
            history[c] = Array(ext.suffix(taps))
            peak = pk
        }
    }

    var dBTP: Double { peak > 0 ? 20 * log10(Double(peak)) : -.infinity }
}
