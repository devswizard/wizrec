import AudioEngine
import Foundation
import MediaEngine
import RenderEngine
import Testing
import WizRecTestSupport
import TSCProjKit
@testable import Exporter

let demoBundle = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Documents/demo project.cmproj")
let perfEnabled = ProcessInfo.processInfo.environment["WIZREC_PERF"] == "1"
    && FileManager.default.fileExists(atPath: demoBundle.path)

/// Export speed on a temp copy of the user's demo project (the original is never opened for writing).
/// Runs only with `WIZREC_PERF=1`; target: 1080p30 H.264 ≥ 4× real time (S3-EXP-3). Needs a quiet
/// machine: under heavy load (load average > 30) exports drop to 2.5–3×, so `LoadGate` reports
/// the number as a known issue there instead of failing.
/// Measure in release (`WIZREC_PERF=1 swift test -c release -Xswiftc -enable-testing --filter
/// ExportPerfTests`): in debug the unspecialised DSP code (noise removal) makes the audio mix ~25×
/// slower (demo: 4.1 s vs 0.16 s) and it, not video, sets the export time.
@Suite(.enabled(if: perfEnabled && hasGPU), .serialized) struct ExportPerfTests {
    @MainActor private func demo(in dir: URL) throws -> (SceneModel, AudioScene) {
        let copy = dir.appendingPathComponent("demo.cmproj")
        try FileManager.default.copyItem(at: demoBundle, to: copy)
        let bundle = try ProjectBundle(url: copy)
        return (SceneModel(project: bundle.project, resolve: bundle.resolve),
                AudioScene(project: bundle.project, resolve: bundle.resolve))
    }

    @Test(arguments: [
        ExportFormat.mp4(codec: "h264", bitrate: nil),
        ExportFormat.mp4(codec: "hevc", bitrate: nil),
        ExportFormat.mov(profile: "422"),
    ])
    func demo1080p30(_ format: ExportFormat) async throws {
        try await measure(format, audio: true)
    }

    /// The same exports without the audio track: the difference to `demo1080p30` is what audio costs.
    @Test(arguments: [ExportFormat.mp4(codec: "h264", bitrate: nil), ExportFormat.mov(profile: "422")])
    func demo1080p30VideoOnly(_ format: ExportFormat) async throws {
        try await measure(format, audio: false)
    }

    /// The mix alone (WAV): a movie export cannot finish faster than this.
    @Test func demoAudioOnly() async throws {
        try await measure(.audio(container: "wav"), audio: true)
    }

    private func measure(_ format: ExportFormat, audio withAudio: Bool) async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let (scene, audio) = try await demo(in: dir)
        var s = ExportSettings(format: format)
        s.includeAudio = withAudio
        s.size = CGSize(width: 1920, height: 1080)
        s.frameRate = Rational(30)
        let out = dir.appendingPathComponent("demo.\(format.fileExtension)")
        let session = ExportSession(scene: scene, audio: audio, pool: MediaPool(), settings: s, output: out)
        let t0 = Date()
        try await session.run()
        let elapsed = Date().timeIntervalSince(t0)
        let length = scene.timebase.seconds(scene.duration)
        let speed = length / elapsed
        let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        print(String(format: "export perf %@%@: %.2f s of video in %.2f s = %.2f× real time, %.1f MB",
                     "\(format)", withAudio ? "" : " (no audio)", length, elapsed, speed, Double(bytes) / 1e6))
        if withAudio, case .mp4(let codec, _) = format, codec == "h264" {
            LoadGate.expect(speed >= 4, String(format: "1080p30 H.264 export ≥ 4× real time, got %.2f×", speed))
        }
    }
}
