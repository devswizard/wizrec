import AVFoundation
import CoreMedia
import Foundation
import Testing
import WizRecTestSupport
@testable import Recorder

/// Stands in for an AVAssetWriter stuck in CoreMedia: `finishWriting` never calls back.
private final class StuckFinish: MediaWriterControl {
    let base: AVAssetWriter
    init(_ base: AVAssetWriter) { self.base = base }
    var status: AVAssetWriter.Status { base.status }
    var error: (any Error)? { base.error }
    func finishWriting(completionHandler handler: @escaping @Sendable () -> Void) {}
    func cancelWriting() { base.cancelWriting() }
}

/// QA11-3 (EXP11-1 merged): a stuck encoder of one recording file reaches the user. A stuck
/// camera/audio writer becomes a warning of the finished recording (the screen file is kept);
/// a stuck screen writer fails the recording with `RecorderError.failed`. No capture permission:
/// writers are injected through `installWritersForTesting`.
@Suite(.serialized) @MainActor struct RecordingEngineStallTests {
    private let stalled = "the encoder stopped responding for 1 s; the file was not finished and was removed"

    private func writer(_ url: URL, _ kind: MediaFileWriter.Kind, stuck: Bool) -> MediaFileWriter {
        guard stuck else { return MediaFileWriter(url: url, kind: kind, realTime: false, finishTimeout: 0.5) }
        return MediaFileWriter(url: url, kind: kind, realTime: false, finishTimeout: 0.5,
                               wrapWriter: { StuckFinish($0) })
    }

    private func feedVideo(_ w: MediaFileWriter) {
        for k in 0..<5 {
            let t = CMTime(value: Int64(k), timescale: 30)
            w.append(Synth.videoFrame(grey: UInt8(k * 40), time: t), at: t)
        }
    }

    private func engine(_ dir: URL) -> RecordingEngine {
        RecordingEngine(options: RecordingOptions(target: .display(0), outputDirectory: dir))
    }

    @Test func stuckCameraWriterBecomesAWarning() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let screen = writer(dir.appendingPathComponent(RecordingFiles.screen), .video(codec: .h264, frameRate: 30), stuck: false)
        let camera = writer(dir.appendingPathComponent(RecordingFiles.camera), .video(codec: .h264, frameRate: 30), stuck: true)
        let mic = writer(dir.appendingPathComponent(RecordingFiles.microphone), .audio, stuck: false)
        feedVideo(screen)
        feedVideo(camera)
        let e = engine(dir)
        e.installWritersForTesting(screen: screen, camera: camera, mic: mic)

        let finish = Task { @MainActor in try await e.finish() }
        let result = try await Deadline.value(of: finish, "recording with a stuck camera encoder to finish", seconds: 60)
        #expect(e.warnings.contains("camera: \(stalled)"), "\(e.warnings)")
        #expect(e.warnings.contains("microphone: no samples recorded"), "\(e.warnings)")
        #expect(result.camera == nil)
        #expect(result.screen == screen.url && FileManager.default.fileExists(atPath: screen.url.path))
        #expect(!FileManager.default.fileExists(atPath: camera.url.path), "stuck camera file left behind")
        let back = try await readBack(result.screen, type: .video)
        #expect(!back.pts.isEmpty, "screen file has no frames") // the kept file is readable
    }

    @Test func stuckScreenWriterFailsTheRecording() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let screen = writer(dir.appendingPathComponent(RecordingFiles.screen), .video(codec: .h264, frameRate: 30), stuck: true)
        feedVideo(screen)
        let e = engine(dir)
        e.installWritersForTesting(screen: screen)

        let finish = Task { @MainActor in try await e.finish() }
        await #expect(throws: RecorderError.failed("screen video: \(stalled)")) {
            _ = try await Deadline.value(of: finish, "recording with a stuck screen encoder to fail", seconds: 60)
        }
        #expect(!FileManager.default.fileExists(atPath: screen.url.path))
    }
}
