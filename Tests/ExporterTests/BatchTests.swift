import CoreGraphics
import Foundation
import MediaEngine
import Testing
import TSCProjKit
import WizRecTestSupport
@testable import Exporter

struct PresetTests {
    @Test func presetsAreNamedUniquelyAndValid() {
        let p = ExportSession.presets
        #expect(p.count >= 10)
        #expect(Set(p.map(\.name)).count == p.count)
        for preset in p {
            if case .gif(let fps) = preset.settings.format { #expect(fps > 0 && !preset.settings.includeAudio) }
            if let s = preset.settings.size { #expect(s.width > 0 && s.height > 0) }
        }
        #expect(p.contains { $0.settings.format == .mov(profile: "4444") })
        #expect(p.contains { $0.settings.format == .audio(container: "mp3") })
    }

    @Test func fileExtensions() {
        #expect(ExportFormat.mp4(codec: "hevc", bitrate: nil).fileExtension == "mp4")
        #expect(ExportFormat.mov(profile: "422").fileExtension == "mov")
        #expect(ExportFormat.gif(fps: 10).fileExtension == "gif")
        #expect(ExportFormat.audio(container: "AAC").fileExtension == "m4a")
        #expect(ExportFormat.audio(container: "wav").fileExtension == "wav")
    }
}

@Suite(.enabled(if: hasGPU), .serialized) struct BatchTests {
    @Test func runsEveryJobAndKeepsGoingAfterAFailure() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await movingProject(frames: 6)
        var mp4 = ExportSettings(format: .mp4(codec: "h264", bitrate: nil)); mp4.includeAudio = false
        let bad = ExportSettings(format: .mp4(codec: "vp9", bitrate: nil))
        let gif = ExportSettings(format: .gif(fps: 10))
        let wav = ExportSettings(format: .audio(container: "wav"))
        let jobs = [
            ExportBatch.Job(settings: mp4, output: dir.appendingPathComponent("a.mp4")),
            ExportBatch.Job(settings: bad, output: dir.appendingPathComponent("b.mp4")),
            ExportBatch.Job(settings: gif, output: dir.appendingPathComponent("c.gif")),
            ExportBatch.Job(settings: wav, output: dir.appendingPathComponent("d.wav")),
        ]
        let batch = ExportBatch(scene: p.scene, audio: p.audio, pool: MediaPool(), jobs: jobs)
        let outcomes = await batch.run()
        #expect(outcomes.count == 4)
        #expect(outcomes[0] == .completed(jobs[0].output))
        if case .failed(let url, _) = outcomes[1] { #expect(url == jobs[1].output) } else { Issue.record("\(outcomes[1])") }
        #expect(outcomes[2] == .completed(jobs[2].output))
        #expect(outcomes[3] == .completed(jobs[3].output))
        #expect(await batch.progress == 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(files == ["a.mp4", "c.gif", "d.wav"])
    }

    @Test func cancelSkipsRemainingJobs() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await movingProject(frames: 290)
        var s = ExportSettings(format: .mp4(codec: "h264", bitrate: nil)); s.includeAudio = false
        let jobs = (0..<3).map { ExportBatch.Job(settings: s, output: dir.appendingPathComponent("\($0).mp4")) }
        let batch = ExportBatch(scene: p.scene, audio: p.audio, pool: MediaPool(), jobs: jobs)
        let run = Task { await batch.run() }
        try await Deadline.poll("batch progress to start", seconds: 60, interval: 0.001) { await batch.progress > 0 }
        await batch.cancel()
        let outcomes = try await Deadline.value(of: run, "batch to stop after cancel", seconds: 60)
        // The first job may finish before the cancel lands (exports run faster than real time);
        // every job after the cancel is skipped and leaves no file.
        let done = outcomes.prefix { if case .completed = $0 { true } else { false } }.count
        #expect(done < jobs.count)
        let skipped: [ExportBatch.Outcome] = jobs[done...].map { (j) -> ExportBatch.Outcome in .skipped(j.output) }
        #expect(Array(outcomes[done...]) == skipped)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(files == jobs[..<done].map(\.output.lastPathComponent))
    }

    /// S3-EXP-2 at batch level.
    @Test func batchConfirmBeforeCancelHook() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await movingProject(frames: 290)
        var s = ExportSettings(format: .mp4(codec: "h264", bitrate: nil)); s.includeAudio = false
        let jobs = (0..<3).map { ExportBatch.Job(settings: s, output: dir.appendingPathComponent("\($0).mp4")) }
        let batch = ExportBatch(scene: p.scene, audio: p.audio, pool: MediaPool(), jobs: jobs)
        #expect(await batch.cancellationLosesWork == false)
        let run = Task { await batch.run() }
        try await Deadline.poll("batch progress to start", seconds: 60, interval: 0.001) { await batch.progress > 0 }
        #expect(await batch.cancellationLosesWork)
        await batch.cancelAndWait()
        #expect(await batch.cancellationLosesWork == false)
        let outcomes = try await Deadline.value(of: run, "batch to stop after cancel", seconds: 60)
        let done = outcomes.prefix { if case .completed = $0 { true } else { false } }.count
        #expect(done < jobs.count)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(files == jobs[..<done].map(\.output.lastPathComponent))
    }
}
