import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import MediaEngine

private func range(_ start: Double, _ duration: Double) -> CMTimeRange {
    CMTimeRange(start: CMTime(value: Int64((start * 705_600_000).rounded()), timescale: 705_600_000),
                duration: CMTime(value: Int64((duration * 705_600_000).rounded()), timescale: 705_600_000))
}

private func rms(_ x: ArraySlice<Float>) -> Double {
    guard !x.isEmpty else { return 0 }
    return (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
}

/// Index of the first sample whose magnitude exceeds `threshold`.
private func onset(_ x: [Float], threshold: Float = 0.1) -> Int? { x.firstIndex { abs($0) > threshold } }

@Suite struct AudioDecodeTests {
    @Test func sameRateIsExact() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.wav")
        try Synth.writeWAV(to: url, seconds: 1, sampleRate: 44100, frequency: 441)
        let pool = MediaPool()
        let info = try await pool.probe(url)
        #expect(info.kind == .movie)
        #expect(info.streams.first?.kind == .audio)
        #expect(info.streams.first?.sampleRate == 44100)
        #expect(abs(info.duration.seconds - 1) < 1e-3)

        let src = try await pool.source(for: url)
        let buf = try await src.audio(stream: 0, range: range(0.25, 0.5), format: PCMFormat(sampleRate: 44100, channels: 1))
        #expect(buf.frameCount == 22050)
        #expect(buf.channels.count == 1)
        let expected = (0..<22050).map { Float(Int16((Synth.sine($0 + 11025, rate: 44100, frequency: 441) * 32767).rounded())) / 32768 }
        let maxErr = zip(buf.channels[0], expected).map { abs($0 - $1) }.max() ?? 1
        #expect(maxErr < 1e-6)
    }

    @Test func resamplesAndUpmixes() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.wav")
        try Synth.writeWAV(to: url, seconds: 1, sampleRate: 44100, frequency: 441)
        let src = try await MediaPool().source(for: url)
        let buf = try await src.audio(stream: 0, range: range(0.1, 0.5), format: PCMFormat(sampleRate: 48000, channels: 2))
        #expect(buf.frameCount == 24000)
        #expect(buf.channels.count == 2)
        #expect(buf.channels[0] == buf.channels[1])
        // Compare with the ideal sine at the output times.
        let ideal = (0..<24000).map { Float(0.5 * sin(2 * Double.pi * 441 * (0.1 + Double($0) / 48000))) }
        let err = zip(buf.channels[0], ideal).map { abs($0 - $1) }.max() ?? 1
        #expect(err < 2e-3, "max error \(err)")
    }

    @Test func silencePadsOutsideStream() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.wav")
        try Synth.writeWAV(to: url, seconds: 1, sampleRate: 48000, channels: 2, frequency: 480)
        let src = try await MediaPool().source(for: url)
        let fmt = PCMFormat(sampleRate: 48000, channels: 2)
        let pre = try await src.audio(stream: 0, range: range(-0.25, 0.5), format: fmt)
        #expect(pre.frameCount == 24000)
        #expect(pre.channels[0][0..<12000].allSatisfy { $0 == 0 })
        #expect(rms(pre.channels[1][12100..<24000]) > 0.3)
        let post = try await src.audio(stream: 0, range: range(0.9, 0.3), format: fmt)
        #expect(rms(post.channels[0][0..<4700]) > 0.3)
        #expect(post.channels[0][4900...].allSatisfy { $0 == 0 })
        let far = try await src.audio(stream: 0, range: range(5, 0.1), format: fmt)
        #expect(far.frameCount == 4800)
        #expect(far.channels.allSatisfy { $0.allSatisfy { $0 == 0 } })
        let mono = try await src.audio(stream: 0, range: range(0.5, 0.01), format: PCMFormat(sampleRate: 48000, channels: 1))
        #expect(mono.channels.count == 1)
        #expect(rms(mono.channels[0][...]) > 0.3)
    }

    /// Consecutive requests join exactly, so playback chunks never click.
    @Test func chunksJoinSeamlessly() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.wav")
        try Synth.writeWAV(to: url, seconds: 2, sampleRate: 44100, frequency: 1000)
        let src = try await MediaPool().source(for: url)
        let fmt = PCMFormat(sampleRate: 48000, channels: 1)
        let whole = try await src.audio(stream: 0, range: range(0.2, 0.6), format: fmt)
        var joined: [Float] = []
        for k in 0..<6 {
            let part = try await src.audio(stream: 0, range: range(0.2 + Double(k) * 0.1, 0.1), format: fmt)
            joined += part.channels[0]
        }
        #expect(joined.count == whole.frameCount)
        let err = zip(joined, whole.channels[0]).map { abs($0 - $1) }.max() ?? 1
        #expect(err < 1e-5)
        // Out-of-order (seek) requests give the same samples too.
        let again = try await src.audio(stream: 0, range: range(0.5, 0.1), format: fmt)
        #expect(zip(again.channels[0], joined[14400..<19200]).allSatisfy { abs($0 - $1) < 1e-5 })
    }

    /// AAC priming: with an edit list libav trims exactly the encoder's priming, so the onset
    /// at 0.5 s lands at 0.5 s. Without an edit list we drop a fixed 2112 samples (what
    /// Camtasia does, media-streams.md §4); FFmpeg's encoder primes only 1024, so there the
    /// onset lands 1088 samples early — which proves the 2112 trim.
    @Test(arguments: [true, false])
    func aacPrimingRemoved(editList: Bool) async throws {
        guard Synth.ffmpegPath != nil else { return }
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("s.wav")
        try Synth.writeWAV(to: wav, seconds: 1.5, sampleRate: 48000, frequency: 500, onset: 0.5)
        let mp4 = dir.appendingPathComponent("s.mp4")
        try Synth.ffmpeg(["-i", wav.path, "-c:a", "aac", "-b:a", "128k", "-use_editlist", editList ? "1" : "0", mp4.path])
        let pool = MediaPool()
        let info = try await pool.probe(mp4)
        let a = try #require(info.streams.first)
        #expect(a.codec == "aac")
        #expect(abs(a.duration.seconds - 1.5) < 0.05, "duration \(a.duration.seconds)")
        let src = try await pool.source(for: mp4)
        let buf = try await src.audio(stream: 0, range: range(0, 1), format: PCMFormat(sampleRate: 48000, channels: 1))
        let at = try #require(onset(buf.channels[0]))
        let expected = editList ? 0.5 : 0.5 - Double(Prober.aacPriming - 1024) / 48000
        #expect(abs(Double(at) / 48000 - expected) < 0.002, "onset at \(Double(at) / 48000) s")
    }

    @Test func videoOnlyFileHasNoAudio() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("v.mp4")
        try await Synth.writeMovie(to: url, times: [0, 0.1])
        let src = try await MediaPool().source(for: url)
        await #expect(throws: MediaError.self) {
            try await src.audio(stream: 0, range: range(0, 0.1), format: PCMFormat(sampleRate: 48000, channels: 2))
        }
        await #expect(throws: MediaError.noSuchStream(1)) {
            try await src.audio(stream: 1, range: range(0, 0.1), format: PCMFormat(sampleRate: 48000, channels: 2))
        }
    }
}

@Suite struct StreamMappingTests {
    /// Cover art and data tracks are not public streams; indices count audio/video only.
    @Test func skipsAttachedPictureAndData() async throws {
        guard Synth.ffmpegPath != nil else { return }
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("cover.png")
        try Synth.writePNG(to: png, width: 32, height: 32, rgba: (0, 255, 0, 255))
        let out = dir.appendingPathComponent("m.mov")
        // Container order: tmcd/cover come out wherever the muxer puts them; public order must be [video, audio].
        try Synth.ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=160x90:rate=30", "-f", "lavfi", "-i", "sine=f=440:r=48000",
                          "-i", png.path, "-map", "0:v", "-map", "2", "-map", "1:a", "-t", "1",
                          "-c:v:0", "libx264", "-c:v:1", "png", "-disposition:v:1", "attached_pic",
                          "-c:a", "aac", "-timecode", "00:00:00:00", out.path])
        let info = try await MediaPool().probe(out)
        #expect(info.streams.map(\.kind) == [.video, .audio])
        #expect(info.streams.map(\.index) == [0, 1])
        #expect(info.streams.map(\.codec) == ["h264", "aac"])
        let src = try await MediaPool().source(for: out)
        let f = try await src.frame(stream: 0, at: CMTime(value: 1, timescale: 2))
        #expect(f.pixelBuffer.width == 160)
        let a = try await src.audio(stream: 1, range: range(0.2, 0.1), format: PCMFormat(sampleRate: 48000, channels: 1))
        #expect(rms(a.channels[0][...]) > 0.05)
    }

    @Test func pdfFirstPage() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p.pdf")
        var box = CGRect(x: 0, y: 0, width: 160, height: 109)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { Issue.record("no pdf ctx"); return }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 109)) // left half blue
        ctx.endPDFPage()
        ctx.closePDF()
        let pool = MediaPool()
        let info = try await pool.probe(url)
        #expect(info.kind == .image)
        #expect(info.streams.first?.codec == "pdf")
        #expect(info.streams.first?.pixelSize == CGSize(width: 160, height: 109))
        let f = try await pool.frame(FrameRequest(url: url, stream: 0, time: .zero))
        #expect(f.pixelBuffer.width == 160 && f.pixelBuffer.height == 109)
        let left = Synth.pixel(f.pixelBuffer, x: 10, y: 50), right = Synth.pixel(f.pixelBuffer, x: 150, y: 50)
        #expect(left.b > 240 && left.r < 20 && left.a == 255)
        #expect(right.a == 0) // unpainted page area is transparent
    }
}

@Suite(.enabled(if: Demo.available, "demo project not installed"))
struct DemoAudioTests {
    /// The .trec audio's 28-sample empty edit is real: stream time 0 is movie time 0.
    @Test func trecAudioStartsAfterEmptyEdit() async throws {
        let src = try await MediaPool().source(for: Demo.trec)
        #expect(abs(src.info.streams[2].duration.seconds - 1133222.0 / 44100) < 1e-4)
        let buf = try await src.audio(stream: 2, range: range(0, 0.5), format: PCMFormat(sampleRate: 44100, channels: 1))
        #expect(buf.frameCount == 22050)
        #expect(buf.channels[0][0..<28].allSatisfy { $0 == 0 })
        #expect(buf.channels[0][28..<22050].contains { $0 != 0 })
    }
}

private extension CVPixelBuffer {
    var width: Int { CVPixelBufferGetWidth(self) }
    var height: Int { CVPixelBufferGetHeight(self) }
}
