import CoreGraphics
import Foundation
import Testing
import TestGenKit
import WizRecTestSupport

/// QA12-3: `ownRenderPassesAndOneFrameLateFails` once read 176 of 180 reference frames and a
/// wrong fps at a load average of ~400. This writes the same kind of reference (1080p H.264,
/// 40 Mbit/s) again and again and checks what landed in the file: the sample count in the
/// box tree, the nominal frame rate and the frames a sequential read returns. Opt-in
/// (`WIZREC_STRESS=1`, run it beside a load generator); `WIZREC_STRESS_ROUNDS` sets the count.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["WIZREC_STRESS"] == "1",
                             "set WIZREC_STRESS=1 (with a load generator) to run"))
struct WriterUnderLoadTests {
    @Test func referenceMoviesKeepEveryFrame() async throws {
        let dir = try scratchDir("writer-load")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rounds = Int(ProcessInfo.processInfo.environment["WIZREC_STRESS_ROUNDS"] ?? "") ?? 10
        let (w, h, n) = (1920, 1080, 180)
        let card = TestCard(width: w, height: h, label: "L")
        for round in 0..<rounds {
            let url = dir.appendingPathComponent("ref-\(round).mp4")
            let load = LoadGate.loadAverage
            try await MediaWriter.writeH264(to: url, width: w, height: h, fps: 30, frameCount: n,
                                            bitsPerSecond: 40_000_000) { i, ctx in card.draw(frame: i, fps: 30, in: ctx) }
            let boxes = MP4SampleCount.videoTracks(url)
            let info = try await MovieFrameReader.info(url)
            var read = 0
            try await MovieFrameReader.forEachFrame(url) { i, _, _ in read = i + 1; return true }
            print("writer-load round \(round): load \(String(format: "%.0f", load)), stsz \(boxes ?? []), "
                  + "fps \(info.fps), read \(read)")
            #expect(boxes == [n], "round \(round) at load \(load): stsz \(String(describing: boxes))")
            #expect(abs(info.fps - 30) < 0.01, "round \(round) at load \(load): \(info.fps) fps")
            #expect(read == n, "round \(round) at load \(load): read \(read) of \(n) frames")
            try? FileManager.default.removeItem(at: url)
        }
    }
}
