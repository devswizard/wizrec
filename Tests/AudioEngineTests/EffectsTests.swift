import CoreMedia
import Foundation
import MediaEngine
import Testing
import TSCProjKit
@testable import AudioEngine

// AUD-3: WizRec's own audio effects, selected by `effectName`.

private func effect(_ name: String, _ params: [String: Any] = [:]) -> [String: Any] {
    ["effectName": name, "bypassed": false, "category": "categoryAudioEffects", "parameters": params]
}

/// White noise (deterministic LCG), uniform in ±1.
private struct Noise {
    var seed: UInt64
    mutating func next() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(Int64(bitPattern: seed) >> 11) / Double(1 << 52)
    }
}

/// One-clip project on `src`, with `effects`, rendered over its whole length (48 kHz, mono source).
private func renderOne(_ u: URL, seconds: Double, effects: [[String: Any]]) async throws -> [Float] {
    let p = try P.project(tracks: [P.track(0, [P.clip("AMFile", id: 1, src: 1, start: 0, duration: sec(seconds),
                                                      effects: effects)])],
                          sources: [P.source(1, u)])
    return try await P.mixer(p).render(0 ..< sec(seconds)).channels[0]
}

@Test func effectNamesMapToKinds() {
    #expect(AudioEffectKind(effectName: "VSTEffect-DFN3NoiseRemoval") == .noiseRemoval)
    #expect(AudioEffectKind(effectName: "NoiseReduction") == .noiseRemoval)
    #expect(AudioEffectKind(effectName: "WinCompression") == .compression)
    #expect(AudioEffectKind(effectName: "VolumeLeveling") == .leveling)
    #expect(AudioEffectKind(effectName: "DynamicsProcessor") == .leveling)
    #expect(AudioEffectKind(effectName: "Emphasize") == .emphasize)
    #expect(AudioEffectKind(effectName: "Pitch") == .pitch)
    #expect(AudioEffectKind(effectName: "DropShadow") == .passThrough)
}

@Test func realFFTRoundTrips() throws {
    let fft = try #require(RealFFT(n: 1024))
    var noise = Noise(seed: 3)
    let x = (0..<1024).map { _ in Float(noise.next()) }
    var re = [Float](repeating: 0, count: 512), im = re, y = x
    fft.forward(x, &re, &im)
    fft.inverse(re, im, &y)
    let err = zip(x, y).map { abs($0 - $1 / fft.roundTripScale) }.max() ?? 1
    #expect(err < 1e-5)
}

@Test func noiseRemovalCutsNoiseAndKeepsTheTone() async throws {
    let dir = try Synth.tempDir()
    let u = dir.appendingPathComponent("noisy.wav")
    // White noise (amp 0.03) throughout; 1 kHz tone bursts (amp 0.3) like speech with pauses:
    // on 0.4 s / off 0.4 s from 2 s. (A steady tone would be tracked as noise, as in any
    // minimum-statistics denoiser.)
    var noise = Noise(seed: 11)
    let rate = 48_000, seconds = 5.0
    let n = (0 ..< Int(seconds) * rate).map { _ in Float(0.03 * noise.next()) }
    let on = { (i: Int) -> Bool in let t = Double(i) / Double(rate); return t >= 2 && (t - 2).truncatingRemainder(dividingBy: 0.8) < 0.4 }
    let sine = { (i: Int) in Float(0.3 * sin(2 * Double.pi * 1000 * Double(i) / Double(rate))) }
    try Synth.wav(u, rate: rate, channels: 1, frames: n.count) { _, i in n[i] + (on(i) ? sine(i) : 0) }
    let dry = try await renderOne(u, seconds: seconds, effects: [])
    let wet = try await renderOne(u, seconds: seconds, effects: [effect("VSTEffect-DFN3NoiseRemoval",
                                                                        ["Amount": 0.8, "Bypass": 0.0])])
    func cut(_ a: Double, _ b: Double) -> Double { 20 * log10(rms(wet[idx(a) ..< idx(b)]) / rms(dry[idx(a) ..< idx(b)])) }
    // Noise only, before the bursts and in a pause between them.
    #expect(cut(1, 1.9) < -10, "noise cut \(cut(1, 1.9)) dB")
    #expect(cut(3.25, 3.55) < -10, "pause cut \(cut(3.25, 3.55)) dB")
    // Burst interiors: tone amplitude within 1 dB; residual well under the input noise.
    for (a, b) in [(2.85, 3.15), (3.65, 3.95), (4.45, 4.75)] {
        let r = idx(a) ..< idx(b)
        let amp = 2 * r.reduce(0.0) { $0 + Double(wet[$1]) * Double(sine($1)) / 0.3 } / Double(r.count)
        #expect(abs(20 * log10(amp / 0.3)) < 1, "tone at \(a): \(amp)")
        let resid = r.map { wet[$0] - sine($0) * Float(amp / 0.3) }
        #expect(rms(resid[...]) < 0.5 * rms(n[r]), "residual at \(a): \(rms(resid[...])) vs \(rms(n[r]))")
    }
    // Bypass (plug-in level) passes the clip through untouched.
    let byp = try await renderOne(u, seconds: 2, effects: [effect("VSTEffect-DFN3NoiseRemoval",
                                                                  ["Amount": 0.8, "Bypass": 1.0])])
    #expect(byp == Array(dry[0 ..< idx(2)]))
}

@Test func effectsStayChunkSeamless() async throws {
    let dir = try Synth.tempDir()
    let u = dir.appendingPathComponent("n.wav")
    var noise = Noise(seed: 5)
    try Synth.wav(u, rate: 48_000, channels: 1, frames: 48_000 * 4) { _, i in
        Float(0.05 * noise.next() + 0.2 * sin(2 * Double.pi * 300 * Double(i) / 48_000))
    }
    let effects = [effect("VSTEffect-DFN3NoiseRemoval", ["Amount": 0.6]), effect("VolumeLeveling"),
                   effect("Pitch", ["pitch": 3.0])]
    let p = try P.project(tracks: [P.track(0, [P.clip("AMFile", id: 1, src: 1, start: sec(0.3), duration: sec(1.5),
                                                      mediaStart: sec(0.5), effects: effects)])],
                          sources: [P.source(1, u)])
    let whole = try await P.mixer(p).render(0 ..< sec(2))
    let m = P.mixer(p)
    var joined: [Float] = []
    let cuts: [Int64] = [0, sec(0.77) + 3, sec(1.2), sec(1.51), sec(2)]
    for i in 0 ..< cuts.count - 1 { joined += try await m.render(cuts[i] ..< cuts[i + 1]).channels[0] }
    #expect(joined == whole.channels[0])
    #expect(rms(whole.channels[0][idx(0.5) ..< idx(1.7)]) > 0.05)
}

@Test func levelingBoostsQuietAndCutsLoud() async throws {
    let dir = try Synth.tempDir()
    // −40 dBFS RMS → +13.3 dB wanted, capped at +12; −6 dBFS RMS → −9.33 dB.
    for (rmsDB, wantDB) in [(-40.5, 12.0), (-6.0, -28.0 / 3)] {
        let amp = pow(10, rmsDB / 20) * 2.squareRoot()
        let u = dir.appendingPathComponent("l\(Int(-rmsDB)).wav")
        try Synth.wav(u, rate: 48_000, channels: 1, frames: 48_000 * 3, Synth.sine(freq: 500, amp: amp, rate: 48_000))
        let x = try await renderOne(u, seconds: 3, effects: [effect("VolumeLeveling")])
        let got = 20 * log10(rms(x[idx(0.8) ..< idx(2.2)]) / (amp / 2.squareRoot()))
        #expect(abs(got - wantDB) < 0.2, "level \(rmsDB): \(got) dB")
    }
}

@Test func pitchShiftsFrequencyKeepingDuration() async throws {
    let dir = try Synth.tempDir()
    let u = dir.appendingPathComponent("p.wav")
    try Synth.wav(u, rate: 48_000, channels: 1, frames: 48_000 * 4, Synth.sine(freq: 440, amp: 0.5, rate: 48_000))
    // Short clips: the band-limited resampler is slow in debug builds.
    // `pitch` is in cents (AU1 default −200 = two semitones down).
    for (cents, want) in [(1200.0, 880.0), (-1200.0, 220.0), (-200.0, 440 * pow(2, -2.0 / 12))] {
        let p = try P.project(tracks: [P.track(0, [P.clip("AMFile", id: 1, src: 1, start: sec(0.25), duration: sec(1),
                                                          effects: [effect("Pitch", ["pitch": cents, "effectBlend": 100.0,
                                                                                     "smoothness": 50.0, "tightness": 50.0])])])],
                              sources: [P.source(1, u)])
        let x = try await P.mixer(p).render(0 ..< sec(1.5)).channels[0]
        #expect(abs(frequency(x[idx(0.35) ..< idx(1.15)], rate: 48_000) - want) < want * 0.01, "\(cents) cents")
        #expect(x[0 ..< idx(0.25)].allSatisfy { $0 == 0 })
        #expect(x[idx(1.25)...].allSatisfy { $0 == 0 })
        #expect(rms(x[idx(0.35) ..< idx(1.15)]) > 0.2)
    }
}

@Test func emphasizeDucksOtherTracks() async throws {
    let dir = try Synth.tempDir()
    let a = dir.appendingPathComponent("a.wav"), b = dir.appendingPathComponent("b.wav")
    try Synth.wav(a, rate: 48_000, channels: 1, frames: 48_000 * 5, Synth.sine(freq: 440, amp: 0.4, rate: 48_000))
    try Synth.wav(b, rate: 48_000, channels: 1, frames: 48_000 * 5, Synth.sine(freq: 1000, amp: 0.2, rate: 48_000))
    // AU1 shape: emphasizeAmount, ramp position 0 (inside the clip), ramp times in ticks (0.25 s).
    let p = try P.project(tracks: [
        P.track(0, [P.clip("AMFile", id: 1, src: 1, start: 0, duration: sec(4))]),
        P.track(1, [P.clip("AMFile", id: 2, src: 2, start: sec(1.5), duration: sec(1),
                           effects: [effect("Emphasize", ["emphasizeAmount": 0.5, "emphasizeRampPosition": 0,
                                                          "emphasizeRampInTime": sec(0.25),
                                                          "emphasizeRampOutTime": sec(0.25)])])]),
    ], sources: [P.source(1, a), P.source(2, b)])
    let x = try await P.mixer(p).render(0 ..< sec(4)).channels[0]
    let music = { (i: Int) in Float(0.4 * sin(2 * Double.pi * 440 * Double(i) / 48_000)) }
    let voice = { (i: Int) in Float(0.2 * sin(2 * Double.pi * 1000 * Double(i - idx(1.5)) / 48_000)) }
    // Before the clip: untouched. Fully ducked (1 − 0.5) between the inside ramps.
    #expect(x[idx(1.4)] == music(idx(1.4)))
    let duck: Float = 0.5
    for i in stride(from: idx(1.76), to: idx(2.24), by: 997) {
        #expect(abs(x[i] - (music(i) * duck + voice(i))) < 1e-5)
    }
    // Halfway through the ramp in and the ramp out (inside the clip).
    #expect(abs(x[idx(1.625)] - (music(idx(1.625)) * 0.75 + voice(idx(1.625)))) < 1e-4)
    #expect(abs(x[idx(2.375)] - (music(idx(2.375)) * 0.75 + voice(idx(2.375)))) < 1e-4)
    // After the clip: untouched again.
    #expect(x[idx(2.6)] == music(idx(2.6)))
}

@Test func emphasizeDefaultRampsShareAShortClip() {
    // Two 1 s default ramps inside a 1 s clip share it: 0.5 s each.
    let d = Duck(track: 0, lo: 0, hi: Double(sec(1)), gain: 0.2, rampIn: Double(sec(1)), rampOut: Double(sec(1)), inside: true)
    #expect(abs(d.factor(at: Double(sec(0.25))) - 0.6) < 1e-9)
    #expect(abs(d.factor(at: Double(sec(0.5))) - 0.2) < 1e-9)
    #expect(d.factor(at: Double(sec(1))) == 1)
    let e = AEffect(name: "Emphasize", parameters: [:])
    #expect(abs(e.duckGain - 0.2) < 1e-12)
    #expect(e.emphasizeRampIn == 705_600_000 && e.emphasizeRampOut == 705_600_000 && e.emphasizeRampsInside)
}

/// Amplitude of the `freq` component of `x` (single-bin DFT).
private func amplitude(_ x: ArraySlice<Float>, freq: Double, rate: Double = 48_000) -> Double {
    var re = 0.0, im = 0.0
    for (k, v) in x.enumerated() {
        let ph = 2 * Double.pi * freq * Double(k) / rate
        re += Double(v) * cos(ph); im -= Double(v) * sin(ph)
    }
    return 2 * (re * re + im * im).squareRoot() / Double(x.count)
}

@Test func pitchEffectBlendMixesDryAndShifted() async throws {
    let dir = try Synth.tempDir()
    let u = dir.appendingPathComponent("pb.wav")
    try Synth.wav(u, rate: 48_000, channels: 1, frames: 48_000 * 2, Synth.sine(freq: 440, amp: 0.5, rate: 48_000))
    func render(_ blend: Double) async throws -> [Float] {
        let p = try P.project(tracks: [P.track(0, [P.clip("AMFile", id: 1, src: 1, start: 0, duration: sec(1),
                                                          effects: [effect("Pitch", ["pitch": 1200.0, "effectBlend": blend])])])],
                              sources: [P.source(1, u)])
        return try await P.mixer(p).render(0 ..< sec(1)).channels[0]
    }
    let half = try await render(50)
    let win = half[idx(0.2) ..< idx(0.8)]
    #expect(abs(amplitude(win, freq: 440) - 0.25) < 0.02)
    #expect(abs(amplitude(win, freq: 880) - 0.25) < 0.03)
    // Blend 0 = the dry signal, sample for sample.
    let dry = try await render(0)
    #expect(dry[idx(0.1) ..< idx(0.9)].indices.allSatisfy { i in
        abs(dry[i] - Float(0.5 * sin(2 * Double.pi * 440 * Double(i) / 48_000))) < 1e-4 })
}

@Test func compressionUsesWinCompressionDefaults() async throws {
    let dir = try Synth.tempDir()
    // AU1 defaults: ratio 10, threshold −20 dBFS, gain (make-up) +9 dB, attack 0, release 3500 ms.
    let params: [String: Any] = ["ratio": 10.0, "threshold": -20.0, "gain": 9.0, "attack": 0.0, "release": 3500.0, "preset": 1]
    // Loud sine, peak −6 dBFS: (−6 + 20) × 0.9 = 12.6 dB reduction, + 9 dB → −3.6 dB.
    // Quiet sine, peak −26 dBFS (under the threshold): + 9 dB.
    for (peakDB, wantDB) in [(-6.0, -3.6), (-26.0, 9.0)] {
        let amp = pow(10, peakDB / 20)
        let u = dir.appendingPathComponent("c\(Int(-peakDB)).wav")
        try Synth.wav(u, rate: 48_000, channels: 1, frames: 48_000 * 2, Synth.sine(freq: 500, amp: amp, rate: 48_000))
        let x = try await renderOne(u, seconds: 2, effects: [effect("WinCompression", params)])
        let got = 20 * log10(rms(x[idx(0.5) ..< idx(1.5)]) / (amp / 2.squareRoot()))
        #expect(abs(got - wantDB) < 0.15, "peak \(peakDB): \(got) dB")
    }
}

@Test func compressionReleasesLinearly() {
    // Release 1000 ms at 1 kHz: 20 dB per 1000 samples. One loud sample (peak 0 dBFS, threshold −20,
    // ratio ∞-ish 1000 → ≈ 20 dB) then silence: reduction falls 2 dB per 100 samples.
    let c = Compressor(sampleRate: 1_000, thresholdDB: -20, ratio: 1_000, makeupDB: 0, attackMS: 0, releaseMS: 1_000)
    let h = c.history
    var input = Signal.zeros(channels: 1, count: h + 1_200)
    input.channels[0][h] = 1
    for k in stride(from: 100, to: 1_200, by: 100) { input.channels[0][h + k] = 1e-3 }   // probes (−60 dBFS)
    let out = c.process(input, outputStart: Int64(h), count: 1_200)
    for k in stride(from: 100, to: 1_000, by: 100) {
        let grDB = -20 * log10(Double(out.channels[0][k]) / 1e-3)
        let want = 20 * (1 - 1.0 / 1_000) - 2 * Double(k) / 100
        #expect(abs(grDB - want) < 0.01, "k \(k): \(grDB)")
    }
    #expect(abs(Double(out.channels[0][1_100]) - 1e-3) < 1e-9)
}

@Test func clippingIsCountedNotLimited() async throws {
    let dir = try Synth.tempDir()
    let u = dir.appendingPathComponent("hot.wav")
    try Synth.wav(u, rate: 48_000, channels: 1, frames: 48_000, Synth.sine(freq: 100, amp: 0.8, rate: 48_000))
    let p = try P.project(tracks: [P.track(0, [P.clip("AMFile", id: 1, src: 1, start: 0, duration: sec(1),
                                                      attributes: ["gain": 2.0])])],
                          sources: [P.source(1, u)])
    let m = P.mixer(p)
    let x = try await m.render(0 ..< sec(1)).channels[0]
    #expect(x.max() == 1 && x.min() == -1)
    let clipped = await m.clippedSamples
    let want = 2 * x.filter { abs($0) == 1 }.count
    #expect(clipped == want && clipped > 0)
}
