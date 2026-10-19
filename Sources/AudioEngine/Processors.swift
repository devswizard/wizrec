// WizRec's own audio effect DSP (AUD-3): spectral noise reduction, leveling, pitch shift.
//
// Every processor has finite memory (`AudioProcessor`, Processing.swift): its output at sample i
// depends only on input samples [i − history, i + lookahead], and analysis frames sit on a grid
// anchored at absolute sample 0. Blocks are therefore deterministic, and neighbouring blocks agree
// on every shared frame, so the effect has no seams. No recursive (IIR) state anywhere.
// Written from textbook methods (spectral subtraction with minimum-statistics noise tracking,
// windowed-RMS gain riding, granular overlap-add pitch shifting); no third-party code.

import Accelerate
import Foundation

// MARK: Real FFT

/// Real-input DFT of length `n` (vDSP, packed format: bin 0 in `re[0]`, bin n/2 in `im[0]`).
/// Created per block: setups are cheap next to a block's work, and nothing non-Sendable outlives
/// a `process` call.
final class RealFFT {
    let n: Int
    private let fwd: vDSP_DFT_Setup
    private let inv: vDSP_DFT_Setup
    /// Gain of forward + inverse (vDSP leaves both unnormalised).
    private(set) var roundTripScale: Float = 1
    private var even: [Float]
    private var odd: [Float]

    init?(n: Int) {
        guard n >= 32, n % 2 == 0,
              let f = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD) else { return nil }
        guard let i = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .INVERSE) else {
            vDSP_DFT_DestroySetup(f)
            return nil
        }
        self.n = n; fwd = f; inv = i
        even = [Float](repeating: 0, count: n / 2); odd = even
        var x = [Float](repeating: 0, count: n); x[0] = 1
        var re = even, im = even
        forward(x, &re, &im)
        inverse(re, im, &x)
        roundTripScale = x[0] == 0 ? 1 : x[0]
    }

    deinit {
        vDSP_DFT_DestroySetup(fwd)
        vDSP_DFT_DestroySetup(inv)
    }

    /// Spectrum of `x` (n samples) into `re`/`im` (n/2 each, packed).
    func forward(_ x: [Float], _ re: inout [Float], _ im: inout [Float]) {
        for j in 0..<(n / 2) { even[j] = x[2 * j]; odd[j] = x[2 * j + 1] }
        vDSP_DFT_Execute(fwd, even, odd, &re, &im)
    }

    /// Time signal (n samples, × `roundTripScale`) of a packed spectrum.
    func inverse(_ re: [Float], _ im: [Float], _ out: inout [Float]) {
        vDSP_DFT_Execute(inv, re, im, &even, &odd)
        for j in 0..<(n / 2) { out[2 * j] = even[j]; out[2 * j + 1] = odd[j] }
    }
}

/// Periodic Hann window: copies at a hop of n/4 sum to 2, and squared copies sum to 1.5.
func periodicHann(_ n: Int) -> [Float] {
    (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
}

// MARK: Noise reduction

/// Spectral noise reduction (`Amount` 0–1 → up to 30 dB of attenuation).
///
/// STFT (Hann, 75 % overlap) on the absolute sample grid. The noise spectrum of frame f is the
/// per-bin minimum of the 3-frame-smoothed power over the previous ~1.5 s (minimum statistics,
/// × 1.5 bias), from the channel average; frames of digital silence are ignored. Gain per bin =
/// max(floor, 1 − 2·noise/power), averaged over 3 frames × 3 bins against musical noise, and
/// applied to every channel (stereo image kept).
struct NoiseReducer: AudioProcessor {
    let n: Int
    let hop: Int
    let window: [Float]
    /// Lowest gain, linear.
    let floorGain: Float
    /// Frames in the noise-minimum window.
    let noiseFrames: Int
    let smoothFrames = 3
    let gainFrames = 3
    let overSubtraction: Float = 2
    let bias: Float = 1.5

    init(sampleRate: Double, amount: Double) {
        n = sampleRate > 50_000 ? 2048 : 1024
        hop = n / 4
        window = periodicHann(n)
        floorGain = Float(pow(10, -30 * min(max(amount, 0), 1) / 20))
        noiseFrames = max(8, Int((1.5 * sampleRate / Double(hop)).rounded()))
    }

    var bins: Int { n / 2 + 1 }
    var history: Int { (noiseFrames + smoothFrames + gainFrames + 2) * hop + n }
    var lookahead: Int { n }

    func process(_ input: Signal, outputStart os: Int64, count: Int) -> Signal {
        let H = Int64(hop), inStart = os - Int64(history)
        let fLo = floorDiv(os - Int64(n), H) + 1, fHi = floorDiv(os + Int64(count) - 1, H)
        guard count > 0, fLo <= fHi, let fft = RealFFT(n: n) else { return input.slice(history, count) }
        let gLo = fLo - Int64(gainFrames - 1)
        let pLo = gLo - Int64(noiseFrames - 1) - Int64(smoothFrames - 1)
        let F = Int(fHi - pLo + 1), B = bins, half = n / 2
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half), im = re

        func load(_ src: [Float], _ f: Int64) {
            let base = Int(f * H - inStart)
            for j in 0..<n {
                let k = base + j
                frame[j] = k >= 0 && k < src.count ? src[k] * window[j] : 0
            }
        }

        // 1. Power of the channel average, every frame from pLo.
        let mono = input.monoMix().channels[0]
        var power = [Float](repeating: 0, count: F * B)
        var silent = [Bool](repeating: false, count: F)
        for i in 0..<F {
            load(mono, pLo + Int64(i))
            fft.forward(frame, &re, &im)
            let r = i * B
            power[r] = re[0] * re[0]
            power[r + half] = im[0] * im[0]
            var sum = power[r] + power[r + half]
            for k in 1..<half {
                let p = re[k] * re[k] + im[k] * im[k]
                power[r + k] = p
                sum += p
            }
            silent[i] = sum == 0
        }

        // 2. Smoothed power (mean of the last `smoothFrames` non-silent frames; +inf if none).
        let s0 = smoothFrames - 1
        var smooth = [Float](repeating: .infinity, count: F * B)
        for i in s0..<F {
            var used = 0
            var acc = [Float](repeating: 0, count: B)
            for j in (i - s0)...i where !silent[j] {
                used += 1
                for k in 0..<B { acc[k] += power[j * B + k] }
            }
            guard used > 0 else { continue }
            let inv = 1 / Float(used)
            for k in 0..<B { smooth[i * B + k] = acc[k] * inv }
        }

        // 3. Noise = sliding per-bin minimum of `smooth` over `noiseFrames` (van Herk / Gil–Werman,
        //    exact), for the frames that need raw gains.
        let M = noiseFrames
        let firstGain = Int(gLo - pLo)              // = s0 + M − 1
        let a0 = firstGain - M + 1                   // first smoothed row inside a window
        let L = F - a0
        var pre = [Float](repeating: 0, count: L * B), suf = pre
        for t in 0..<L {
            let src = (a0 + t) * B
            if t % M == 0 {
                for k in 0..<B { pre[t * B + k] = smooth[src + k] }
            } else {
                for k in 0..<B { pre[t * B + k] = min(pre[(t - 1) * B + k], smooth[src + k]) }
            }
        }
        for t in stride(from: L - 1, through: 0, by: -1) {
            let src = (a0 + t) * B
            if t == L - 1 || (t + 1) % M == 0 {
                for k in 0..<B { suf[t * B + k] = smooth[src + k] }
            } else {
                for k in 0..<B { suf[t * B + k] = min(suf[(t + 1) * B + k], smooth[src + k]) }
            }
        }

        // 4. Raw gains for frames gLo…fHi.
        let G = F - firstGain
        var gain = [Float](repeating: 1, count: G * B)
        for g in 0..<G {
            let i = firstGain + g, t = i - M + 1 - a0   // window [t, t + M − 1] in pre/suf rows
            for k in 0..<B {
                let noise = min(suf[t * B + k], pre[(t + M - 1) * B + k])
                let p = power[i * B + k]
                guard noise.isFinite else { continue }
                let v = p > 1e-30 ? 1 - overSubtraction * bias * noise / p : 0
                gain[g * B + k] = max(floorGain, min(1, v))
            }
        }

        // 5. Smooth gains (3 frames × 3 bins), filter each channel, overlap-add.
        var out = Signal.zeros(channels: input.channelCount, count: count)
        let norm = 1 / (1.5 * fft.roundTripScale)
        var g = [Float](repeating: 1, count: B)
        var y = [Float](repeating: 0, count: n)
        for f in fLo...fHi {
            let gi = Int(f - gLo)
            for k in 0..<B {
                var acc: Float = 0, used: Float = 0
                for d in 0..<gainFrames {
                    let row = (gi - d) * B
                    for kk in max(0, k - 1)...min(B - 1, k + 1) { acc += gain[row + kk]; used += 1 }
                }
                g[k] = acc / used
            }
            let dst = Int(f * H - os)
            let lo = max(0, -dst), hi = min(n, count - dst)
            guard lo < hi else { continue }
            for c in 0..<input.channelCount {
                load(input.channels[c], f)
                fft.forward(frame, &re, &im)
                re[0] *= g[0]
                im[0] *= g[half]
                for k in 1..<half { re[k] *= g[k]; im[k] *= g[k] }
                fft.inverse(re, im, &y)
                for j in lo..<hi { out.channels[c][dst + j] += y[j] * window[j] * norm }
            }
        }
        return out
    }
}

// MARK: Leveling

/// Volume leveling: rides the gain toward −20 dBFS RMS with ratio 3:1, at most ±12 dB, from a
/// centred 400 ms RMS window; the gain curve is averaged over 200 ms. Passages under −50 dBFS RMS
/// get no boost (noise stays down). Parameters are WizRec's own until AU1 [inf].
struct Leveler: AudioProcessor {
    let win: Int
    let smooth: Int
    let targetDB = -20.0, ratio = 3.0, maxBoostDB = 12.0, maxCutDB = 12.0, gateDB = -50.0

    init(sampleRate: Double) {
        win = max(2, Int((0.4 * sampleRate).rounded()))
        smooth = max(2, Int((0.2 * sampleRate).rounded()))
    }

    var history: Int { win / 2 + smooth / 2 + 1 }
    var lookahead: Int { win / 2 + smooth / 2 + 1 }

    /// Gain in dB for an RMS level in dBFS.
    func gainDB(level: Double) -> Double {
        let g = (targetDB - level) * (1 - 1 / ratio)
        if level < gateDB { return min(0, max(-maxCutDB, g)) }
        return min(maxBoostDB, max(-maxCutDB, g))
    }

    func process(_ input: Signal, outputStart: Int64, count: Int) -> Signal {
        let mono = input.monoMix().channels[0]
        let L = mono.count
        var energy = [Double](repeating: 0, count: L + 1)
        for i in 0..<L { energy[i + 1] = energy[i] + Double(mono[i]) * Double(mono[i]) }
        let h = history, sh = smooth / 2
        let gLo = h - sh, gHi = min(L, h + count + sh)
        guard gLo >= 0, gHi > gLo else { return input.slice(h, count) }
        var gsum = [Double](repeating: 0, count: gHi - gLo + 1)
        for i in gLo..<gHi {
            let a = max(0, i - win / 2), b = min(L, i + win / 2)
            let ms = b > a ? (energy[b] - energy[a]) / Double(b - a) : 0
            let level = ms > 1e-12 ? 10 * log10(ms) : -120
            gsum[i - gLo + 1] = gsum[i - gLo] + pow(10, gainDB(level: level) / 20)
        }
        var out = Signal.zeros(channels: input.channelCount, count: count)
        for j in 0..<count {
            let i = h + j
            let a = max(gLo, i - sh), b = min(gHi, i + sh)
            let g = b > a ? Float((gsum[b - gLo] - gsum[a - gLo]) / Double(b - a)) : 1
            for c in 0..<input.channelCount { out.channels[c][j] = input.channels[c][i] * g }
        }
        return out
    }
}

// MARK: Pitch

/// Pitch shift by `semitones` with the duration unchanged: 40 ms Hann grains every 10 ms on the
/// absolute output grid, each resampled by 2^(semitones/12) around its own centre (linear
/// interpolation) and overlap-added. Simple and seam-free; some grain roughness on tonal material.
struct PitchShifter: AudioProcessor {
    let ratio: Double
    let n: Int
    let hop: Int
    let window: [Float]

    init(sampleRate: Double, semitones: Double) {
        ratio = pow(2, semitones / 12)
        n = max(64, 4 * Int((0.04 * sampleRate / 4).rounded()))
        hop = n / 4
        window = periodicHann(n)
    }

    private var reach: Int { Int((Double(n) / 2 * ratio).rounded(.up)) + 2 }
    var history: Int { n / 2 + hop + reach }
    var lookahead: Int { n / 2 + hop + reach }

    func process(_ input: Signal, outputStart os: Int64, count: Int) -> Signal {
        let H = Int64(hop), half = n / 2, inStart = os - Int64(history)
        var out = Signal.zeros(channels: input.channelCount, count: count)
        let fLo = floorDiv(os - Int64(half), H), fHi = floorDiv(os + Int64(count) + Int64(half), H)
        guard count > 0, fLo <= fHi else { return out }
        for f in fLo...fHi {
            let c = f * H
            let dst = Int(c - Int64(half) - os)
            let lo = max(0, -dst), hi = min(n, count - dst)
            guard lo < hi else { continue }
            let centre = Double(c - inStart)
            for ch in 0..<input.channelCount {
                input.channels[ch].withUnsafeBufferPointer { s in
                    out.channels[ch].withUnsafeMutableBufferPointer { d in
                        for u in lo..<hi {
                            let pos = centre + Double(u - half) * ratio
                            let i0 = Int(pos.rounded(.down))
                            guard i0 >= 0, i0 + 1 < s.count else { continue }
                            let fr = Float(pos - Double(i0))
                            let x = s[i0] + (s[i0 + 1] - s[i0]) * fr
                            d[dst + u] += x * window[u] * 0.5
                        }
                    }
                }
            }
        }
        return out
    }
}
