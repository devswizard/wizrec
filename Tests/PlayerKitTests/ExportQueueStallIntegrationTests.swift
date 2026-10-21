import AVFoundation
import Foundation
import MediaEngine
import Metal
import PlayerKit
import TestGenKit
import Testing
import WizRecTestSupport
@testable import Exporter

/// Stands in for an AVAssetWriter stuck in CoreMedia: forwards status, error and cancel to the
/// real writer, but `finishWriting` never calls back.
private final class NeverFinishing: FinishableWriter {
    let base: AVAssetWriter
    init(_ base: AVAssetWriter) { self.base = base }
    var status: AVAssetWriter.Status { base.status }
    var error: (any Error)? { base.error }
    func finishWriting(completionHandler handler: @escaping @Sendable () -> Void) {}
    func cancelWriting() { base.cancelWriting() }
}

/// QA11-3 (EXP11-1 merged): an encoder that stops responding fails its export-queue job with a
/// readable sentence and no partial file, and the batch goes on with the next job. The runner
/// mirrors `EditorWindowController.makeExportQueue` (the app target is not testable).
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
@MainActor struct ExportQueueStallIntegrationTests {
    @Test func stalledEncoderFailsItsJobAndTheBatchGoesOn() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qa11-stall-\(UUID().uuidString)",
                                                                              isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let card = TestCard(width: 320, height: 180, label: "S")
        let movie = dir.appendingPathComponent("card.mp4")
        try await MediaWriter.writeH264(to: movie, width: 320, height: 180, fps: 30, frameCount: 15) { n, ctx in
            card.draw(frame: n, fps: 30, in: ctx)
        }
        let doc = try EditorDocumentModel.untitled(width: 320, height: 180, in: dir)
        _ = try await doc.importAndInsert(movie, at: 0)

        var settings = ExportSettings(format: .mp4(codec: "h264", bitrate: nil))
        settings.includeAudio = false
        let scene = doc.scene, audio = doc.audioScene
        let stuckJobs = Set([1])
        let queue = ExportQueue { id, output, progress in
            let session = ExportSession(scene: scene, audio: audio, pool: MediaPool(diskCacheDirectory: nil),
                                        settings: settings, output: output)
            await session.setProgressHandler(progress)
            let hooks = stuckJobs.contains(id) ? WriterHooks(wrapWriter: { NeverFinishing($0) }) : WriterHooks()
            try await ExportSession.$writerHooks.withValue(hooks) {
                try await ExportSession.$writerTimeouts.withValue(WriterTimeouts(finish: 0.5, stall: 0.3, cancel: 2)) {
                    try await session.run()
                }
            }
            progress(1)
        }
        let stuckOut = dir.appendingPathComponent("stuck.mp4"), okOut = dir.appendingPathComponent("ok.mp4")
        let first = queue.add(name: "stuck", output: stuckOut)
        let second = queue.add(name: "ok", output: okOut)
        #expect(stuckJobs.contains(first) && !stuckJobs.contains(second))

        let idle = Task { @MainActor in await queue.waitUntilIdle() }
        try await Deadline.value(of: idle, "export queue to finish both jobs", seconds: 120)

        let states = queue.jobs.map(\.state)
        #expect(states == [
            .failed("The encoder stopped responding for 1 s. The export was stopped and the partial file removed."),
            .done,
        ], "\(states)")
        #expect(!FileManager.default.fileExists(atPath: stuckOut.path), "partial file of the stalled job left behind")
        #expect(queue.activeJobCount == 0 && !queue.isRunning)
        #expect(queue.overallProgress == 1)

        // The job after the stall wrote a complete, decodable movie.
        let info = try await MovieFrameReader.info(okOut)
        #expect(info.width == 320 && info.height == 180)
        let frames = try await MovieFrameReader.frames(okOut, indices: [0, 14])
        #expect(card.decodeFrameNumber(try #require(frames[14])) == 14)
    }
}
