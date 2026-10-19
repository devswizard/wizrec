import AudioEngine
import Foundation
import MediaEngine
import RenderEngine
import Testing
import TSCProjKit
@testable import Exporter

let demoBundle = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Documents/demo project.cmproj")
let perfEnabled = ProcessInfo.processInfo.environment["WIZREC_PERF"] == "1"
    && FileManager.default.fileExists(atPath: demoBundle.path)

/// Export speed on the user's demo project (read only; output in a temp dir).
/// Runs only with `WIZREC_PERF=1`; target: 1080p30 H.264 ≥ 4× real time (S3-EXP-3). Needs a quiet
/// machine: under heavy load (load average > 30) exports drop to 2.5–3×, so `LoadGate` reports
/// the number as a known issue there instead of failing.
@Suite(.enabled(if: perfEnabled && hasGPU), .serialized) struct ExportPerfTests {
    @MainActor private func demo() throws -> (SceneModel, AudioScene) {
        let bundle = try ProjectBundle(url: demoBundle)
        return (SceneModel(project: bundle.project, resolve: bundle.resolve),
                AudioScene(project: bundle.project, resolve: bundle.resolve))
    }

    @Test(arguments: [
        ExportFormat.mp4(codec: "h264", bitrate: nil),
        ExportFormat.mp4(codec: "hevc", bitrate: nil),
        ExportFormat.mov(profile: "422"),
    ])
    func demo1080p30(_ format: ExportFormat) async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let (scene, audio) = try await demo()
        var s = ExportSettings(format: format)
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
        print(String(format: "export perf %@: %.2f s of video in %.2f s = %.2f× real time, %.1f MB",
                     "\(format)", length, elapsed, speed, Double(bytes) / 1e6))
        if case .mp4(let codec, _) = format, codec == "h264" {
            LoadGate.expect(speed >= 4, String(format: "1080p30 H.264 export ≥ 4× real time, got %.2f×", speed))
        }
    }
}
