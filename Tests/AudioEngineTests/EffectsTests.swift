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
    for (semis, want) in [(12.0, 880.0), (-12.0, 220.0), (7.0, 440 * pow(2, 7.0 / 12))] {
        let p = try P.project(tracks: [P.track(0, [P.clip("AMFile", id: 1, src: 1, start: sec(0.25), duration: sec(1),
                                                          effects: [effect("Pitch", ["pitch": semis])])])],
                              sources: [P.source(1, u)])
        let x = try await P.mixer(p).render(0 ..< sec(1.5)).channels[0]
        #expect(abs(frequency(x[idx(0.35) ..< idx(1.15)], rate: 48_000) - want) < want * 0.01, "\(semis) st")
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
    let p = try P.project(tracks: [
        P.track(0, [P.clip("AMFile", id: 1, src: 1, start: 0, duration: sec(4))]),
        P.track(1, [P.clip("AMFile", id: 2, src: 2, start: sec(1.5), duration: sec(1),
                           effects: [effect("Emphasize", ["Amount": 0.5])])]),
    ], sources: [P.source(1, a), P.source(2, b)])
    let x = try await P.mixer(p).render(0 ..< sec(4)).channels[0]
    let music = { (i: Int) in Float(0.4 * sin(2 * Double.pi * 440 * Double(i) / 48_000)) }
    let voice = { (i: Int) in Float(0.2 * sin(2 * Double.pi * 1000 * Double(i - idx(1.5)) / 48_000)) }
    // Before the ramp: untouched. Inside: track 0 at −12 dB, the emphasised clip at full level.
    #expect(x[idx(1)] == music(idx(1)))
    let duck = Float(pow(10, -12.0 / 20))
    for i in stride(from: idx(1.6), to: idx(2.4), by: 997) {
        #expect(abs(x[i] - (music(i) * duck + voice(i))) < 1e-5)
    }
    // Ramp back up over 0.25 s after the clip.
    #expect(abs(x[idx(2.625)] - music(idx(2.625)) * (1 - (1 - duck) * 0.5)) < 1e-4)
    #expect(x[idx(3)] == music(idx(3)))
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
