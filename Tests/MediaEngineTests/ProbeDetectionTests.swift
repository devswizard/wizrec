// Container detection: content must never outvote a valid container named by its extension.

import CoreMedia
import Foundation
import TSCProjKit
import Testing
@testable import MediaEngine

/// 32-bit float WAV (format tag 3), interleaved.
private func writeFloatWAV(_ url: URL, rate: Int, channels: Int, frames: Int, _ sample: (Int, Int) -> Float) throws {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let dataBytes = frames * channels * 4
    d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes)); d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(3); u16(UInt16(channels)); u32(UInt32(rate))
    u32(UInt32(rate * channels * 4)); u16(UInt16(channels * 4)); u16(32)
    d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
    var samples = [Float](repeating: 0, count: frames * channels)
    for i in 0..<frames { for c in 0..<channels { samples[i * channels + c] = sample(c, i) } }
    samples.withUnsafeBytes { d.append(contentsOf: $0) }
    try d.write(to: url)
}

private func sineWAV(_ url: URL, amp: Double) throws {
    try writeFloatWAV(url, rate: 48000, channels: 1, frames: 3 * 48000) { _, i in
        Float(amp * sin(2 * Double.pi * 500 * Double(i) / 48000))
    }
}

@Suite struct ProbeDetectionTests {
    /// This exact signal puts a 0x47 byte every 188 bytes, so libav's content probe scores it as
    /// MPEG-TS (100) above WAV (99) and the open fails. The `.wav` extension must win.
    @Test(arguments: [0.014142135623730951, 0.01])
    func floatWAVSineIsWAV(amp: Double) async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tone.wav")
        try sineWAV(url, amp: amp)
        let info = try await MediaPool().probe(url)
        #expect(info.kind == .movie)
        #expect(info.streams.count == 1)
        #expect(info.streams.first?.kind == .audio)
        #expect(info.streams.first?.codec == "pcm_f32le")
        #expect(info.streams.first?.sampleRate == 48000)
        #expect(abs(info.duration.seconds - 3) < 1e-3)

        let src = try await MediaPool().source(for: url)
        let range = CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1))
        let buf = try await src.audio(stream: 0, range: range, format: PCMFormat(sampleRate: 48000, channels: 1))
        let peak = buf.channels[0].map { abs($0) }.max() ?? 0
        #expect(abs(Double(peak) - amp) < 1e-4)
    }

    @Test func misdetectedWAVUsesExtensionDemuxer() throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("bad.wav"), ok = dir.appendingPathComponent("ok.wav")
        try sineWAV(bad, amp: 0.014142135623730951)
        try sineWAV(ok, amp: 0.01)
        #expect(try FormatContext(url: bad).usedExtensionHint)
        #expect(try !FormatContext(url: ok).usedExtensionHint)
    }

    /// The user's project media keep the content-probed demuxer (behaviour unchanged).
    @Test(arguments: ["demo project", "Moheshkali Dwip Vlog"])
    func userMediaKeepContentProbe(project name: String) throws {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/\(name).cmproj")
        guard FileManager.default.fileExists(atPath: dir.path) else { return } // not installed: skip
        let bundle = try ProjectBundle(url: dir)
        var checked = 0
        for src in bundle.project.sourceBin {
            let url = bundle.resolve(src)
            guard FileManager.default.fileExists(atPath: url.path),
                  !Prober.isImageExtension(url.pathExtension.lowercased()),
                  url.pathExtension.lowercased() != Prober.shaderExtension,
                  let fc = try? FormatContext(url: url) else { continue }
            #expect(!fc.usedExtensionHint, "\(url.lastPathComponent)")
            checked += 1
        }
        print("content probe kept \(name): \(checked)")
        #expect(checked > 0)
    }

    /// A file whose extension names audio/video must report the libav failure, not an image/PDF error.
    @Test func brokenAudioExtensionReportsFFmpegError() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("broken.wav")
        try Data(repeating: 0x5A, count: 4096).write(to: url)
        await #expect {
            _ = try await MediaPool().probe(url)
        } throws: { error in
            guard case MediaError.unsupported(let msg) = error else { return false }
            return msg.contains("broken.wav") && !msg.localizedCaseInsensitiveContains("pdf")
        }
    }
}
