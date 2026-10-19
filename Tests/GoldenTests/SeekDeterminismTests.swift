import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import MediaEngine
import Testing
import TestGenKit

// S3-QA-1 flake hunt: the render pipeline's frame N differed from the sequential
// path only when the decoder reached the source frame by a seek instead of by
// decoding forward. Root cause is in MediaEngine: a seek to frame N of an H.264
// file returns frame N (right label) with different, less accurate pixels than
// decoding forward to N. Every frame of a source must be byte-identical however
// it is reached, or export/preview depend on what was decoded before.

/// Visible BGRA bytes of a 32BGRA buffer.
private func bgra(_ pb: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return [] }
    let rb = CVPixelBufferGetBytesPerRow(pb), w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    var out: [UInt8] = []
    out.reserveCapacity(w * h * 4)
    for y in 0..<h { out.append(contentsOf: UnsafeRawBufferPointer(start: base + y * rb, count: w * 4)) }
    return out
}

@Suite(.serialized) struct SeekDeterminismTests {
    /// H.264 test card (GOP 30, as `MediaWriter.writeH264` encodes): frame N decoded right after
    /// opening (a seek) equals frame N reached by decoding every frame from 0.
    @Test func seekedFrameEqualsSequentiallyDecodedFrame() async throws {
        let dir = try scratchDir("seek-determinism")
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = dir.appendingPathComponent("card.mp4")
        let card = TestCard(width: 160, height: 90, label: "S")
        _ = try MediaWriter.writeH264(to: movie, width: 160, height: 90, fps: 30, frameCount: 90) { n, ctx in
            card.draw(frame: n, fps: 30, in: ctx)
        }
        let seq = try await MediaPool(diskCacheDirectory: nil).source(for: movie)
        let v = try #require(seq.info.streams.first { $0.kind == .video })
        var sequential: [[UInt8]] = []
        for n in 0..<90 {
            sequential.append(bgra(try await seq.frame(stream: v.index, at: CMTime(value: Int64(n), timescale: 30)).pixelBuffer))
        }
        var differing: [Int] = []
        for n in stride(from: 0, to: 90, by: 1) {
            let fresh = try await MediaPool(diskCacheDirectory: nil).source(for: movie)
            let f = bgra(try await fresh.frame(stream: v.index, at: CMTime(value: Int64(n), timescale: 30)).pixelBuffer)
            if f != sequential[n] { differing.append(n) }
        }
        #expect(differing.isEmpty, "seek vs sequential differs at frames \(differing)")
    }
}
