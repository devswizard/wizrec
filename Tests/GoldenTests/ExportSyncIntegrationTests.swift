import AudioEngine
import CoreMedia
import Exporter
import Foundation
import Metal
import MediaEngine
import RenderEngine
import Testing
import TestGenKit
import TimelineEngine
import TSCProjKit

// Session 4 (S4-EXP-1, parallel audio prefetch): A/V sync and determinism over a project long
// enough that audio is mixed in several chunks while video renders. Synthetic media only.

private let W = 320, H = 180
private let seconds = 6

/// 6 s test-card clip (frame numbers as barcodes) on track 0; on track 1 a click train with a
/// one-cycle click at k + 0.5 s for k = 0…5, so click k coincides with card frame 30k + 15.
@MainActor
private struct SyncFixture {
    let bundle: ProjectBundle
    let card: TestCard
    /// Timeline times of the click onsets, seconds.
    let clicks = (0..<seconds).map { Double($0) + 0.5 }

    init(in dir: URL) async throws {
        bundle = try ProjectBundle.create(at: dir.appendingPathComponent("sync.cmproj"), width: W, height: H)
        card = TestCard(width: W, height: H, label: "S")
        let frameCount = seconds * 30
        let movie = dir.appendingPathComponent("card.mp4")
        let card = self.card
        try await MediaWriter.writeH264(to: movie, width: W, height: H, fps: 30, frameCount: frameCount, bitsPerSecond: 4_000_000) { n, ctx in
            card.draw(frame: n, fps: 30, in: ctx)
        }
        var pcm = [Float](repeating: 0, count: seconds * 48_000)
        for at in clicks {
            let s = Int(at * 48_000)
            for i in 0..<48 { pcm[s + i] = 0.8 * Float(sin(2 * Double.pi * Double(i) / 48)) }
        }
        let wav = dir.appendingPathComponent("clicks.wav")
        try AudioSignals.writeWAV(pcm, to: wav)

        let chain = EditChain(bundle.project)
        let v = AddSource(SourceDescriptor(src: try bundle.importFile(movie), lastModified: Date(timeIntervalSince1970: 1_792_000_000), tracks: [
            .init(type: 0, editRate: 30, rangeEnd: Int64(frameCount), width: W, height: H, sampleRate: Rational(30), bitDepth: 24, channelCount: 0),
        ]))
        let a = AddSource(SourceDescriptor(src: try bundle.importFile(wav), lastModified: Date(timeIntervalSince1970: 1_792_000_000), tracks: [
            .init(type: 2, editRate: 48_000, rangeEnd: Int64(pcm.count), width: 0, height: 0, sampleRate: Rational(48_000), bitDepth: 16, channelCount: 1),
        ]))
        try chain.run(v); try chain.run(a)
        try chain.run(InsertClip(sourceID: try #require(v.sourceID), track: 0, start: 0))
        try chain.run(AddTrack(at: 1))
        try chain.run(InsertClip(sourceID: try #require(a.sourceID), track: 1, start: 0))
    }

    func export(_ settings: ExportSettings, to url: URL) async throws {
        let session = ExportSession(scene: SceneModel(project: bundle.project, resolve: bundle.resolve),
                                    audio: AudioScene(project: bundle.project, resolve: bundle.resolve),
                                    pool: MediaPool(diskCacheDirectory: nil), settings: settings, output: url)
        try await session.run()
    }
}

/// Decoded mono audio of `url` (whole file at 48 kHz) and the time of its first sample, seconds.
private func decodeAudio(_ url: URL) async throws -> (samples: [Float], start: Double) {
    let src = try await MediaPool(diskCacheDirectory: nil).source(for: url)
    let stream = try #require(src.info.streams.first { $0.kind == .audio }, "no audio track in \(url.lastPathComponent)")
    let pcm = try await src.audio(stream: stream.index,
                                  range: CMTimeRange(start: .zero, duration: CMTime(seconds: Double(seconds), preferredTimescale: 48_000)),
                                  format: PCMFormat(sampleRate: 48_000, channels: 1))
    return (pcm.channels[0], pcm.startTime.seconds)
}

/// Onset times (seconds) of clicks: first sample above `threshold` after ≥ 0.1 s of quiet.
private func onsets(_ x: [Float], start: Double, threshold: Float = 0.2) -> [Double] {
    var out: [Double] = []
    var last = -Int.max / 2
    for (i, v) in x.enumerated() where abs(v) > threshold {
        if i - last > 4_800 { out.append(start + Double(i) / 48_000) }
        last = i
    }
    return out
}

@Suite(.serialized, .timeLimit(.minutes(6)), .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
@MainActor struct ExportSyncIntegrationTests {
    /// Every click (6 over 6 s, so several audio chunks) sits at its timeline time ± 1 frame
    /// in H.264/AAC and ProRes/PCM exports, and the video frame at each click shows the card
    /// frame the timeline puts there.
    @Test(arguments: [ExportFormat.mp4(codec: "h264", bitrate: 4_000_000), ExportFormat.mov(profile: "422")])
    func everyClickStaysWithinOneFrame(_ format: ExportFormat) async throws {
        let dir = try scratchDir("s4-sync")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = try await SyncFixture(in: dir)
        let out = dir.appendingPathComponent("out.\(format.fileExtension)")
        try await f.export(ExportSettings(format: format), to: out)

        let (pcm, start) = try await decodeAudio(out)
        let got = onsets(pcm, start: start)
        #expect(got.count == f.clicks.count, "found clicks at \(got)")
        for (want, at) in zip(f.clicks, got) {
            #expect(abs(at - want) <= 1.0 / 30, "\(format): click at \(at) s, expected \(want) s (±1 frame)")
        }
        let indices = f.clicks.map { Int(($0 * 30).rounded()) }
        let frames = try await MovieFrameReader.frames(out, indices: indices)
        for n in indices {
            let image = try #require(frames[n], "frame \(n) missing")
            #expect(f.card.decodeFrameNumber(image) == n, "\(format): frame \(n) shows \(String(describing: f.card.decodeFrameNumber(image)))")
        }
    }

    /// Two ProRes 422 + PCM exports of the same project (separate pools) are identical: every
    /// decoded video frame and every audio sample.
    @Test func proResExportIsDeterministicWithAudio() async throws {
        let dir = try scratchDir("s4-determinism")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = try await SyncFixture(in: dir)
        var outs: [URL] = []
        for k in 0..<2 {
            let out = dir.appendingPathComponent("run\(k).mov")
            try await f.export(ExportSettings(format: .mov(profile: "422")), to: out)
            outs.append(out)
        }
        let a0 = try await decodeAudio(outs[0]), a1 = try await decodeAudio(outs[1])
        #expect(a0.start == a1.start)
        #expect(a0.samples.count == a1.samples.count)
        let firstDiff = zip(a0.samples, a1.samples).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        #expect(firstDiff == nil, "audio differs from sample \(firstDiff ?? -1)")

        let n = seconds * 30
        let v0 = try await MovieFrameReader.frames(outs[0], indices: Array(0..<n))
        let v1 = try await MovieFrameReader.frames(outs[1], indices: Array(0..<n))
        #expect(v0.count == n && v1.count == n)
        let differing = (0..<n).filter { v0[$0]?.pixels != v1[$0]?.pixels }
        #expect(differing.isEmpty, "video differs at frames \(differing)")
    }
}
