import AVFoundation
import CoreGraphics
import Foundation
import MediaEngine
import RenderEngine
import TestGenKit
import Testing
import TSCProjKit
@testable import Exporter

/// Facts about an exported movie's video track.
struct MovieFacts {
    var codec: FourCharCode
    var width: Int, height: Int
    var fps: Double
    var duration: Double
    var frames: Int
    var primaries: String?, transfer: String?, matrix: String?
    var hasAudio: Bool
}

func movieFacts(_ url: URL) async throws -> MovieFacts {
    let asset = AVURLAsset(url: url)
    let v = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let (size, fps, range, descs) = try await v.load(.naturalSize, .nominalFrameRate, .timeRange, .formatDescriptions)
    let d = try #require(descs.first)
    let ext = CMFormatDescriptionGetExtensions(d) as? [String: Any] ?? [:]
    var frames = 0
    try await MovieFrameReader.forEachFrame(url) { _, _, _ in frames += 1; return true }
    let audio = try await asset.loadTracks(withMediaType: .audio)
    return MovieFacts(codec: CMFormatDescriptionGetMediaSubType(d), width: Int(size.width), height: Int(size.height),
                      fps: Double(fps), duration: range.duration.seconds, frames: frames,
                      primaries: ext[kCVImageBufferColorPrimariesKey as String] as? String,
                      transfer: ext[kCVImageBufferTransferFunctionKey as String] as? String,
                      matrix: ext[kCVImageBufferYCbCrMatrixKey as String] as? String,
                      hasAudio: !audio.isEmpty)
}

func fourCC(_ s: String) -> FourCharCode { s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) } }

@Suite(.enabled(if: hasGPU), .serialized) struct VideoExportTests {
    @Test func h264MP4MatchesTimingAndTags() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await movingProject(frames: 45)
        var s = ExportSettings(format: .mp4(codec: "h264", bitrate: 4_000_000))
        s.includeAudio = false
        let out = dir.appendingPathComponent("out.mp4")
        try await export(p, s, to: out)
        let f = try await movieFacts(out)
        #expect(f.codec == fourCC("avc1"))
        #expect(f.width == 480 && f.height == 270)
        #expect(f.frames == 45)
        #expect(abs(f.fps - 30) < 0.01)
        #expect(abs(f.duration - 1.5) < 1e-3)
        #expect(f.primaries == kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        #expect(f.transfer == kCVImageBufferTransferFunction_ITU_R_709_2 as String)
        #expect(f.matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
        #expect(!f.hasAudio)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers == ["out.mp4"])
    }

    /// Every exported frame shows the source frame the time mapping says (barcode on test card A).
    @Test func framesLandOnTheExactSourceFrames() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Clip A from source frame 12, starting at timeline frame 0; export frames 5..<35.
        let p = try await makeProject { b, m in
            b.tracks = [[b.video(m[.clipA]!, start: 0, duration: 60 * tpf, mediaStart: 12 * tpf)]]
        }
        var s = ExportSettings(format: .mp4(codec: "h264", bitrate: 8_000_000))
        s.includeAudio = false
        s.range = (5 * tpf)..<(35 * tpf)
        let out = dir.appendingPathComponent("barcode.mp4")
        try await export(p, s, to: out)
        var decoded: [Int?] = []
        try await MovieFrameReader.forEachFrame(out) { _, _, pb in
            decoded.append(RGBAImage(pixelBuffer: pb).flatMap { p.cardA.decodeFrameNumber($0) })
            return true
        }
        #expect(decoded.count == 30)
        #expect(decoded == (0..<30).map { Optional(17 + $0) })
    }

    /// Acceptance: export frame N == OfflineRenderer frame N (SSIM ≥ 0.99 after decode).
    @Test(arguments: [
        ExportFormat.mp4(codec: "h264", bitrate: 12_000_000),
        ExportFormat.mp4(codec: "hevc", bitrate: 8_000_000),
        ExportFormat.mov(profile: "422HQ"),
    ])
    func exportFrameEqualsPreviewFrame(_ format: ExportFormat) async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await movingProject(frames: 40)
        var s = ExportSettings(format: format)
        s.includeAudio = false
        let out = dir.appendingPathComponent("eq.\(format.fileExtension)")
        try await export(p, s, to: out)
        let frames = [0, 1, 13, 26, 39]
        let decoded = try await MovieFrameReader.frames(out, indices: frames)
        let renderer = OfflineRenderer(scene: p.scene, pool: MediaPool())
        let timing = FrameTiming(editRate: p.scene.timebase.editRate, fps: p.scene.frameRate, range: 0..<p.scene.duration)
        for n in frames {
            let ref = RGBAImage(try await renderer.image(at: timing.ticks(frame: n), size: CGSize(width: 480, height: 270)))
            let got = try #require(decoded[n])
            let score = ssim(got, ref)
            #expect(score >= 0.99, "\(format) frame \(n): SSIM \(score)")
        }
    }

    @Test func sizeIsAspectFittedAndEven() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await movingProject(frames: 3)
        var s = ExportSettings(format: .mp4(codec: "h264", bitrate: nil))
        s.includeAudio = false
        s.size = CGSize(width: 301, height: 1000)
        let out = dir.appendingPathComponent("fit.mp4")
        try await export(p, s, to: out)
        let f = try await movieFacts(out)
        #expect(f.width == 300 && f.height == 170)  // 301×169.3 → even 300×170
    }

    @Test func otherFrameRate() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await movingProject(frames: 30)
        var s = ExportSettings(format: .mp4(codec: "h264", bitrate: nil))
        s.includeAudio = false
        s.frameRate = Rational(25)
        let out = dir.appendingPathComponent("25.mp4")
        try await export(p, s, to: out)
        let f = try await movieFacts(out)
        #expect(f.frames == 25 && abs(f.fps - 25) < 0.01 && abs(f.duration - 1) < 1e-3)
    }

    @Test func proRes4444KeepsAlpha() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await makeProject(background: [0, 0, 0, 0]) { b, m in
            b.tracks = [[b.video(m[.clipA]!, start: 0, duration: 4 * tpf, params: [
                "scale0": .constant(0.5), "scale1": .constant(0.5),
            ])]]
        }
        var s = ExportSettings(format: .mov(profile: "4444"))
        s.includeAudio = false
        let out = dir.appendingPathComponent("alpha.mov")
        try await export(p, s, to: out)
        let f = try await movieFacts(out)
        #expect(f.codec == fourCC("ap4h") && f.frames == 4)
        let frame = try #require(try await MovieFrameReader.frames(out, indices: [0])[0])
        #expect(frame.pixel(5, 5).a < 8, "corner is transparent")
        #expect(frame.pixel(240, 135).a > 247, "clip is opaque")
    }

    /// QuickTime ProRes 4444 alpha is straight: a half-transparent white layer must decode as
    /// white at alpha ≈ 128 (premultiplied storage would decode as grey). Checked with ffmpeg too.
    @Test func proRes4444StoresStraightAlpha() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await makeProject(background: [0, 0, 0, 0]) { b, m in
            b.tracks = [[b.image(m[.marker]!, start: 0, duration: 2 * tpf, params: ["opacity": .constant(0.5)])]]
        }
        var s = ExportSettings(format: .mov(profile: "4444"))
        s.includeAudio = false
        let out = dir.appendingPathComponent("half.mov")
        try await export(p, s, to: out)
        let px = try #require(try await MovieFrameReader.frames(out, indices: [0])[0]).pixel(240, 135)
        #expect(px.r > 250 && px.g > 250 && px.b > 250, "\(px)")
        #expect(abs(Int(px.a) - 128) <= 2, "\(px)")
    }

    @Test func proRes422HasNoAlphaAndPCMAudioWhenAvailable() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await movingProject(frames: 6)
        let out = dir.appendingPathComponent("p.mov")
        try await export(p, ExportSettings(format: .mov(profile: "422")), to: out)
        let f = try await movieFacts(out)
        #expect(f.codec == fourCC("apcn") && f.frames == 6)
        #expect(f.hasAudio)
    }

    @Test func cancelRemovesPartialFileAndKeepsExistingOutput() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await movingProject(frames: 290)
        let out = dir.appendingPathComponent("c.mp4")
        try Data("previous export".utf8).write(to: out)
        var s = ExportSettings(format: .mp4(codec: "h264", bitrate: nil))
        s.includeAudio = false
        let session = ExportSession(scene: p.scene, audio: p.audio, pool: MediaPool(), settings: s, output: out)
        let run = Task { try await session.run() }
        while await session.progress < 0.05 { try await Task.sleep(nanoseconds: 2_000_000) }
        await session.cancel()
        await #expect(throws: ExportError.cancelled) { try await run.value }
        #expect(try Data(contentsOf: out) == Data("previous export".utf8))
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left == ["c.mp4"], "\(left)")
    }

    /// S3-EXP-2: the app asks `cancellationLosesWork` before closing, then `cancelAndWait()`.
    @Test func confirmBeforeCancelHook() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await movingProject(frames: 290)
        let out = dir.appendingPathComponent("w.mp4")
        var s = ExportSettings(format: .mp4(codec: "h264", bitrate: nil))
        s.includeAudio = false
        let session = ExportSession(scene: p.scene, audio: p.audio, pool: MediaPool(), settings: s, output: out)
        #expect(await session.cancellationLosesWork == false)
        let run = Task { try await session.run() }
        while await session.progress < 0.05 { try await Task.sleep(nanoseconds: 2_000_000) }
        #expect(await session.cancellationLosesWork)
        await session.cancelAndWait()
        // Returned only after run() stopped and cleaned up: nothing left in the directory.
        #expect(await session.cancellationLosesWork == false)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left.isEmpty, "\(left)")
        await #expect(throws: ExportError.cancelled) { try await run.value }
    }

    @Test func cancelAndWaitAfterCompletionKeepsFile() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await movingProject(frames: 6)
        let out = dir.appendingPathComponent("k.mp4")
        var s = ExportSettings(format: .mp4(codec: "h264", bitrate: nil))
        s.includeAudio = false
        let session = ExportSession(scene: p.scene, audio: p.audio, pool: MediaPool(), settings: s, output: out)
        try await session.run()
        #expect(await session.cancellationLosesWork == false)
        await session.cancelAndWait()
        #expect(FileManager.default.fileExists(atPath: out.path))
    }

    @Test func taskCancellationStopsExport() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await movingProject(frames: 290)
        let out = dir.appendingPathComponent("t.mp4")
        var s = ExportSettings(format: .mp4(codec: "h264", bitrate: nil))
        s.includeAudio = false
        let session = ExportSession(scene: p.scene, audio: p.audio, pool: MediaPool(), settings: s, output: out)
        let run = Task { try await session.run() }
        while await session.progress < 0.05 { try await Task.sleep(nanoseconds: 2_000_000) }
        run.cancel()
        await #expect(throws: ExportError.cancelled) { try await run.value }
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left.isEmpty, "\(left)")
    }

    @Test func progressIsMonotonicAndEndsAtOne() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await movingProject(frames: 20)
        var s = ExportSettings(format: .mp4(codec: "hevc", bitrate: nil))
        s.includeAudio = false
        let session = ExportSession(scene: p.scene, audio: p.audio, pool: MediaPool(), settings: s,
                                    output: dir.appendingPathComponent("p.mp4"))
        let log = ProgressLog()
        await session.setProgressHandler { v in log.append(v) }
        try await session.run()
        let values = log.values
        #expect(values.first == 0 && values.last == 1)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(await session.progress == 1)
    }

    @Test func badSettingsFail() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await movingProject(frames: 2)
        for format in [ExportFormat.mp4(codec: "vp9", bitrate: nil), .mov(profile: "RAW"), .audio(container: "ogg")] {
            await #expect(throws: ExportError.self) {
                try await export(p, ExportSettings(format: format), to: dir.appendingPathComponent("x.bin"))
            }
        }
        var empty = ExportSettings(format: .mp4(codec: "h264", bitrate: nil))
        empty.range = 10..<10
        await #expect(throws: ExportError.self) { try await export(p, empty, to: dir.appendingPathComponent("e.mp4")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}

/// Thread-safe list of progress values.
final class ProgressLog: @unchecked Sendable {
    // @unchecked: all access goes through `lock`.
    private let lock = NSLock()
    private var storage: [Double] = []
    func append(_ v: Double) { lock.lock(); storage.append(v); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Polling `progress` from the main actor while a movie exports must not slow the export down
/// (agent "app" saw a crawl with 200 ms polling).
@Suite(.enabled(if: hasGPU), .serialized) struct ProgressPollingTests {
    @MainActor @Test func pollingProgressDoesNotStallExport() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try movingProject(frames: 290)
        let session = ExportSession(scene: p.scene, audio: p.audio, pool: MediaPool(),
                                    settings: ExportSettings(format: .mp4(codec: "h264", bitrate: nil)),
                                    output: dir.appendingPathComponent("poll.mp4"))
        let t0 = Date()
        let run = Task.detached { try await session.run() }
        var polls = 0
        while await session.progress < 1 {
            polls += 1
            try await Task.sleep(nanoseconds: 200_000_000)
            if Date().timeIntervalSince(t0) > 60 { break }
        }
        try await run.value
        let elapsed = Date().timeIntervalSince(t0)
        LoadGate.expect(elapsed < 60, "export with polling took \(elapsed) s (\(polls) polls)")
    }
}

struct WorkDirectoryTests {
    @Test func staleWorkDirectoriesOfDeadProcessesAreSwept() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let me = ProcessInfo.processInfo.processIdentifier
        // PID 99999999 cannot exist (pid_max is far lower); our own PID is alive.
        let dead = dir.appendingPathComponent(".wizrec-export-99999999-AAAA")
        let live = dir.appendingPathComponent(".wizrec-export-\(me)-BBBB")
        let legacy = dir.appendingPathComponent(".wizrec-export-CCCC-DDDD")
        for d in [dead, live, legacy] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        ExportSession.sweepStaleWorkDirectories(near: dir.appendingPathComponent("out.mp4"))
        #expect(!fm.fileExists(atPath: dead.path))
        #expect(fm.fileExists(atPath: live.path))
        #expect(fm.fileExists(atPath: legacy.path))
        #expect(ExportSession.workDirectory(for: dir.appendingPathComponent("x.mp4")).lastPathComponent
                    .hasPrefix(".wizrec-export-\(me)-"))
    }
}
