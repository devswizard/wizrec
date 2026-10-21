import CoreMedia
import Foundation
import MediaEngine
import Testing
import TSCProjKit
@testable import AudioEngine

// AUD12-1: a project without a usable `audioFormatSampleRate` exports at the 48 kHz fallback.
// Unmeasured sources used to be measured at Camtasia's 44.1 kHz default, which resampled every
// such source once and made the export ~10× slower. They are now measured at the mixer's own rate
// [WizRec, audio.md §2.1]; projects that carry the key (Camtasia always writes it) are unchanged.

/// Stereo 48 kHz test source: a 997 Hz tone with a 5.5 kHz partial (so a 44.1 kHz measurement
/// differs from a 48 kHz one in the last digits) and a quiet passage.
private func writeSource(_ url: URL, seconds: Double) throws {
    let frames = Int(48_000 * seconds)
    try Synth.wav(url, rate: 48_000, channels: 2, frames: frames) { c, i in
        let t = Double(i) / 48_000
        let level = t.truncatingRemainder(dividingBy: 2) < 1.5 ? 0.25 : 0.02
        return Float(level * (sin(2 * Double.pi * 997 * t + Double(c)) + 0.6 * sin(2 * Double.pi * 5_500 * t)))
    }
}

/// One normalised clip over the whole source; `raw` is the JSON of `audioFormatSampleRate`
/// (nil removes it); `lufs` / `peak` are the source's stored values (sentinels = unmeasured).
private func project(_ url: URL, seconds: Double, raw: String?, lufs: Double = 100, peak: Double = -1) throws -> Project {
    let p = try P.project(tracks: [P.track(0, [P.clip("AMFile", id: 10, src: 1, start: 0, duration: sec(seconds))])],
                          sources: [P.source(1, url, channels: 2, lufs: lufs, peak: peak)], normalise: true, target: -16)
    p.root["audioFormatSampleRate"] = try raw.map { try JSON.parse($0) }
    return p
}

/// The mix at `rate` (default: the exporter's 48 kHz fallback), in 0.5 s chunks like an export.
private func mix(_ p: Project, seconds: Double, rate: Double = 48_000) async throws -> [[Float]] {
    let m = P.mixer(p, rate: rate)
    var out: [[Float]] = [[], []]
    var t: Int64 = 0
    let end = sec(seconds), step = sec(0.5)
    while t < end {
        let b = try await m.render(t ..< min(end, t + step))
        for c in 0..<2 { out[c] += b.channels[c] }
        t += step
    }
    return out
}

/// Missing or invalid rate: the scene reports nil, the source is measured at the mixer's rate
/// (48 kHz on export, 44.1 kHz for a 44.1 kHz mixer) and the mix applies exactly the gain those
/// stored values would give.
@Test(arguments: [nil, "0", "\"48000\"", "1e9"] as [String?], [48_000.0, 44_100.0])
func fallbackRateMeasuresAtMixRate(_ raw: String?, _ rate: Double) async throws {
    let dir = try Synth.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let u = dir.appendingPathComponent("s.wav")
    try writeSource(u, seconds: 2)
    let fallback = try project(u, seconds: 2, raw: raw)
    #expect(P.scene(fallback).sampleRate == nil)
    let other: Double = rate == 48_000 ? 44_100 : 48_000
    let pool = MediaPool(diskCacheDirectory: nil)
    let mine = try #require(try await SourceLoudness.measure(pool: pool, url: u, stream: 0, mixRate: rate))
    let theirs = try #require(try await SourceLoudness.measure(pool: pool, url: u, stream: 0, mixRate: other))
    #expect(mine != theirs, "the test signal must tell the two measurement rates apart")

    let got = try await mix(fallback, seconds: 2, rate: rate)
    let storedMine = try await mix(project(u, seconds: 2, raw: "48000", lufs: mine.integratedLUFS, peak: mine.peakLevel),
                                   seconds: 2, rate: rate)
    let storedOther = try await mix(project(u, seconds: 2, raw: "48000", lufs: theirs.integratedLUFS, peak: theirs.peakLevel),
                                    seconds: 2, rate: rate)
    let n = Int(2 * rate)
    let counts: [Int] = got.map { (c: [Float]) -> Int in c.count }
    #expect(counts == [n, n])
    #expect(got == storedMine, "fallback must measure at the mixer's rate")
    #expect(got != storedOther)
    // And the gain is the normalisation rule's: −16 LUFS target, peak-capped.
    let g = AudioMixer.normalisationGain(target: -16, lufs: mine.integratedLUFS, peak: mine.peakLevel)
    let dry = try await mix(project(u, seconds: 2, raw: raw, lufs: -16, peak: 0.5), seconds: 2, rate: rate)
    let k = n / 4
    let wet: Double = Double(got[0][k]), want: Double = g * Double(dry[0][k])
    #expect(abs(wet - want) < 1e-5)
}

/// Export-like mix of a 30 s source at the 48 kHz fallback vs a valid 48 kHz rate: both measure the
/// unmeasured source once at 48 kHz, so neither resamples and the costs match. Asserted (≤ 1.5×)
/// in release builds; debug builds only report. (Measuring at 44.1 kHz cost ≈ 2× in debug and
/// 4–5× in release even after the resampler speed-ups.)
@Test(.enabled(if: ProcessInfo.processInfo.environment["WIZREC_PERF"] == "1"))
func fallbackRateExportCostsLikeAValidRate() async throws {
    let dir = try Synth.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let u = dir.appendingPathComponent("s.wav")
    let seconds = 30.0
    try writeSource(u, seconds: seconds)
    let clock = ContinuousClock()
    func best(_ raw: String?) async throws -> Double {
        var best = Double.infinity
        for _ in 0..<5 {
            let p = try project(u, seconds: seconds, raw: raw)
            let d = try await clock.measure { _ = try await mix(p, seconds: seconds) }
            best = min(best, Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
        }
        return best
    }
    let valid = try await best("48000")
    let missing = try await best(nil)
    let ratio = missing / valid
    print(String(format: "fallback-rate mix of %.0f s: valid 48 kHz %.3f s, missing %.3f s (%.2f×)",
                 seconds, valid, missing, ratio))
    #if !DEBUG
    #expect(ratio <= 1.5, "missing sample rate costs \(ratio)× a valid one")
    #endif
}
