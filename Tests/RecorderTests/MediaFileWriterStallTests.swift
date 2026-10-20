import AVFoundation
import CoreMedia
import Foundation
import Testing
import WizRecTestSupport
@testable import Recorder

/// Thread-safe call counter.
private final class Calls: @unchecked Sendable {
    // @unchecked: `n` is only touched under `lock`.
    private let lock = NSLock()
    private var n = 0
    func hit() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

/// Stands in for an AVAssetWriter stuck in CoreMedia: forwards status, error and cancel to the
/// real writer, but `finishWriting` never calls back.
private final class StuckWriter: MediaWriterControl {
    let base: AVAssetWriter
    let cancels: Calls
    init(_ base: AVAssetWriter, cancels: Calls) { self.base = base; self.cancels = cancels }
    var status: AVAssetWriter.Status { base.status }
    var error: (any Error)? { base.error }
    func finishWriting(completionHandler handler: @escaping @Sendable () -> Void) {}
    func cancelWriting() { cancels.hit(); base.cancelWriting() }
}

/// EXP11-1: `MediaFileWriter.finish` never hangs on a stuck encoder.
@Suite(.serialized) struct MediaFileWriterStallTests {
    private func stuckWriter(_ url: URL, kind: MediaFileWriter.Kind, cancels: Calls) -> MediaFileWriter {
        MediaFileWriter(url: url, kind: kind, realTime: false, finishTimeout: 0.5,
                        wrapWriter: { StuckWriter($0, cancels: cancels) })
    }

    /// Finishes `writer` on its own task; expects `encoderStalled` well before the bound, the file
    /// removed and the writer cancelled.
    private func expectStall(_ writer: MediaFileWriter, cancels: Calls) async throws {
        let clock = ContinuousClock()
        let began = clock.now
        let task = Task { try await writer.finish(at: CMTime(value: 1, timescale: 1)) }
        await #expect(throws: MediaFileWriter.WriterError.encoderStalled(seconds: 1)) {
            _ = try await Deadline.value(of: task, "stuck writer finish to fail", seconds: 60)
        }
        let took = clock.now - began
        #expect(took < .seconds(30), "finish took \(took)")
        try await Deadline.poll("abandoned writer to be cancelled", seconds: 10, interval: 0.01) { cancels.value > 0 }
        #expect(!FileManager.default.fileExists(atPath: writer.url.path))
    }

    @Test func stuckVideoFinishFails() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cancels = Calls()
        let writer = stuckWriter(dir.appendingPathComponent("screen.mp4"), kind: .video(codec: .h264, frameRate: 30),
                                 cancels: cancels)
        for k in 0..<5 {
            let t = CMTime(value: Int64(k), timescale: 30)
            writer.append(Synth.videoFrame(grey: UInt8(k * 40), time: t), at: t)
        }
        #expect(writer.appendedCount == 5)
        try await expectStall(writer, cancels: cancels)
    }

    @Test func stuckAudioFinishFails() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cancels = Calls()
        let writer = stuckWriter(dir.appendingPathComponent("mic.m4a"), kind: .audio, cancels: cancels)
        for k in 0..<10 {
            let t = CMTime(value: Int64(k) * 960, timescale: 48_000)
            writer.append(Synth.audioBuffer(time: t), at: t)
        }
        #expect(writer.appendedCount == 10)
        try await expectStall(writer, cancels: cancels)
    }

    @Test func stallErrorDescribesItself() {
        #expect(MediaFileWriter.defaultFinishTimeout == 60)
        #expect(String(describing: MediaFileWriter.WriterError.encoderStalled(seconds: 60))
            == "the encoder stopped responding for 60 s; the file was not finished and was removed")
        #expect(String(describing: MediaFileWriter.WriterError.failed("disk full")) == "disk full")
    }
}
