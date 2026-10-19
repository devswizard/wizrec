// AudioEngine relies on `audio()` being a pure function of (stream, range, format): the same
// samples, bit for bit, whatever was requested before (fresh source, sequential reads, seeks).

import CoreMedia
import Foundation
import Testing
@testable import MediaEngine

@Suite(.enabled(if: Synth.ffmpegPath != nil, "needs ffmpeg"))
struct AudioDeterminismTests {
    static let codecs: [(String, [String])] = [
        ("wav", []),
        ("m4a", ["-c:a", "aac", "-b:a", "128k"]),
        ("mp3", ["-c:a", "libmp3lame", "-b:a", "128k"]),
        ("mov", ["-c:a", "aac_at", "-b:a", "128k"]),
    ]

    private func r(_ s: Double, _ d: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 705_600_000),
                    duration: CMTime(seconds: d, preferredTimescale: 705_600_000))
    }

    @Test(arguments: [0, 1, 2, 3])
    func historyIndependent(codecIndex: Int) async throws {
        let (ext, args) = Self.codecs[codecIndex]
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("src.wav")
        try Synth.writeWAV(to: wav, seconds: 6, sampleRate: 48000, channels: 2, frequency: 523, onset: 0.3)
        let url = ext == "wav" ? wav : dir.appendingPathComponent("a.\(ext)")
        if ext != "wav" { try Synth.ffmpeg(["-i", wav.path] + args + [url.path]) }
        for f in [PCMFormat(sampleRate: 44100, channels: 2), PCMFormat(sampleRate: 48000, channels: 2)] {
            for target in [r(0, 0.4), r(2.5, 0.37), r(5.2, 1.0)] {
                let label = "\(ext) @\(Int(f.sampleRate)) t=\(target.start.seconds)"
                // Fresh source.
                let a = try await MediaPool().source(for: url).audio(stream: 0, range: target, format: f)
                // Sequential reads from the start up to and through the target.
                let seqSrc = try await MediaPool().source(for: url)
                var t = 0.0
                while t + 0.25 < target.start.seconds {
                    _ = try await seqSrc.audio(stream: 0, range: r(t, 0.25), format: f)
                    t += 0.25
                }
                let b = try await seqSrc.audio(stream: 0, range: target, format: f)
                // After seeks far away and back.
                let seekSrc = try await MediaPool().source(for: url)
                _ = try await seekSrc.audio(stream: 0, range: r(4.0, 0.2), format: f)
                _ = try await seekSrc.audio(stream: 0, range: r(0.1, 0.2), format: f)
                let c = try await seekSrc.audio(stream: 0, range: target, format: f)
                #expect(a.channels == b.channels, "\(label): sequential differs from fresh")
                #expect(a.channels == c.channels, "\(label): after seeks differs from fresh")
            }
        }
    }
}
