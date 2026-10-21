import CoreMedia
import Foundation
import MediaEngine
import Testing
import TSCProjKit
@testable import AudioEngine

// AUD12-1: a project without a usable `audioFormatSampleRate` exports at the 48 kHz fallback
// while unmeasured sources are measured at Camtasia's 44.1 kHz default (audio.md §2.1), which
// resamples every such source once. That resample used to make the export ~10× slower.

/// Stereo 48 kHz test source: a 997 Hz tone with a 5.5 kHz partial (so the 44.1 kHz measurement
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

/// The mix at the exporter's 48 kHz fallback rate, in 0.5 s chunks like an export.
private func mix(_ p: Project, seconds: Double) async throws -> [[Float]] {
    let m = P.mixer(p, rate: 48_000)
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

/// Missing or invalid rate: the scene reports nil, the source is measured at 44.1 kHz and the
/// 48 kHz mix applies exactly the gain those stored values would give.
@Test(arguments: [nil, "0", "\"48000\"", "1e9"] as [String?])
func fallbackRateMeasuresAt44_1kHz(_ raw: String?) async throws {
    let dir = try Synth.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let u = dir.appendingPathComponent("s.wav")
    try writeSource(u, seconds: 2)
    let fallback = try project(u, seconds: 2, raw: raw)
    #expect(P.scene(fallback).sampleRate == nil)
    let pool = MediaPool(diskCacheDirectory: nil)
    let m44 = try #require(try await SourceLoudness.measure(pool: pool, url: u, stream: 0, mixRate: 44_100))
    let m48 = try #require(try await SourceLoudness.measure(pool: pool, url: u, stream: 0, mixRate: 48_000))
    #expect(m44 != m48, "the test signal must tell the two measurement rates apart")

    let got = try await mix(fallback, seconds: 2)
    let stored44 = try await mix(project(u, seconds: 2, raw: "48000", lufs: m44.integratedLUFS, peak: m44.peakLevel), seconds: 2)
    let stored48 = try await mix(project(u, seconds: 2, raw: "48000", lufs: m48.integratedLUFS, peak: m48.peakLevel), seconds: 2)
    #expect(got.map(\.count) == [96_000, 96_000])
    #expect(got == stored44, "fallback must measure at 44.1 kHz")
    #expect(got != stored48)
    // And the gain is the normalisation rule's: −16 LUFS target, peak-capped.
    let g = AudioMixer.normalisationGain(target: -16, lufs: m44.integratedLUFS, peak: m44.peakLevel)
    let dry = try await mix(project(u, seconds: 2, raw: raw, lufs: -16, peak: 0.5), seconds: 2)
    let i = 24_000
    #expect(abs(Double(got[0][i]) - g * Double(dry[0][i])) < 1e-5)
}

/// Export-like mix of a 20 s source at the 48 kHz fallback: without a project rate it must cost at
/// most ~1.5× the time with a valid 48 kHz rate (both measure the unmeasured source once; only the
/// fallback resamples it to 44.1 kHz). Asserted in release builds; debug builds only report.
@Test(.enabled(if: ProcessInfo.processInfo.environment["WIZREC_PERF"] == "1"))
func fallbackRateExportCostsLikeAValidRate() async throws {
    let dir = try Synth.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let u = dir.appendingPathComponent("s.wav")
    let seconds = 20.0
    try writeSource(u, seconds: seconds)
    let clock = ContinuousClock()
    func best(_ raw: String?) async throws -> Double {
        var best = Double.infinity
        for _ in 0..<3 {
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
