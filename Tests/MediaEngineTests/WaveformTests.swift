// Waveform peaks and filmstrip thumbnails.

import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import MediaEngine

private func secs(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600_000) }

/// Envelope of decoded PCM (all channels) at `bps`, computed the slow way.
private func referencePeaks(_ src: any MediaSource, stream: Int, rate: Double, channels: Int,
                            seconds: Double, bps: Double) async throws -> (min: [Float], max: [Float]) {
    let range = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: Int32(rate)))
    let pcm = try await src.audio(stream: stream, range: range, format: PCMFormat(sampleRate: rate, channels: channels))
    let per = rate / bps
    let n = Int((Double(pcm.frameCount) / per).rounded(.up))
    var lo = [Float](repeating: 0, count: n), hi = [Float](repeating: 0, count: n)
    for j in 0..<n {
        let a = Int(Double(j) * per), b = min(pcm.frameCount, Int(Double(j + 1) * per))
        guard a < b else { continue }
        var l = Float.greatestFiniteMagnitude, h = -Float.greatestFiniteMagnitude
        for ch in pcm.channels { for i in a..<b { l = min(l, ch[i]); h = max(h, ch[i]) } }
        lo[j] = l; hi[j] = h
    }
    return (lo, hi)
}

@Suite struct WaveformTests {
    @Test func wavEnvelopeAndOnset() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.wav")
        try Synth.writeWAV(to: url, seconds: 2, sampleRate: 44100, channels: 2, frequency: 441, onset: 0.5)
        let pool = MediaPool(diskCacheDirectory: dir.appendingPathComponent("cache"))
        let p = try await pool.peaks(url: url, stream: 0, bucketsPerSecond: 10)
        #expect(p.bucketsPerSecond == 10)
        #expect(p.count == 20)
        for i in 0..<5 { #expect(p.min[i] == 0 && p.max[i] == 0, "bucket \(i) silent") }
        for i in 5..<20 {
            #expect(abs(p.max[i] - 0.5) < 0.01, "bucket \(i) max \(p.max[i])")
            #expect(abs(p.min[i] + 0.5) < 0.01, "bucket \(i) min \(p.min[i])")
        }
        // Above the base resolution: clamped, and stated.
        let fine = try await pool.peaks(url: url, stream: 0, bucketsPerSecond: 1e6)
        #expect(fine.bucketsPerSecond < 1100 && fine.bucketsPerSecond > 900)
    }

    @Test func diskCacheRoundTripsAndStaysOutOfBundles() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.wav")
        try Synth.writeWAV(to: url, seconds: 1, sampleRate: 48000, frequency: 300, onset: 0.25)
        let cacheDir = dir.appendingPathComponent("peaks")
        #expect(!FileManager.default.fileExists(atPath: cacheDir.path)) // created lazily
        let a = try await MediaPool(diskCacheDirectory: cacheDir).peaks(url: url, stream: 0, bucketsPerSecond: 50)
        let files = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        #expect(files.count == 1)
        let b = try await MediaPool(diskCacheDirectory: cacheDir).peaks(url: url, stream: 0, bucketsPerSecond: 50)
        #expect(a == b)
        #expect(PeakDiskCache(directory: dir.appendingPathComponent("x.cmproj/cache")) == nil)
    }

    /// AAC in MP4 (2112 priming samples, no edit list): peaks line up with `audio()` PCM.
    @Test(.enabled(if: Synth.ffmpegPath != nil, "needs ffmpeg"))
    func aacPeaksMatchDecodedPCM() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("s.wav"), m4a = dir.appendingPathComponent("s.mp4")
        try Synth.writeWAV(to: wav, seconds: 3, sampleRate: 48000, channels: 2, frequency: 500, onset: 1.0)
        try Synth.ffmpeg(["-i", wav.path, "-c:a", "aac", "-b:a", "192k", m4a.path])
        let pool = MediaPool(diskCacheDirectory: nil)
        let src = try await pool.source(for: m4a)
        let info = try #require(src.info.streams.first)
        let p = try await pool.peaks(url: m4a, stream: 0, bucketsPerSecond: 100)
        let ref = try await referencePeaks(src, stream: 0, rate: 48000, channels: 2, seconds: info.duration.seconds, bps: 100)
        #expect(abs(p.count - ref.min.count) <= 1)
        var worst: Float = 0
        for i in 0..<min(p.count, ref.min.count) {
            worst = max(worst, abs(p.max[i] - ref.max[i]), abs(p.min[i] - ref.min[i]))
        }
        #expect(worst < 0.02, "worst bucket difference \(worst)")
        // Silent until 1.0 s, loud after.
        #expect(p.max[95] < 0.01)
        #expect(p.max[105] > 0.4)
    }

    @Test func videoStreamHasNoPeaks() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("v.mp4")
        try await Synth.writeMovie(to: url, times: [0, 0.1])
        await #expect(throws: MediaError.self) { try await MediaPool(diskCacheDirectory: nil).peaks(url: url, stream: 0, bucketsPerSecond: 10) }
    }
}

@Suite struct ThumbnailTests {
    @Test func keyframeAndExactThumbnailsOnOwnDecoders() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.mp4")
        try await Synth.writeMovie(to: url, times: (0..<90).map { Double($0) / 30 }, keyInterval: 15)
        let pool = MediaPool()
        var got: [Thumbnail] = []
        for try await t in pool.thumbnails(url: url, stream: 0, times: [secs(2.9), secs(0.1), secs(1.2)], maxPixelSize: 64) {
            got.append(t)
        }
        #expect(got.map { $0.requestedTime.seconds } == [0.1, 1.2, 2.9].map { secs($0).seconds })
        // A keyframe at or before each time (the encoder places one at least every 15 frames,
        // sometimes more often: the key interval is a maximum, so read the file's real keyframes).
        let keyframes = try await Synth.syncTimes(url)
        #expect(keyframes.first == .zero && keyframes.count >= 90 / 15, "\(keyframes.map(\.seconds)) got \(got.map(\.presentationTime.seconds))")
        for t in got {
            let lag = t.requestedTime.seconds - t.presentationTime.seconds
            #expect(lag >= 0 && lag <= 15.0 / 30 + 1e-6, "lag \(lag)")
            #expect(keyframes.contains(t.presentationTime), "thumbnail at \(t.presentationTime.seconds) s is a keyframe")
        }
        for t in got {
            #expect(t.image.width == 64)
            #expect(t.image.height == 13)
        }
        var exact: [Double] = []
        for try await t in pool.thumbnails(url: url, stream: 0, times: [secs(1.21), secs(2.9)], maxPixelSize: 100, accuracy: .exact) {
            exact.append((t.presentationTime.seconds * 30).rounded())
        }
        #expect(exact == [36, 87])
        let src = try #require(try await pool.source(for: url) as? FFMediaSource)
        #expect(await src.openVideoDecoders == 0) // playback lanes untouched
        #expect(await pool.thumbnails.cachedCount == 5)
    }

    @Test func imageThumbnail() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("i.png")
        try Synth.writePNG(to: url, width: 400, height: 200, rgba: (255, 0, 0, 255))
        let t = try await MediaPool().thumbnail(url: url, stream: 0, at: .zero, maxPixelSize: 100)
        #expect(t.image.width == 100 && t.image.height == 50)
    }
}

/// Throughput of the M2 helpers on the user's vlog (local only, `WIZREC_PERF=1`).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WIZREC_PERF"] == "1", "set WIZREC_PERF=1"), .serialized)
struct WaveformPerfTests {
    static let vlogMedia = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/Moheshkali Dwip Vlog.cmproj/media")

    /// Every audio stream of every vlog source: one cold decode, then disk-cache hits.
    @Test func vlogPeaks() async throws {
        guard let e = FileManager.default.enumerator(at: Self.vlogMedia, includingPropertiesForKeys: nil) else { return }
        let files = e.compactMap { $0 as? URL }.filter { ["mp4", "m4a", "mp3"].contains($0.pathExtension.lowercased()) }
        guard !files.isEmpty else { return }
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var seconds = 0.0
        let t0 = Date()
        let pool = MediaPool(diskCacheDirectory: dir)
        var jobs: [(URL, Int)] = []
        for f in files {
            let info = try await pool.probe(f)
            for s in info.streams where s.kind == .audio { jobs.append((f, s.index)); seconds += s.duration.seconds }
        }
        try await withThrowingTaskGroup(of: Void.self) { g in
            for (f, s) in jobs { g.addTask { _ = try await pool.peaks(url: f, stream: s, bucketsPerSecond: 100) } }
            try await g.waitForAll()
        }
        let cold = Date().timeIntervalSince(t0)
        let t1 = Date()
        let pool2 = MediaPool(diskCacheDirectory: dir)
        for (f, s) in jobs { _ = try await pool2.peaks(url: f, stream: s, bucketsPerSecond: 100) }
        let warm = Date().timeIntervalSince(t1)
        print("PERF peaks vlog: \(jobs.count) audio streams, \(Int(seconds)) s of audio: cold \(String(format: "%.2f", cold)) s (\(Int(seconds / cold))x realtime), disk cache \(String(format: "%.3f", warm)) s")
    }

    /// A 40-picture filmstrip of one DJI clip (2688x1512 10-bit HEVC).
    @Test(.enabled(if: Vlog.sample != nil)) func djiFilmstrip() async throws {
        let url = try #require(Vlog.sample)
        let pool = MediaPool()
        let dur = try await pool.probe(url).streams[0].duration.seconds
        let times = (0..<40).map { CMTime(seconds: dur * Double($0) / 40, preferredTimescale: 600) }
        let t0 = Date()
        var n = 0
        for try await _ in pool.thumbnails(url: url, stream: 0, times: times, maxPixelSize: 160) { n += 1 }
        let ms = Date().timeIntervalSince(t0) * 1000
        print("PERF filmstrip DJI: \(n) thumbnails in \(Int(ms)) ms (\(String(format: "%.1f", ms / Double(n))) ms each)")
    }
}
