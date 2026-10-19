import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import MediaEngine

private func secs(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600_000) }

private func assertBGRA(_ buf: CVPixelBuffer) {
    #expect(CVPixelBufferGetPixelFormatType(buf) == kCVPixelFormatType_32BGRA)
    #expect(CVPixelBufferGetIOSurface(buf) != nil)
}

@Suite struct VideoDecodeTests {
    @Test(arguments: [AVVideoCodecType.h264, .hevc])
    func probeAndSeekEqualsSequential(codec: AVVideoCodecType) async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cfr.mp4")
        let n = 90, fps = 30.0
        try await Synth.writeMovie(to: url, times: (0..<n).map { Double($0) / fps }, codec: codec, keyInterval: 15)

        let pool = MediaPool()
        let info = try await pool.probe(url)
        #expect(info.kind == .movie)
        #expect(info.streams.count == 1)
        let s = try #require(info.streams.first)
        #expect(s.kind == .video)
        #expect(s.codec == (codec == .h264 ? "h264" : "hevc"))
        #expect(s.pixelSize == CGSize(width: 320, height: 64))
        #expect(abs(s.nominalFrameRate - fps) < 0.5)
        #expect(abs(info.duration.seconds - Double(n) / fps) < 0.05)

        let src = try await pool.source(for: url)
        // Sequential, sampling mid-frame.
        var sequential: [Int] = []
        for i in 0..<n {
            let f = try await src.frame(stream: 0, at: secs((Double(i) + 0.5) / fps))
            assertBGRA(f.pixelBuffer)
            sequential.append(Synth.index(of: f.pixelBuffer))
            #expect(abs(f.presentationTime.seconds - Double(i) / fps) < 1e-3, "pts \(f.presentationTime.seconds) i \(i)")
        }
        #expect(sequential == Array(0..<n))

        // Random order seeks land on the same frames.
        var rng = SystemRandomNumberGenerator()
        for i in (0..<n).shuffled(using: &rng).prefix(40) {
            let f = try await src.frame(stream: 0, at: secs((Double(i) + 0.25) / fps))
            #expect(Synth.index(of: f.pixelBuffer) == i, "seek to frame \(i)")
        }
        // Exactly on a PTS: that frame. Just before: the previous one.
        let f30 = try await src.frame(stream: 0, at: CMTime(value: 1, timescale: 1))
        #expect(Synth.index(of: f30.pixelBuffer) == 30)
        let f29 = try await src.frame(stream: 0, at: CMTime(value: 599_999, timescale: 600_000))
        #expect(Synth.index(of: f29.pixelBuffer) == 29)
    }

    @Test func variableFrameRateHoldsAndClamps() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("vfr.mov")
        let times = [0.0, 0.1, 0.15, 0.9, 1.0, 2.5, 2.55, 4.0]
        try await Synth.writeMovie(to: url, times: times, keyInterval: 3, fileType: .mov)
        let src = try await MediaPool().source(for: url)

        func idx(_ t: Double) async throws -> Int {
            Synth.index(of: try await src.frame(stream: 0, at: secs(t)).pixelBuffer)
        }
        #expect(try await idx(0.5) == 2)   // held from 0.15 until 0.9
        #expect(try await idx(0.0) == 0)
        #expect(try await idx(-3) == 0)    // clamped
        #expect(try await idx(2.49) == 4)
        #expect(try await idx(2.5) == 5)
        #expect(try await idx(0.12) == 1)
        let last = try await src.frame(stream: 0, at: secs(100))
        #expect(Synth.index(of: last.pixelBuffer) == 7) // clamped to the last frame
        #expect(!last.duration.isValid)
        let f3 = try await src.frame(stream: 0, at: secs(0.95))
        #expect(abs(f3.presentationTime.seconds - 0.9) < 1e-3)
        #expect(abs(f3.duration.seconds - 0.1) < 1e-3)
    }

    @Test func softwareDecodeMatches() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sw.mp4")
        try await Synth.writeMovie(to: url, times: (0..<40).map { Double($0) / 30 }, keyInterval: 10)
        let dec = try VideoDecoder(url: url, streamIndex: 0, allowHardware: false)
        #expect(await !dec.isHardwareAccelerated)
        for i in [33, 2, 17, 18, 19, 39, 0] {
            let f = try await dec.frame(at: secs((Double(i) + 0.5) / 30))
            #expect(Synth.index(of: f.pixelBuffer) == i)
        }
    }

    /// Scrub (software lane), then play: the hardware lane takes over ahead of the playhead
    /// and every frame stays exact across the switch.
    @Test(arguments: [AVVideoCodecType.h264, .hevc])
    func laneHandoverKeepsFramesExact(codec: AVVideoCodecType) async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("lanes.mp4")
        let n = 150, fps = 30.0
        try await Synth.writeMovie(to: url, times: (0..<n).map { Double($0) / fps }, codec: codec, keyInterval: 20)
        let src = try #require(try await MediaPool().source(for: url) as? FFMediaSource)
        let hw = try await src.isHardwareAccelerated(stream: 0)
        for i in [100, 37] {
            let f = try await src.frame(stream: 0, at: secs((Double(i) + 0.5) / fps))
            #expect(Synth.index(of: f.pixelBuffer) == i)
        }
        for i in 37..<n {
            let f = try await src.frame(stream: 0, at: secs((Double(i) + 0.5) / fps))
            #expect(Synth.index(of: f.pixelBuffer) == i, "frame \(i)")
            if i == 50 { try await Task.sleep(nanoseconds: 300_000_000) } // let the handover land
        }
        let lanes = try await src.laneCounts(stream: 0)
        if hw {
            #expect(lanes.software > 0)
            #expect(lanes.hardware > 50, "hardware lane served \(lanes.hardware)")
        }
    }

    @Test func missingFileAndBadStream() async throws {
        let pool = MediaPool()
        let missing = URL(fileURLWithPath: "/nonexistent/x.mp4")
        await #expect(throws: MediaError.fileNotFound(missing)) { try await pool.probe(missing) }
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.mp4")
        try await Synth.writeMovie(to: url, times: [0, 0.1])
        let src = try await pool.source(for: url)
        await #expect(throws: MediaError.noSuchStream(3)) { try await src.frame(stream: 3, at: .zero) }
    }
}

@Suite struct StillAndShaderTests {
    @Test func pngIsSingleFrame() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("red.png")
        try Synth.writePNG(to: url, width: 40, height: 30, rgba: (255, 0, 0, 255))
        let pool = MediaPool()
        let info = try await pool.probe(url)
        #expect(info.kind == .image)
        #expect(info.streams.first?.pixelSize == CGSize(width: 40, height: 30))
        #expect(info.streams.first?.codec == "png")
        let src = try await pool.source(for: url)
        for t in [0.0, 5.0, 1000.0] {
            let f = try await src.frame(stream: 0, at: secs(t))
            assertBGRA(f.pixelBuffer)
            #expect(CVPixelBufferGetWidth(f.pixelBuffer) == 40)
            let p = Synth.pixel(f.pixelBuffer, x: 5, y: 5)
            #expect(p.r > 250 && p.g < 5 && p.b < 5 && p.a == 255)
        }
        let thumb = try await src.thumbnail(stream: 0, at: .zero, maxPixelSize: 20)
        #expect(thumb.width == 20 && thumb.height == 15)
    }

    @Test func jpegProbes() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("p.png")
        try Synth.writePNG(to: png, width: 16, height: 8, rgba: (0, 0, 255, 255))
        let jpg = dir.appendingPathComponent("p.jpg")
        guard Synth.ffmpegPath != nil else { return }
        try Synth.ffmpeg(["-i", png.path, jpg.path])
        let info = try await MediaPool().probe(jpg)
        #expect(info.kind == .image)
        #expect(info.streams.first?.codec == "jpeg")
    }

    @Test func shaderHasNoFrames() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("bg.tscshadervid")
        try Data(#"{"shader":"x"}"#.utf8).write(to: url)
        let pool = MediaPool()
        let info = try await pool.probe(url)
        #expect(info.kind == .shader)
        #expect(info.streams.isEmpty)
        let src = try await pool.source(for: url)
        await #expect(throws: MediaError.self) { try await src.frame(stream: 0, at: .zero) }
    }

    @Test func unknownFile() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("junk.bin")
        try Data(repeating: 7, count: 100).write(to: url)
        let pool = MediaPool()
        #expect(try await pool.probe(url).kind == .unknown)
        await #expect(throws: MediaError.self) { try await pool.source(for: url) }
    }
}

@Suite(.enabled(if: Demo.available, "demo project not installed"))
struct DemoRecordingTests {
    @Test func probeTrec() async throws {
        let info = try await MediaPool().probe(Demo.trec)
        #expect(info.kind == .recording)
        #expect(info.streams.map(\.kind) == [.video, .video, .audio])
        #expect(info.streams.map(\.codec) == ["tscc2", "h264", "aac"])
        #expect(info.streams.map(\.index) == [0, 1, 2])
        #expect(info.streams[0].pixelSize == CGSize(width: 3024, height: 1964))
        #expect(info.streams[1].pixelSize == CGSize(width: 1920, height: 1080))
        #expect(info.streams[2].sampleRate == 44100)
        #expect(info.streams[2].channelCount == 1)
        #expect(info.streams[0].nominalFrameRate > 4 && info.streams[0].nominalFrameRate < 7)
        #expect(abs(info.streams[0].duration.seconds - 25.678) < 0.01)
    }

    /// Walks every tscc2 frame sequentially, then checks random seeks return identical frames.
    @Test func tscc2SeekEqualsSequential() async throws {
        let src = try await MediaPool().source(for: Demo.trec)
        var frames: [(pts: CMTime, dur: CMTime, sum: UInt64)] = []
        var t = CMTime.zero
        while true {
            let f = try await src.frame(stream: 0, at: t)
            #expect(CVPixelBufferGetWidth(f.pixelBuffer) == 3024 && CVPixelBufferGetHeight(f.pixelBuffer) == 1964)
            frames.append((f.presentationTime, f.duration, checksum(f.pixelBuffer)))
            guard f.duration.isValid else { break }
            t = f.presentationTime + f.duration
        }
        // 137 packets, but 55 are 1-byte "unchanged" packets that libavcodec turns into no
        // picture; the previous frame holds through them (same as ffprobe -show_frames: 82).
        #expect(frames.count == 82)
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.pts < $1.pts })
        #expect(frames.first?.pts == .zero)
        var rng = SystemRandomNumberGenerator()
        for i in Array(frames.indices).shuffled(using: &rng).prefix(12) {
            let fr = frames[i]
            // Anywhere inside the frame's interval: the same frame.
            let inside = fr.dur.isValid ? fr.pts + CMTimeMultiplyByRatio(fr.dur, multiplier: 1, divisor: 2) : fr.pts + secs(1)
            let f = try await src.frame(stream: 0, at: inside)
            #expect(f.presentationTime == fr.pts)
            #expect(checksum(f.pixelBuffer) == fr.sum, "frame \(i)")
        }
    }

    @Test func cameraStreamFrames() async throws {
        let src = try await MediaPool().source(for: Demo.trec)
        let a = try await src.frame(stream: 1, at: secs(12.3))
        #expect(CVPixelBufferGetWidth(a.pixelBuffer) == 1920)
        let b = try await src.frame(stream: 1, at: secs(1))
        let c = try await src.frame(stream: 1, at: secs(12.3))
        #expect(a.presentationTime == c.presentationTime)
        #expect(checksum(a.pixelBuffer) == checksum(c.pixelBuffer))
        #expect(b.presentationTime < a.presentationTime)
        let end = try await src.frame(stream: 1, at: secs(60))
        #expect(!end.duration.isValid)
    }

    @Test func thumbnailOfScreen() async throws {
        let src = try await MediaPool().source(for: Demo.trec)
        let img = try await src.thumbnail(stream: 0, at: secs(5), maxPixelSize: 256)
        #expect(img.width == 256)
        #expect(img.height == 166)
    }
}

/// Order-sensitive checksum over the visible BGRA bytes.
func checksum(_ buf: CVPixelBuffer) -> UInt64 {
    CVPixelBufferLockBaseAddress(buf, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buf) else { return 0 }
    let w = CVPixelBufferGetWidth(buf) * 4, h = CVPixelBufferGetHeight(buf), bpr = CVPixelBufferGetBytesPerRow(buf)
    var hash: UInt64 = 0xcbf29ce484222325
    let p = base.assumingMemoryBound(to: UInt8.self)
    for y in stride(from: 0, to: h, by: 3) {
        let row = p + y * bpr
        for x in stride(from: 0, to: w, by: 7) {
            hash = (hash ^ UInt64(row[x])) &* 0x100000001b3
        }
    }
    return hash
}
