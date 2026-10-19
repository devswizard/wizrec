import AudioEngine
import CoreMedia
import Exporter
import Foundation
import MediaEngine
import RenderEngine
import Testing
import TestGenKit
import TimelineEngine
import TSCProjKit

// Wave B integration (M9 acceptance): export frame N == preview frame N, and
// audio in sync with video to within one frame. Synthetic media only.
// Each test returns early (logged) while `ExportSession.run()` still throws
// `.notImplemented`, so the suite is ready before Exporter lands.

private let W = 480, H = 270

/// Edited project: test-card clip split at frame 20, right half moved to frame 30
/// (frames 20–29 show the background); a one-cycle click at timeline 1.0 s on track 1.
@MainActor
private struct ExportFixture {
    let bundle: ProjectBundle
    let card: TestCard
    /// Timeline time of the click onset, seconds.
    let clickAt = 1.0

    init(in dir: URL) throws {
        bundle = try ProjectBundle.create(at: dir.appendingPathComponent("exp.cmproj"), width: W, height: H)
        card = TestCard(width: W, height: H, label: "E")
        let movie = dir.appendingPathComponent("card.mp4")
        let card = self.card
        try MediaWriter.writeH264(to: movie, width: W, height: H, fps: 30, frameCount: 60, bitsPerSecond: 8_000_000) { n, ctx in
            card.draw(frame: n, fps: 30, in: ctx)
        }
        // 2 s of silence with a 1 kHz one-cycle click at 0.5 s.
        var pcm = [Float](repeating: 0, count: 96_000)
        for i in 0..<48 { pcm[24_000 + i] = 0.8 * Float(sin(2 * Double.pi * Double(i) / 48)) }
        let wav = dir.appendingPathComponent("click.wav")
        try AudioSignals.writeWAV(pcm, to: wav)

        let chain = EditChain(bundle.project)
        let v = AddSource(SourceDescriptor(src: try bundle.importFile(movie), lastModified: Date(timeIntervalSince1970: 1_792_000_000), tracks: [
            .init(type: 0, editRate: 30, rangeEnd: 60, width: W, height: H, sampleRate: Rational(30), bitDepth: 24, channelCount: 0),
        ]))
        let a = AddSource(SourceDescriptor(src: try bundle.importFile(wav), lastModified: Date(timeIntervalSince1970: 1_792_000_000), tracks: [
            .init(type: 2, editRate: 48_000, rangeEnd: 96_000, width: 0, height: 0, sampleRate: Rational(48_000), bitDepth: 16, channelCount: 1),
        ]))
        try chain.run(v); try chain.run(a)
        let vsrc = try #require(v.sourceID)
        let vid = try #require(try chain.run(InsertClip(sourceID: vsrc, track: 0, start: 0)).clipID)
        let split = try chain.run(SplitClip(clipID: vid, at: frames(20)))
        try chain.run(MoveClip(clipID: try #require(split.rightID), toTrack: 0, start: frames(30)))
        try chain.run(AddTrack(at: 1))
        let aid = try #require(a.sourceID)
        try chain.run(InsertClip(sourceID: aid, track: 1, start: frames(15)))  // click lands at 0.5 + 0.5 s
    }

    var scene: SceneModel { SceneModel(project: bundle.project, resolve: bundle.resolve) }
    var audio: AudioScene { AudioScene(project: bundle.project, resolve: bundle.resolve) }

    /// Runs an export; nil (logged) while Exporter is still a stub.
    func export(_ settings: ExportSettings, to url: URL) async throws -> ExportSession? {
        let session = ExportSession(scene: scene, audio: audio, pool: MediaPool(diskCacheDirectory: nil),
                                    settings: settings, output: url)
        do {
            try await session.run()
        } catch ExportError.notImplemented {
            print("export integration: Exporter not implemented yet, skipped")
            return nil
        }
        return session
    }
}

/// Index of the first sample whose magnitude exceeds `threshold`.
private func onset(_ x: [Float], threshold: Float = 0.2) -> Int? { x.firstIndex { abs($0) > threshold } }

@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor struct ExportIntegrationTests {

    /// Exported frame N shows what the preview renderer draws at frame N (SSIM ≥ 0.95 through
    /// H.264) and the same source frame (barcode), across a split and a gap.
    @Test func exportFrameMatchesPreviewFrame() async throws {
        let dir = try scratchDir("exp-frames")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = try ExportFixture(in: dir)
        var settings = ExportSettings(format: .mp4(codec: "h264", bitrate: 8_000_000))
        settings.includeAudio = false
        let out = dir.appendingPathComponent("out.mp4")
        guard let session = try await f.export(settings, to: out) else { return }
        #expect(await session.progress == 1)

        let info = try await MovieFrameReader.info(out)
        #expect(info.width == W && info.height == H)
        #expect(abs(info.fps - 30) < 0.01)
        let expectedFrames = Int(f.bundle.project.duration / frameTicks)
        #expect(abs(info.duration * 30 - Double(expectedFrames)) < 0.5, "duration \(info.duration) s")

        // Frame → source frame shown (nil = background in the gap).
        // Video ends at frame 70; the click's audio clip runs to 2.5 s (frame 75), so the tail is background.
        #expect(expectedFrames == 75)
        let probes: [Int: Int?] = [0: 0, 7: 7, 19: 19, 20: nil, 25: nil, 30: 20, 41: 31, 69: 59, 72: nil]
        let exported = try await MovieFrameReader.frames(out, indices: Array(probes.keys))
        let renderer = OfflineRenderer(scene: f.scene, pool: MediaPool())
        for (n, source) in probes.sorted(by: { $0.key < $1.key }) {
            let got = try #require(exported[n], "frame \(n) missing")
            let preview = RGBAImage(try await renderer.image(at: Int64(n) * frameTicks, size: CGSize(width: W, height: H)))
            let ssim = Metrics.ssim(preview, got).mean
            #expect(ssim >= 0.95, "frame \(n): export vs preview SSIM \(ssim)")
            #expect(f.card.decodeFrameNumber(got) == source, "frame \(n) shows source \(String(describing: f.card.decodeFrameNumber(got)))")
        }
    }

    /// The click's onset in the exported audio sits at 1.0 s ± one frame (encoder priming must be
    /// compensated), and video frame 0 starts at time 0.
    @Test func audioStaysInSyncWithinOneFrame() async throws {
        let dir = try scratchDir("exp-sync")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = try ExportFixture(in: dir)
        let out = dir.appendingPathComponent("out.mp4")
        guard try await f.export(ExportSettings(format: .mp4(codec: "h264", bitrate: nil)), to: out) != nil else { return }

        let src = try await MediaPool(diskCacheDirectory: nil).source(for: out)
        let audioStream = try #require(src.info.streams.first { $0.kind == .audio }, "no audio track")
        let videoStream = try #require(src.info.streams.first { $0.kind == .video })
        let pcm = try await src.audio(stream: audioStream.index,
                                      range: CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 48_000)),
                                      format: PCMFormat(sampleRate: 48_000, channels: 1))
        let at = try #require(onset(pcm.channels[0]), "click not found in the export")
        let seconds = Double(at) / 48_000 + pcm.startTime.seconds
        #expect(abs(seconds - f.clickAt) <= 1.0 / 30, "click at \(seconds) s, expected \(f.clickAt) s (±1 frame)")
        let first = try await src.frame(stream: videoStream.index, at: .zero)
        #expect(first.presentationTime.seconds.magnitude < 1e-3, "first video frame at \(first.presentationTime.seconds) s")
    }

    /// Audio-only WAV export equals the mixer's output (16-bit quantisation aside).
    @Test func wavExportEqualsMixer() async throws {
        let dir = try scratchDir("exp-wav")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = try ExportFixture(in: dir)
        let out = dir.appendingPathComponent("out.wav")
        guard try await f.export(ExportSettings(format: .audio(container: "wav")), to: out) != nil else { return }
        let rate = Double(f.bundle.project.audioSampleRate)
        let mix = try await AudioMixer(scene: f.audio, pool: MediaPool(diskCacheDirectory: nil),
                                       format: MixFormat(sampleRate: rate, channels: 2)).render(0 ..< f.bundle.project.duration)
        let src = try await MediaPool(diskCacheDirectory: nil).source(for: out)
        let s = try #require(src.info.streams.first { $0.kind == .audio })
        let wav = try await src.audio(stream: s.index, range: CMTimeRange(start: .zero, duration: s.duration),
                                      format: PCMFormat(sampleRate: rate, channels: 2))
        #expect(abs(wav.frameCount - mix.frameCount) <= 1, "wav \(wav.frameCount) vs mix \(mix.frameCount) samples")
        let n = min(wav.frameCount, mix.frameCount)
        let worst = (0..<n).reduce(Float(0)) { max($0, abs(wav.channels[0][$1] - mix.channels[0][$1])) }
        #expect(worst < 2.0 / 32_768 + 1e-6 || worst < 1e-3, "max |wav − mix| = \(worst)")
    }

    /// Cancel stops the job and leaves no partial file.
    @Test func cancelRemovesPartialFile() async throws {
        let dir = try scratchDir("exp-cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = try ExportFixture(in: dir)
        let out = dir.appendingPathComponent("out.mov")
        let session = ExportSession(scene: f.scene, audio: f.audio, pool: MediaPool(diskCacheDirectory: nil),
                                    settings: ExportSettings(format: .mov(profile: "422")), output: out)
        let job = Task { try await session.run() }
        await session.cancel()
        do {
            try await job.value
            // A tiny job may finish before the cancel lands; then the file must be complete.
            #expect(FileManager.default.fileExists(atPath: out.path))
        } catch ExportError.notImplemented {
            print("export integration: Exporter not implemented yet, skipped")
        } catch ExportError.cancelled {
            #expect(!FileManager.default.fileExists(atPath: out.path), "cancelled export left \(out.lastPathComponent)")
        }
    }

    // MARK: - S3: sample rate from the project, confirm-before-cancel hook

    /// Audio sample rate of the first audio stream of `url`, Hz.
    private func audioRate(_ url: URL) async throws -> Double {
        let src = try await MediaPool(diskCacheDirectory: nil).source(for: url)
        return try #require(src.info.streams.first { $0.kind == .audio }, "no audio in \(url.lastPathComponent)").sampleRate
    }

    /// The AAC/MP3 sample-rate table rate used for a project rate `r`: the next table rate ≥ r,
    /// 48 kHz above the table (export4 rate caps).
    private func aacRate(_ r: Double) -> Double {
        [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000].first { $0 >= r } ?? 48_000
    }

    /// Edited project → `audioFormatSampleRate` changed → save → reopen → export: every audio
    /// output (WAV, M4A, MP4's audio track) is written at the reopened project's rate; invalid
    /// rates fall back to 48 kHz. The click stays at 1.0 s ± 1 frame at the new rate.
    @Test(arguments: [("22050", 22_050.0), ("32000", 32_000.0), ("37000", 37_000.0), ("44100", 44_100.0),
                      ("\"abc\"", 48_000.0), ("1000000", 48_000.0)])
    func exportUsesReopenedProjectSampleRate(lexeme: String, expected: Double) async throws {
        let dir = try scratchDir("exp-rate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = try ExportFixture(in: dir)
        f.bundle.project.root["audioFormatSampleRate"] = try JSON.parse(lexeme)
        try f.bundle.saveWithBackup()
        let reopened = try ProjectBundle(url: f.bundle.directory)
        #expect(reopened.project.serialized() == f.bundle.project.serialized())
        let scene = SceneModel(project: reopened.project, resolve: reopened.resolve)
        let audio = AudioScene(project: reopened.project, resolve: reopened.resolve)
        #expect(audio.sampleRate == (expected == 48_000 ? nil : expected))

        for (name, format) in [("out.wav", ExportFormat.audio(container: "wav")),
                               ("out.m4a", ExportFormat.audio(container: "m4a")),
                               ("out.mp4", ExportFormat.mp4(codec: "h264", bitrate: nil))] {
            let out = dir.appendingPathComponent(name)
            let session = ExportSession(scene: scene, audio: audio, pool: MediaPool(diskCacheDirectory: nil),
                                        settings: ExportSettings(format: format), output: out)
            do {
                try await session.run()
            } catch {
                Issue.record("\(name) at \(lexeme) Hz: \(error)")
                continue
            }
            // PCM keeps the exact rate; AAC takes the next table rate at or above it.
            let want = name == "out.wav" ? expected : aacRate(expected)
            #expect(try await audioRate(out) == want, "\(name) at \(lexeme)")
        }
        // Sync at the new rate: decode the WAV at its own rate and find the click.
        let src = try await MediaPool(diskCacheDirectory: nil).source(for: dir.appendingPathComponent("out.wav"))
        let s = try #require(src.info.streams.first { $0.kind == .audio })
        let pcm = try await src.audio(stream: s.index, range: CMTimeRange(start: .zero, duration: s.duration),
                                      format: PCMFormat(sampleRate: expected, channels: 1))
        let at = try #require(onset(pcm.channels[0]), "click not found")
        #expect(abs(Double(at) / expected + pcm.startTime.seconds - f.clickAt) <= 1.0 / 30)
    }

    /// Confirm-before-cancel hook on a real project export: no work to lose before `run()`
    /// or after it; while running, `cancelAndWait()` returns only once the partial output is
    /// gone, and the output directory holds nothing but the project afterwards.
    @Test func cancelAndWaitHookOnProjectExport() async throws {
        let dir = try scratchDir("exp-cancelwait")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = try ExportFixture(in: dir)
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var settings = ExportSettings(format: .mov(profile: "4444"))
        settings.size = CGSize(width: 1920, height: 1080)  // slow enough to catch mid-run
        let out = outDir.appendingPathComponent("big.mov")
        let session = ExportSession(scene: f.scene, audio: f.audio, pool: MediaPool(diskCacheDirectory: nil),
                                    settings: settings, output: out)
        #expect(await session.cancellationLosesWork == false)
        await session.cancelAndWait()  // idle: returns at once, nothing written
        #expect(try FileManager.default.contentsOfDirectory(atPath: outDir.path).isEmpty)

        let fresh = ExportSession(scene: f.scene, audio: f.audio, pool: MediaPool(diskCacheDirectory: nil),
                                  settings: settings, output: out)
        let job = Task { try await fresh.run() }
        let t0 = Date()
        while await !fresh.cancellationLosesWork, Date().timeIntervalSince(t0) < 30 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await fresh.cancelAndWait()
        #expect(await fresh.cancellationLosesWork == false)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: outDir.path)
        do {
            try await job.value
            #expect(leftovers == ["big.mov"], "finished before the cancel: only the complete file")
        } catch ExportError.cancelled {
            #expect(leftovers.isEmpty, "cancelAndWait returned with \(leftovers) still present")
        }

        // A finished export keeps its file through cancelAndWait.
        let small = outDir.appendingPathComponent("small.wav")
        let done = ExportSession(scene: f.scene, audio: f.audio, pool: MediaPool(diskCacheDirectory: nil),
                                 settings: ExportSettings(format: .audio(container: "wav")), output: small)
        try await done.run()
        await done.cancelAndWait()
        #expect(await done.cancellationLosesWork == false)
        #expect(FileManager.default.fileExists(atPath: small.path))
    }
}
