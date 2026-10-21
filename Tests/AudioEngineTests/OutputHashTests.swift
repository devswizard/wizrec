import CoreMedia
import Foundation
import MediaEngine
import Testing
import TSCProjKit
@testable import AudioEngine

// AUD12-2: the speed-ups of the resamplers (MediaEngine decode, pitch), WSOLA and the effect DSP
// must not change a single output bit. Each case hashes the exact Float bit patterns of a render
// of a deterministic signal; the expected digests were taken before the speed-ups.

/// FNV-1a 64 over the Float bit patterns of every channel, in order.
private func digest(_ channels: [[Float]]) -> String {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for ch in channels {
        for x in ch {
            var b = x.bitPattern
            for _ in 0..<4 {
                h = (h ^ UInt64(b & 0xff)) &* 0x0000_0100_0000_01b3
                b >>= 8
            }
        }
    }
    return String(h, radix: 16)
}

/// Deterministic test material: two sines per channel plus LCG noise.
private func material(rate: Int, channels: Int, seconds: Double) -> (Int, Int) -> Float {
    let n = Int(Double(rate) * seconds)
    var seed: UInt64 = 0x5eed
    var noise = [Float](repeating: 0, count: n * channels)
    for i in noise.indices {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        noise[i] = Float(Double(Int64(bitPattern: seed) >> 11) / Double(1 << 52)) * 0.05
    }
    return { c, i in
        let t = Double(i) / Double(rate)
        let tone = 0.4 * sin(2 * Double.pi * (220 + 110 * Double(c)) * t) + 0.2 * sin(2 * Double.pi * 3_150 * t)
        // A loud burst for the compressor, a quiet stretch for the noise reducer.
        let env = t > 0.6 && t < 0.7 ? 2.2 : (t > 0.9 && t < 1.1 ? 0.05 : 1)
        return Float(tone * env) + noise[i * channels + c]
    }
}

private func effect(_ name: String, _ params: [String: Any] = [:]) -> [String: Any] {
    ["effectName": name, "bypassed": false, "category": "categoryAudioEffects", "parameters": params]
}

private func range(_ s: Double, _ d: Double, _ rate: Int32) -> CMTimeRange {
    CMTimeRange(start: CMTime(value: Int64((s * Double(rate)).rounded()), timescale: rate),
                duration: CMTime(value: Int64((d * Double(rate)).rounded()), timescale: rate))
}

@Suite(.serialized) struct OutputHashTests {
    /// MediaEngine decode + resample to the mix rate (down, up, fractional start, channel mapping).
    @Test func decodeResampleIsBitExact() async throws {
        let dir = try Synth.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let stereo = dir.appendingPathComponent("s.wav"), mono = dir.appendingPathComponent("m.wav")
        try Synth.wav(stereo, rate: 48_000, channels: 2, frames: 57_600, material(rate: 48_000, channels: 2, seconds: 1.2))
        try Synth.wav(mono, rate: 44_100, channels: 1, frames: 26_460, material(rate: 44_100, channels: 1, seconds: 0.6))
        let cases: [(URL, Double, Int, CMTimeRange)] = [
            (stereo, 44_100, 2, range(0.1, 0.5, 44_100)),
            (stereo, 8_000, 2, range(0.3, 0.6, 8_000)),
            (stereo, 22_050, 1, range(0, 0.4, 22_050)),
            (stereo, 96_000, 2, range(0.25, 0.3, 96_000)),
            (stereo, 48_000, 2, CMTimeRange(start: CMTime(value: 87_654_321, timescale: 705_600_000),
                                            duration: CMTime(value: 14_000, timescale: 48_000))),
            (mono, 48_000, 2, range(0.05, 0.5, 48_000)),
        ]
        var got: [String] = []
        for (url, rate, ch, r) in cases {
            let src = try await MediaPool(diskCacheDirectory: nil).source(for: url)
            let pcm = try await src.audio(stream: 0, range: r, format: PCMFormat(sampleRate: rate, channels: ch))
            got.append(digest(pcm.channels))
        }
        print("decodeResampleIsBitExact: \(got)")
        #expect(got == Self.decodeDigests)
    }

    static let decodeDigests = ["40af1c3de8cb3c53", "5af8e2d6a4a7dfe7", "ba27a0504ecf9fc9", "123a41e2a7a1c81f",
                                "3f590d6b5209c45e", "44d95980f8cc9da1"]

    /// Effects (noise removal, compression, leveling), pitch (resample + WSOLA) and Clip Speed
    /// (WSOLA), across block boundaries; plus a 44.1 kHz mix with loudness measured at that rate.
    @Test func mixIsBitExact() async throws {
        let dir = try Synth.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let u = dir.appendingPathComponent("s.wav")
        try Synth.wav(u, rate: 48_000, channels: 2, frames: 57_600, material(rate: 48_000, channels: 2, seconds: 1.2))
        let fx = [effect("VSTEffect-DFN3NoiseRemoval", ["Amount": 0.8]),
                  effect("WinCompression", ["ratio": 10.0, "threshold": -20.0, "gain": 9.0, "attack": 2.0, "release": 300.0]),
                  effect("VolumeLeveling")]
        let pitch = [effect("Pitch", ["pitch": -200.0, "effectBlend": 70.0])]
        let tracks = [
            P.track(0, [P.clip("AMFile", id: 10, src: 1, start: 0, duration: sec(1.2), effects: fx)]),
            P.track(1, [P.clip("AMFile", id: 11, src: 1, start: sec(0.1), duration: sec(0.8),
                               mediaDuration: sec(1.2), scalar: "2/3", effects: pitch)]),
            P.track(2, [P.clip("AMFile", id: 12, src: 1, start: sec(0.05), duration: sec(1.1),
                               mediaDuration: sec(0.55), scalar: "2")]),
        ]
        var got: [String] = []
        for (rate, normalise, raw) in [(48_000.0, false, "48000"), (44_100.0, true, "48000"), (48_000.0, true, nil)] as [(Double, Bool, String?)] {
            let p = try P.project(tracks: tracks, sources: [P.source(1, u, channels: 2)], normalise: normalise)
            p.root["audioFormatSampleRate"] = try raw.map { try JSON.parse($0) }
            let m = P.mixer(p, rate: rate)
            // Two renders, so a seam sits inside the clips.
            let a = try await m.render(0 ..< sec(0.55)), b = try await m.render(sec(0.55) ..< sec(1.2))
            got.append(digest(zip(a.channels, b.channels).map { $0 + $1 }))
        }
        print("mixIsBitExact: \(got)")
        #expect(got == Self.mixDigests)
    }

    /// The third case (no project rate) changed on purpose with AUD12-1: its unmeasured source is
    /// now measured at the mixer's 48 kHz instead of 44.1 kHz (audio.md §2.1 [WizRec]); it was
    /// "4855c80aafcdbd52" before. The speed-ups themselves changed no digest.
    static let mixDigests = ["e760e735dcaca112", "f63cd75b0afdb6be", "15eca0a3d6d8b2ff"]
}
