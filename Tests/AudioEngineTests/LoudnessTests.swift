import CoreMedia
import Foundation
import MediaEngine
import TestGenKit
import Testing
import TSCProjKit
@testable import AudioEngine

// BS.1770-4 meter checks (EBU Tech 3341-style cases on synthesized signals) and the per-clip
// normalisation rule of docs/specs/audio.md §2.

private func buffer(rate: Double = 48_000, channels: Int, seconds: Double,
                    _ sample: (Int, Int) -> Float) -> PCMBuffer {
    let n = Int(seconds * rate)
    let chans = (0..<channels).map { c in (0..<n).map { sample(c, $0) } }
    return PCMBuffer(format: PCMFormat(sampleRate: rate, channels: channels),
                     startTime: .zero, frameCount: n, channels: chans)
}

private func sine(dBFS: Double, freq: Double = 997, rate: Double = 48_000) -> (Int, Int) -> Float {
    let a = pow(10, dBFS / 20)
    return { _, i in Float(a * sin(2 * Double.pi * freq * Double(i) / rate)) }
}

@Test func stereoSineReadsItsPeakLevelInLUFS() {
    // Tech 3341 case 1/2: a 1 kHz stereo sine at −23 / −33 dBFS reads −23 / −33 LUFS (±0.1).
    for level in [-23.0, -33.0] {
        let b = buffer(channels: 2, seconds: 10, sine(dBFS: level))
        #expect(abs(Loudness.integratedLUFS(b) - level) < 0.1)
    }
    // 44.1 kHz too (coefficients come from the analogue prototype).
    let b44 = buffer(rate: 44_100, channels: 2, seconds: 10, sine(dBFS: -23, rate: 44_100))
    #expect(abs(Loudness.integratedLUFS(b44) + 23) < 0.1)
}

@Test func monoWeightsOneChannelOnce() {
    // BS.1770 mono: one channel, weight 1 → 3.01 dB below the same sine in stereo.
    let b = buffer(channels: 1, seconds: 10, sine(dBFS: -20))
    #expect(abs(Loudness.integratedLUFS(b) - (-20 - 3.0103)) < 0.1)
    // Dual-mono weighting (WizRec's own measurement of mono sources) reads like stereo.
    var m = LoudnessMeter(sampleRate: 48_000, channels: 1, dualMono: true)
    m.feed(b.channels, count: b.frameCount)
    #expect(abs(m.integrated + 20) < 0.1)
}

@Test func gatesDropQuietPassagesAndSilence() {
    // Tech 3341 case 3 shape: −36 / −23 / −36 dBFS → −23 LUFS (the relative gate drops the −36 parts).
    let rate = 48_000
    let quiet = pow(10, -36.0 / 20), loud = pow(10, -23.0 / 20)
    let b = buffer(channels: 2, seconds: 30) { _, i in
        let a = (i < 5 * rate || i >= 25 * rate) ? quiet : loud
        return Float(a * sin(2 * Double.pi * 997 * Double(i) / Double(rate)))
    }
    #expect(abs(Loudness.integratedLUFS(b) + 23) < 0.1)
    // Absolute gate: silence + quiet tone below −70 → −inf; shorter than one 400 ms block → −inf.
    #expect(Loudness.integratedLUFS(buffer(channels: 2, seconds: 3) { _, _ in 0 }) == -.infinity)
    #expect(Loudness.integratedLUFS(buffer(channels: 2, seconds: 3, sine(dBFS: -75))) == -.infinity)
    #expect(Loudness.integratedLUFS(buffer(channels: 2, seconds: 0.35, sine(dBFS: -20))) == -.infinity)
}

@Test func meterIsChunkIndependent() {
    var seed: UInt64 = 7
    let b = buffer(channels: 2, seconds: 4) { _, _ in
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: seed >> 11) % 20_000) / 100_000
    }
    var one = LoudnessMeter(sampleRate: 48_000, channels: 2)
    one.feed(b.channels, count: b.frameCount)
    var many = LoudnessMeter(sampleRate: 48_000, channels: 2)
    var i = 0
    for size in [1, 999, 4_800, 17, 30_000, 100_000] where i < b.frameCount {
        let n = min(size, b.frameCount - i)
        many.feed(b.channels.map { Array($0[i ..< i + n]) }, count: n)
        i += n
    }
    if i < b.frameCount {
        let n = b.frameCount - i
        many.feed(b.channels.map { Array($0[i ..< i + n]) }, count: n)
    }
    #expect(one.integrated == many.integrated)
}

@Test func truePeakSeesInterSamplePeaks() {
    // fs/4 sine at 45° phase: every sample is ±0.7071 (−3.01 dBFS) but the waveform peaks at 0 dBTP.
    let b = buffer(channels: 1, seconds: 1) { _, i in Float(sin(Double.pi / 2 * Double(i) + Double.pi / 4)) }
    let sampleMax = b.channels[0].map { abs($0) }.max() ?? 0
    #expect(abs(20 * log10(Double(sampleMax)) + 3.01) < 0.01)
    // Tech 3341 tolerance for true peak: +0.2 / −0.4 dB.
    let tp = Loudness.truePeak(b)
    #expect(tp > -0.4 && tp < 0.2)
    // A plain 997 Hz sine: true peak ≈ sample peak ≈ its level.
    #expect(abs(Loudness.truePeak(buffer(channels: 2, seconds: 1, sine(dBFS: -6))) + 6) < 0.1)
    #expect(Loudness.truePeak(buffer(channels: 2, seconds: 1) { _, _ in 0 }) == -.infinity)
}

@Test func meterMatchesFFmpegEBUR128OnNoise() throws {
    guard let ffmpeg = ffmpegPath() else { return }
    let dir = try Synth.tempDir()
    let u = dir.appendingPathComponent("noise.wav")
    // Pink-ish noise (one-pole filtered white) with a level change, stereo, 12 s.
    var seed: UInt64 = 42
    var state: [Double] = [0, 0]
    let rate = 48_000, frames = 12 * rate
    var chans = [[Float]](repeating: [Float](repeating: 0, count: frames), count: 2)
    for i in 0 ..< frames {
        for c in 0 ..< 2 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let w = Double(Int64(bitPattern: seed) >> 11) / Double(1 << 52)
            state[c] = 0.95 * state[c] + 0.05 * w
            chans[c][i] = Float(state[c] * (i < 4 * rate ? 0.8 : 2.4))
        }
    }
    try Synth.wav(u, rate: rate, channels: 2, frames: frames) { c, i in chans[c][i] }
    let b = PCMBuffer(format: PCMFormat(sampleRate: Double(rate), channels: 2), startTime: .zero,
                      frameCount: frames, channels: chans)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: ffmpeg)
    p.arguments = ["-hide_banner", "-nostats", "-i", u.path, "-af", "ebur128=peak=true", "-f", "null", "-"]
    let pipe = Pipe()
    p.standardError = pipe
    p.standardOutput = FileHandle.nullDevice
    try p.run()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    // Summary block: "I:         -23.4 LUFS" … "Peak:       -1.2 dBFS".
    let summary = out.components(separatedBy: "Summary:").last ?? ""
    func value(_ label: String) -> Double? {
        guard let line = summary.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(label) })
        else { return nil }
        return line.split(separator: " ").compactMap { Double($0) }.first
    }
    let ffI = try #require(value("I:"))
    #expect(abs(Loudness.integratedLUFS(b) - ffI) < 0.1)
    if let ffPeak = value("Peak:") {
        #expect(abs(Loudness.truePeak(b) - ffPeak) < 0.3)
    }
}

// MARK: Normalisation

@Test func normalisationGainIsTargetMinusLoudnessCappedByPeak() {
    let g = AudioMixer.normalisationGain
    #expect(abs(g(-18, -30, 0.1) - pow(10, 12.0 / 20)) < 1e-12)
    #expect(g(-18, -40, 0.5) == 2)                                // +22 dB capped at 1/peak
    #expect(abs(g(-18, -10, 0.9) - pow(10, -8.0 / 20)) < 1e-12)   // loud sources are turned down
    #expect(g(-18, -.infinity, 0) == 1)                           // silence
    #expect(g(-18, nil, 0.5) == 1)                                // unmeasured
    #expect(abs(g(-18, -38.99, 0.1016) - 1 / 0.1016) < 1e-12)     // the vlog's hard case (audio.md §1)
}

private func normalisedRMS(lufs: Double, peak: Double, project: Bool = true, source: Bool = true,
                           clip: Bool? = nil) async throws -> Double {
    let dir = try Synth.tempDir()
    let u = dir.appendingPathComponent("t.wav")
    try Synth.wav(u, rate: 48_000, channels: 1, frames: 48_000 * 2, Synth.sine(freq: 997, amp: 0.1, rate: 48_000))
    var src = P.source(1, u, lufs: lufs, peak: peak)
    src["loudnessNormalization"] = source
    var attrs: [String: Any] = [:]
    if let clip { attrs["loudnessNormalization"] = clip }
    let p = try P.project(tracks: [P.track(0, [P.clip("AMFile", id: 10, src: 1, start: 0, duration: sec(2),
                                                      attributes: attrs)])],
                          sources: [src], normalise: project, target: -18)
    let b = try await P.mixer(p).render(0 ..< sec(2))
    return rms(b.channels[0][idx(0.1) ..< idx(1.9)]) / (0.1 / 2.squareRoot())
}

@Test func normalisationAppliesPerClipWithThreeSwitches() async throws {
    // Stored measurements: −30 LUFS → +12 dB; peak 0.1 allows up to +20 dB.
    #expect(abs(try await normalisedRMS(lufs: -30, peak: 0.1) - pow(10, 12.0 / 20)) < 1e-3)
    // Peak cap: −40 LUFS wants +22 dB, peak 0.5 allows ×2.
    #expect(abs(try await normalisedRMS(lufs: -40, peak: 0.5) - 2) < 1e-3)
    // Any switch off → unity.
    #expect(abs(try await normalisedRMS(lufs: -30, peak: 0.1, project: false) - 1) < 1e-3)
    #expect(abs(try await normalisedRMS(lufs: -30, peak: 0.1, source: false) - 1) < 1e-3)
    #expect(abs(try await normalisedRMS(lufs: -30, peak: 0.1, clip: false) - 1) < 1e-3)
}

@Test func unmeasuredSourcesAreMeasuredByWizRec() async throws {
    // Sentinels (100.0 / −1.0): mono 997 Hz at amplitude 0.1 measures −20 LUFS (dual mono) with
    // sample peak 0.1 → +2 dB to reach −18.
    let r = try await normalisedRMS(lufs: 100, peak: -1)
    #expect(abs(20 * log10(r) - 2) < 0.1)
}

// MARK: Source measurement like Camtasia's stored values (audio.md §2.1, AU2)

@Test func sourceMeasurementMatchesCamtasiaStoredValues() async throws {
    // The AU2 signals (mono, 48 kHz, 16-bit; regenerated, deterministic) and what Camtasia 2026.2.3
    // stored for them on save: integratedLUFS, peakLevel (linear).
    let dir = try Synth.tempDir()
    let cases: [(String, [Float], Double, Double, Double)] = [
        ("a.wav", AudioSignals.pinkNoise(seconds: 10, lufs: -40, peakLimit: -20, seed: 0xA), -37.2512483366092, 0.0473308339715004, 0.2),
        ("b.wav", AudioSignals.clickTrain(seconds: 10, lufs: -30, peak: -1), -26.945935759826, 0.891246914863586, 0.1),
        // MediaEngine's resampler reads the quiet pink 0.13 LU louder. Loud pink: Camtasia reads
        // 0.35 LU lower than dual-mono at 44.1 kHz [?] (audio.md §2.1).
        ("c.wav", AudioSignals.pinkNoise(seconds: 10, lufs: -10, peakLimit: -0.5, seed: 0xC), -7.54978312205293, 1.03471958637238, 0.45),
    ]
    let pool = MediaPool(diskCacheDirectory: nil)
    for (name, x, lufs, peak, tol) in cases {
        let u = dir.appendingPathComponent(name)
        try AudioSignals.writeWAV(x, to: u)
        let m = try #require(try await SourceLoudness.measure(pool: pool, url: u, stream: 0, mixRate: 44_100))
        #expect(abs(m.integratedLUFS - lufs) < tol, "\(name): \(m.integratedLUFS) vs \(lufs)")
        // Sample peak after resampling to 44.1 kHz (not the 48 kHz peak, not true peak). The
        // resamplers differ, so the loud pink's +0.30 dBFS reads +0.47 here: within 0.25 dB.
        #expect(abs(20 * log10(m.peakLevel / peak)) < 0.25,"\(name): peak \(m.peakLevel) vs \(peak)")
        // Mono counts as dual mono: +3 LU over a plain BS.1770 mono reading at 48 kHz.
        let plain = AudioSignals.integratedLUFS(x)
        #expect(m.integratedLUFS - plain > 2.5 && m.integratedLUFS - plain < 3.5)
    }
}

@Test func missingSourceMeasuresNil() async throws {
    let dir = try Synth.tempDir()
    let m = try await SourceLoudness.measure(pool: MediaPool(diskCacheDirectory: nil),
                                             url: dir.appendingPathComponent("absent.wav"), stream: 0)
    #expect(m == nil)
}
