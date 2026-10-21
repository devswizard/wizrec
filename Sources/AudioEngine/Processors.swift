// WizRec's own audio effect DSP (AUD-3): spectral noise reduction, compression and leveling. (Pitch is a
// placement step: resample + WSOLA in Mixer.swift.)
//
// Every processor has finite memory (`AudioProcessor`, Processing.swift): its output at sample i
// depends only on input samples [i − history, i + lookahead], and analysis frames sit on a grid
// anchored at absolute sample 0. Blocks are therefore deterministic, and neighbouring blocks agree
// on every shared frame, so the effect has no seams. No recursive (IIR) state anywhere.
// Written from textbook methods (spectral subtraction with minimum-statistics noise tracking,
// windowed-RMS gain riding); no third-party code.

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
    private let even: UnsafeMutablePointer<Float>
    private let odd: UnsafeMutablePointer<Float>

    init?(n: Int) {
        guard n >= 32, n % 2 == 0,
              let f = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD) else { return nil }
        guard let i = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .INVERSE) else {
            vDSP_DFT_DestroySetup(f)
            return nil
        }
        self.n = n; fwd = f; inv = i
        even = .allocate(capacity: n / 2); even.initialize(repeating: 0, count: n / 2)
        odd = .allocate(capacity: n / 2); odd.initialize(repeating: 0, count: n / 2)
        var x = [Float](repeating: 0, count: n); x[0] = 1
        var re = [Float](repeating: 0, count: n / 2), im = re
        forward(x, &re, &im)
        inverse(re, im, &x)
        roundTripScale = x[0] == 0 ? 1 : x[0]
    }

    deinit {
        vDSP_DFT_DestroySetup(fwd)
        vDSP_DFT_DestroySetup(inv)
        even.deallocate()
        odd.deallocate()
    }

    /// Spectrum of `x` (n samples) into `re`/`im` (n/2 each, packed).
    func forward(_ x: UnsafePointer<Float>, _ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>) {
        // De-interleave even/odd samples (a plain copy).
        var split = DSPSplitComplex(realp: even, imagp: odd)
        x.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { (c: UnsafePointer<DSPComplex>) -> Void in
            vDSP_ctoz(c, 2, &split, 1, vDSP_Length(n / 2))
        }
        vDSP_DFT_Execute(fwd, even, odd, re, im)
    }

    /// Time signal (n samples, × `roundTripScale`) of a packed spectrum.
    func inverse(_ re: UnsafePointer<Float>, _ im: UnsafePointer<Float>, _ out: UnsafeMutablePointer<Float>) {
        vDSP_DFT_Execute(inv, re, im, even, odd)
        // Re-interleave (a plain copy).
        var split = DSPSplitComplex(realp: even, imagp: odd)
        out.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { (c: UnsafeMutablePointer<DSPComplex>) -> Void in
            vDSP_ztoc(&split, 1, c, 2, vDSP_Length(n / 2))
        }
    }

    func forward(_ x: [Float], _ re: inout [Float], _ im: inout [Float]) {
        x.withUnsafeBufferPointer { xp in
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    guard let xb = xp.baseAddress, let rb = rp.baseAddress, let ib = ip.baseAddress else { return }
                    forward(xb, rb, ib)
                }
            }
        }
    }

    func inverse(_ re: [Float], _ im: [Float], _ out: inout [Float]) {
        re.withUnsafeBufferPointer { rp in
            im.withUnsafeBufferPointer { ip in
                out.withUnsafeMutableBufferPointer { op in
                    guard let rb = rp.baseAddress, let ib = ip.baseAddress, let ob = op.baseAddress else { return }
                    inverse(rb, ib, ob)
                }
            }
        }
    }
}

/// Periodic Hann window: squared copies at a hop of n/4 sum to 1.5.
func periodicHann(_ n: Int) -> [Float] {
    (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
}

/// A scratch matrix of Float rows (row stride padded to 4 floats so every row has the same
/// alignment). Lives for one `process` call.
final class Rows {
    let count: Int
    let stride: Int
    let base: UnsafeMutablePointer<Float>

    init(_ count: Int, width: Int, fill: Float = 0) {
        self.count = count
        stride = (width + 3) & ~3
        base = .allocate(capacity: max(1, count * stride))
        base.initialize(repeating: fill, count: max(1, count * stride))
    }

    deinit { base.deallocate() }

    subscript(_ i: Int) -> UnsafeMutablePointer<Float> { base + i * stride }
}

// MARK: Noise reduction

/// Spectral noise reduction (`Amount` 0–1 → up to 30 dB of attenuation).
///
/// STFT (Hann, 75 % overlap) on the absolute sample grid. The noise spectrum of frame f is the
/// per-bin minimum of the 3-frame-smoothed power over the previous ~1.5 s (minimum statistics,
/// × `bias` ≈ mean noise power), from the channel average; frames of digital silence or before
/// the media start are ignored. Gain per bin = max(floor, 1 − 2·noise/local power), local power
/// = mean over 3 frames × 3 bins (centred); gains are again averaged over 3 frames × 3 bins
/// against musical noise and applied to every channel (stereo image kept).
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
    var overSubtraction: Float = 2
    /// Noise power / minimum of the smoothed power over the window (tuned on white noise:
    /// stationary noise drops ≈ 12 dB at Amount 0.8).
    var bias: Float = 10

    init(sampleRate: Double, amount: Double) {
        n = sampleRate > 50_000 ? 2048 : 1024
        hop = n / 4
        window = periodicHann(n)
        floorGain = Float(pow(10, -30 * min(max(amount, 0), 1) / 20))
        noiseFrames = max(8, Int((1.5 * sampleRate / Double(hop)).rounded()))
    }

    var bins: Int { n / 2 + 1 }
    var history: Int { (noiseFrames + smoothFrames + gainFrames + 2) * hop + n }
    var lookahead: Int { n + hop }

    func process(_ input: Signal, outputStart os: Int64, count: Int) -> Signal {
        let H = Int64(hop), inStart = os - Int64(history)
        let fLo = floorDiv(os - Int64(n), H) + 1, fHi = floorDiv(os + Int64(count) - 1, H)
        guard count > 0, fLo <= fHi, let fft = RealFFT(n: n) else { return input.slice(history, count) }
        let gLo = fLo - Int64(gainFrames - 1)
        let pLo = gLo - Int64(noiseFrames - 1) - Int64(smoothFrames - 1)
        let F = Int(fHi - pLo + 1), B = bins, half = n / 2
        let M = noiseFrames, s0 = smoothFrames - 1
        let firstGain = Int(gLo - pLo)          // = s0 + M − 1
        let a0 = firstGain - M + 1              // first smoothed row inside a noise window (= s0)
        let L = F - a0, G = F - firstGain
        let vB = vDSP_Length(B)

        let frame = Rows(1, width: n), re = Rows(1, width: half), im = Rows(1, width: half), y = Rows(1, width: n)
        let win = Rows(1, width: n)
        for j in 0..<n { win[0][j] = window[j] }

        /// Windowed frame f of `src` (absolute sample f·H; zeros outside the input) into `frame`.
        func load(_ src: UnsafeBufferPointer<Float>, _ f: Int64) {
            let b = Int(f * H - inStart), dst = frame[0]
            if b >= 0, b + n <= src.count, let s = src.baseAddress {
                vDSP_vmul(s + b, 1, win[0], 1, dst, 1, vDSP_Length(n))
            } else {
                for j in 0..<n { let k = b + j; dst[j] = k >= 0 && k < src.count ? src[k] * win[0][j] : 0 }
            }
        }

        // 1. Power of the channel average for frames pLo … fHi + 1 (one extra for the centred
        //    local power). Digital silence or a frame reaching before the content's sample 0
        //    (media start) would drag the minimum down: neither counts as noise.
        let power = Rows(F + 1, width: B)
        var silent = [Bool](repeating: false, count: F + 1)
        let mono = input.monoMix().channels[0]
        mono.withUnsafeBufferPointer { m in
            for i in 0...F {
                load(m, pLo + Int64(i))
                fft.forward(frame[0], re[0], im[0])
                let p = power[i]
                var split = DSPSplitComplex(realp: re[0], imagp: im[0])
                vDSP_zvmags(&split, 1, p, 1, vDSP_Length(half))
                p[0] = re[0][0] * re[0][0]
                p[half] = im[0][0] * im[0][0]
                var sum: Float = 0
                vDSP_sve(p, 1, &sum, vB)
                silent[i] = sum == 0 || (pLo + Int64(i)) * H < 0
            }
        }

        // 2. Smoothed power: mean of the last `smoothFrames` non-silent frames (+inf if none).
        let smooth = Rows(F, width: B, fill: .infinity)
        for i in s0..<F {
            let used = ((i - s0)...i).filter { !silent[$0] }
            guard let first = used.first else { continue }
            let d = smooth[i]
            d.update(from: power[first], count: B)
            for j in used.dropFirst() { vDSP_vadd(d, 1, power[j], 1, d, 1, vB) }
            var inv = 1 / Float(used.count)
            vDSP_vsmul(d, 1, &inv, d, 1, vB)
        }

        // 3. Noise = sliding per-bin minimum of `smooth` over M rows (van Herk / Gil–Werman; exact).
        let pre = Rows(L, width: B), suf = Rows(L, width: B)
        for t in 0..<L {
            if t % M == 0 { pre[t].update(from: smooth[a0 + t], count: B) }
            else { vDSP_vmin(pre[t - 1], 1, smooth[a0 + t], 1, pre[t], 1, vB) }
        }
        for t in Swift.stride(from: L - 1, through: 0, by: -1) {
            if t == L - 1 || (t + 1) % M == 0 { suf[t].update(from: smooth[a0 + t], count: B) }
            else { vDSP_vmin(suf[t + 1], 1, smooth[a0 + t], 1, suf[t], 1, vB) }
        }

        // 3×3 box sum along frequency of `src` into `dst` (edge bins sum 2):
        // dst[k] = (src[k − 1] + src[k]) + src[k + 1], two element-wise adds.
        let inner = vDSP_Length(B - 2)
        func freqSum(_ src: UnsafeMutablePointer<Float>, _ dst: UnsafeMutablePointer<Float>) {
            dst[0] = src[0] + src[1]
            vDSP_vadd(src, 1, src + 1, 1, dst + 1, 1, inner)
            vDSP_vadd(dst + 1, 1, src + 2, 1, dst + 1, 1, inner)
            dst[B - 1] = src[B - 2] + src[B - 1]
        }
        // 1 / (3 · bins summed) per bin.
        let boxNorm = Rows(1, width: B, fill: 1 / 9)
        boxNorm[0][0] = 1 / 6; boxNorm[0][B - 1] = 1 / 6

        // 4. Raw gains for frames gLo … fHi from the centred 3×3 local power.
        let fp = Rows(F + 1, width: B)
        for i in (firstGain - 1)...F { freqSum(power[i], fp[i]) }
        let gain = Rows(G, width: B, fill: 1)
        let local = Rows(1, width: B)
        let k2 = overSubtraction * bias
        for g in 0..<G {
            let i = firstGain + g, t = g
            vDSP_vadd(fp[i - 1], 1, fp[i], 1, local[0], 1, vB)
            vDSP_vadd(local[0], 1, fp[i + 1], 1, local[0], 1, vB)
            vDSP_vmul(local[0], 1, boxNorm[0], 1, local[0], 1, vB)
            let lo = suf[t], hi = pre[t + M - 1], out = gain[g], p = local[0]
            var k = 0
            while k < B {
                defer { k += 1 }
                let noise = hi[k] < lo[k] ? hi[k] : lo[k]           // `min(lo, hi)`
                guard noise.isFinite else { continue }
                let v: Float = p[k] > 1e-30 ? 1 - k2 * noise / p[k] : 0
                let m: Float = v < 1 ? v : 1                         // `min(1, v)`
                out[k] = m >= floorGain ? m : floorGain              // `max(floorGain, m)`
            }
        }

        // 5. Smooth gains (3 frames × 3 bins), filter each channel, overlap-add.
        let gf = Rows(G, width: B)
        for g in 0..<G { freqSum(gain[g], gf[g]) }
        let gs = Rows(1, width: B)
        let wn = Rows(1, width: n)
        var norm = 1 / (1.5 * fft.roundTripScale)
        vDSP_vsmul(win[0], 1, &norm, wn[0], 1, vDSP_Length(n))
        var out = Signal.zeros(channels: input.channelCount, count: count)
        for f in fLo...fHi {
            let gi = Int(f - gLo)
            vDSP_vadd(gf[gi], 1, gf[gi - 1], 1, gs[0], 1, vB)
            vDSP_vadd(gs[0], 1, gf[gi - 2], 1, gs[0], 1, vB)
            vDSP_vmul(gs[0], 1, boxNorm[0], 1, gs[0], 1, vB)
            let dst = Int(f * H - os)
            let lo = max(0, -dst), hi = min(n, count - dst)
            guard lo < hi else { continue }
            let g = gs[0]
            for c in 0..<input.channelCount {
                input.channels[c].withUnsafeBufferPointer { load($0, f) }
                fft.forward(frame[0], re[0], im[0])
                let r = re[0], m = im[0]
                r[0] *= g[0]
                m[0] *= g[half]
                vDSP_vmul(r + 1, 1, g + 1, 1, r + 1, 1, vDSP_Length(half - 1))
                vDSP_vmul(m + 1, 1, g + 1, 1, m + 1, 1, vDSP_Length(half - 1))
                fft.inverse(r, m, y[0])
                out.channels[c].withUnsafeMutableBufferPointer { o in
                    guard let ob = o.baseAddress else { return }
                    let d = ob + dst + lo
                    vDSP_vma(y[0] + lo, 1, wn[0] + lo, 1, d, 1, d, 1, vDSP_Length(hi - lo))
                }
            }
        }
        return out
    }
}

// MARK: Leveling

/// Volume leveling: rides the gain toward −20 dBFS RMS with ratio 3:1, at most ±12 dB, from a
/// centred 400 ms RMS window; the gain curve is averaged over 200 ms. Passages under −50 dBFS RMS
/// get no boost (noise stays down). Only for volume-leveling effect names of older projects:
/// Camtasia 2026.2.3 has no Volume Leveling item (audio.md §3.1) [obs]. Parameters are WizRec's own.
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

// MARK: Compression

/// Downward compressor for `WinCompression` (audio.md §3.2): above `thresholdDB` (dBFS, linked
/// sample peak of all channels) the level is reduced by `ratio`; `makeupDB` is added afterwards.
/// Finite memory by construction: the gain reduction at sample i is
/// `max over j in [i − W, i] of (want_j − slope · (i − j))`, i.e. instant peak attack and a
/// linear release of 20 dB per `releaseMS` [WizRec], over a window W long enough for the largest
/// reduction (levels up to +24 dBFS) to recover. A non-zero `attackMS` averages the reduction
/// over that many trailing samples [WizRec]. Parameter meanings are [inf]; the exact curve needs
/// a reference export.
struct Compressor: AudioProcessor {
    let thresholdDB: Double
    let ratio: Double
    let makeupDB: Double
    /// Release slope, dB per sample (∞ for release 0).
    let slope: Double
    /// Release window W, samples.
    let window: Int
    /// Attack averaging length, samples (0 = instant).
    let attack: Int

    /// Level (dBFS) beyond which no extra reduction is modelled.
    static let maxLevelDB = 24.0

    init(sampleRate: Double, thresholdDB: Double, ratio: Double, makeupDB: Double, attackMS: Double, releaseMS: Double) {
        self.thresholdDB = thresholdDB.isFinite ? thresholdDB : -20
        self.ratio = ratio.isFinite ? max(1, ratio) : 1
        self.makeupDB = makeupDB.isFinite ? min(max(makeupDB, -60), 60) : 0
        let rel = releaseMS.isFinite ? max(0, releaseMS) : 0
        let releaseSamples = rel / 1000 * sampleRate
        slope = releaseSamples > 0 ? 20 / releaseSamples : .infinity
        let maxGR = max(0, (Self.maxLevelDB - self.thresholdDB) * (1 - 1 / self.ratio))
        window = slope.isFinite ? Int((maxGR / slope).rounded(.up)) : 0
        attack = attackMS.isFinite ? max(0, Int((attackMS / 1000 * sampleRate).rounded())) : 0
    }

    var history: Int { window + max(0, attack - 1) }
    var lookahead: Int { 0 }

    /// Wanted gain reduction (dB, ≥ 0) for a linear peak level.
    func want(_ peak: Float) -> Double {
        guard peak > 0 else { return 0 }
        let l = min(20 * log10(Double(peak)), Self.maxLevelDB)
        return max(0, (l - thresholdDB) * (1 - 1 / ratio))
    }

    func process(_ input: Signal, outputStart: Int64, count: Int) -> Signal {
        let L = input.count
        let h = history
        var out = Signal.zeros(channels: input.channelCount, count: count)
        guard count > 0, L >= h + count else { return out }
        // Pointer loops throughout (AUD12-2): same arithmetic, in the same order, as the textbook
        // version, without per-element bounds checks and generic `min`/`max` calls.
        let C = input.channelCount
        let want = UnsafeMutablePointer<Double>.allocate(capacity: L)
        let gr = UnsafeMutablePointer<Double>.allocate(capacity: L)
        let dq = UnsafeMutablePointer<Int>.allocate(capacity: L)
        defer { want.deallocate(); gr.deallocate(); dq.deallocate() }
        gr.initialize(repeating: 0, count: L)
        // Linked detector: the channels' largest magnitude.
        let peak = UnsafeMutablePointer<Float>.allocate(capacity: L)
        defer { peak.deallocate() }
        peak.initialize(repeating: 0, count: L)
        for c in 0..<C {
            input.channels[c].withUnsafeBufferPointer { (sp: UnsafeBufferPointer<Float>) -> Void in
                guard let x = sp.baseAddress else { return }
                var i = 0
                while i < L {
                    let a = x[i].magnitude
                    if a >= peak[i] { peak[i] = a }   // `max(p, a)`
                    i += 1
                }
            }
        }
        let k = 1 - 1 / ratio, lMax = Self.maxLevelDB, th = thresholdDB
        var i = 0
        while i < L {
            let p = peak[i]
            if p > 0 {
                let db = 20 * log10(Double(p))
                let l = lMax < db ? lMax : db           // `min(db, maxLevelDB)`
                let v = (l - th) * k
                want[i] = v >= 0 ? v : 0                // `max(0, v)`
            } else {
                want[i] = 0
            }
            i += 1
        }
        // Reduction with linear release: monotonic deque of candidates (index), dominated ones dropped.
        let first = h - max(0, attack - 1)   // first index whose reduction is needed (= window)
        let w = window, finite = slope.isFinite, sl = slope
        var head = 0, tail = 0
        i = 0
        while i < L {
            let wi = want[i]
            if wi > 0 {
                while tail > head {
                    let b = dq[tail - 1]
                    guard wi >= want[b] - sl * Double(i - b) else { break }
                    tail -= 1
                }
                dq[tail] = i
                tail += 1
            }
            while tail > head, dq[head] < i - w { head += 1 }
            if i >= first, tail > head {
                let j = dq[head]
                let v = want[j] - (finite ? sl * Double(i - j) : (i == j ? 0 : .infinity))
                gr[i] = v >= 0 ? v : 0
            }
            i += 1
        }
        // Optional attack averaging, then gain.
        let gains = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { gains.deallocate() }
        var kk = 0
        while kk < count {
            let i = h + kk
            var r = gr[i]
            if attack > 1 {
                var s = 0.0
                var j = i - attack + 1
                while j <= i { s += gr[j]; j += 1 }
                r = s / Double(attack)
            }
            gains[kk] = Float(pow(10, (makeupDB - r) / 20))
            kk += 1
        }
        for c in 0..<C {
            input.channels[c].withUnsafeBufferPointer { (sp: UnsafeBufferPointer<Float>) -> Void in
                out.channels[c].withUnsafeMutableBufferPointer { (dp: inout UnsafeMutableBufferPointer<Float>) -> Void in
                    guard let x = sp.baseAddress, let d = dp.baseAddress else { return }
                    var k = 0
                    while k < count { d[k] = x[h + k] * gains[k]; k += 1 }
                }
            }
        }
        return out
    }
}
