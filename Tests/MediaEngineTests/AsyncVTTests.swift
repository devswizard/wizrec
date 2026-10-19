// The asynchronous VideoToolbox path (several frames in flight) keeps the frame rule exact.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import MediaEngine

private func secs(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600_000) }

/// Mean absolute BGR difference of two equally sized BGRA buffers (every 4th pixel).
private func mae(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
    CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    guard let pa = CVPixelBufferGetBaseAddress(a)?.assumingMemoryBound(to: UInt8.self),
          let pb = CVPixelBufferGetBaseAddress(b)?.assumingMemoryBound(to: UInt8.self),
          CVPixelBufferGetWidth(a) == CVPixelBufferGetWidth(b), CVPixelBufferGetHeight(a) == CVPixelBufferGetHeight(b)
    else { return 255 }
    let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
    let ra = CVPixelBufferGetBytesPerRow(a), rb = CVPixelBufferGetBytesPerRow(b)
    var sum = 0.0, n = 0
    for y in stride(from: 0, to: h, by: 4) {
        for x in stride(from: 0, to: w, by: 4) {
            for c in 0..<3 { sum += Double(abs(Int(pa[y * ra + x * 4 + c]) - Int(pb[y * rb + x * 4 + c]))); n += 1 }
        }
    }
    return sum / Double(max(1, n))
}

@Suite struct AsyncVideoToolboxTests {
    /// h264 with B-frames (reordering) and hevc: sequential, random seeks, exact PTS edges.
    @Test(arguments: [AVVideoCodecType.h264, .hevc])
    func seekEqualsSequential(codec: AVVideoCodecType) async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.mp4")
        let n = 120, fps = 30.0
        try await Synth.writeMovie(to: url, times: (0..<n).map { Double($0) / fps }, codec: codec, keyInterval: 25)
        let dec = try VideoDecoder(url: url, streamIndex: 0, allowHardware: true)
        let async = await dec.isAsyncVideoToolbox
        guard async else { return } // no hardware decoder for this codec here
        var seq: [Int] = []
        for i in 0..<n { seq.append(Synth.index(of: try await dec.frame(at: secs((Double(i) + 0.5) / fps)).pixelBuffer)) }
        #expect(seq == Array(0..<n))
        var rng = SystemRandomNumberGenerator()
        for i in (0..<n).shuffled(using: &rng).prefix(40) {
            #expect(Synth.index(of: try await dec.frame(at: secs((Double(i) + 0.25) / fps)).pixelBuffer) == i, "seek \(i)")
        }
        #expect(Synth.index(of: try await dec.frame(at: CMTime(value: 2, timescale: 1)).pixelBuffer) == 60)
        #expect(Synth.index(of: try await dec.frame(at: CMTime(value: 1_999_999, timescale: 1_000_000)).pixelBuffer) == 59)
        // Skipping ahead (high clip speed) stays exact.
        for i in stride(from: 3, to: n, by: 7) {
            #expect(Synth.index(of: try await dec.frame(at: secs((Double(i) + 0.5) / fps)).pixelBuffer) == i, "skip \(i)")
        }
        let last = try await dec.frame(at: secs(1000))
        #expect(Synth.index(of: last.pixelBuffer) == n - 1)
        #expect(!last.duration.isValid)
        #expect(await dec.isAsyncVideoToolbox) // never fell back to software
    }

    @Test func variableFrameRateHolds() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("vfr.mov")
        try await Synth.writeMovie(to: url, times: [0.0, 0.1, 0.15, 0.9, 1.0, 2.5, 2.55, 4.0], keyInterval: 3, fileType: .mov)
        let dec = try VideoDecoder(url: url, streamIndex: 0, allowHardware: true)
        guard await dec.isAsyncVideoToolbox else { return }
        for (t, want) in [(0.5, 2), (0.0, 0), (2.49, 4), (2.5, 5), (0.12, 1), (3.0, 6), (9.0, 7)] {
            #expect(Synth.index(of: try await dec.frame(at: secs(t)).pixelBuffer) == want, "t \(t)")
        }
    }

    /// The user's DJI footage: async VideoToolbox and software lanes give the same pictures.
    @Test(.enabled(if: Vlog.sample != nil, "vlog project not installed"))
    func djiMatchesSoftware() async throws {
        let url = try #require(Vlog.sample)
        let hw = try VideoDecoder(url: url, streamIndex: 0, allowHardware: true)
        let sw = try VideoDecoder(url: url, streamIndex: 0, allowHardware: false)
        #expect(await hw.isAsyncVideoToolbox)
        for frame in [0, 61, 150, 151, 152] {
            let t = CMTime(value: Int64(1001 * frame), timescale: 60000)
            let a = try await hw.frame(at: t), b = try await sw.frame(at: t)
            #expect(a.presentationTime == b.presentationTime)
            #expect(mae(a.pixelBuffer, b.pixelBuffer) < 2.5, "frame \(frame)")
        }
    }
}
