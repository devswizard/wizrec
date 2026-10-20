import AppKit
import Foundation
import MediaEngine
import Testing
import TimelineEngine
import TSCProjKit
import WizRecTestSupport
@testable import TimelineUI

/// Synthesises a 2-s 320×240 test pattern with a 440 Hz tone (ffmpeg lavfi). Nil when ffmpeg is missing.
func synthMovie() throws -> URL? {
    let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
    guard let ffmpeg = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("timelineui-media-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let out = dir.appendingPathComponent("clip.mp4")
    let args: [String] = ["-nostdin", "-v", "error", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=30", "-f", "lavfi",
                          "-i", "sine=frequency=440:sample_rate=44100", "-t", "2", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                          "-c:a", "aac", "-shortest", out.path]
    return try TestProcess.run(ffmpeg, args).status == 0 ? out : nil
}

struct MediaProviderTests {
    @Test func mediaPoolProviderGivesThumbnailsAndPeaks() async throws {
        guard let url = try synthMovie() else { return }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = MediaPoolTimelineProvider(pool: MediaPool(), bundleDirectory: url.deletingLastPathComponent())
        let video = TimelineMediaRef(sourceID: 1, src: "./clip.mp4", stream: 0)
        let audio = TimelineMediaRef(sourceID: 1, src: "./clip.mp4", stream: 1)
        let img = try #require(await provider.thumbnail(video, atSeconds: 1, maxPixelSize: 96))
        #expect(max(img.width, img.height) <= 96 && img.width > img.height)
        let wf = try #require(await provider.waveform(audio))
        #expect(wf.bucketsPerSecond > 0)
        let r = try #require(wf.range(from: 0.5, to: 1.5))
        #expect(r.max > 0.08 && r.min < -0.08)  // lavfi sine: amplitude 1/8
        // Wrong stream kinds and missing files give nil, not errors.
        #expect(await provider.waveform(video) == nil)
        #expect(await provider.thumbnail(TimelineMediaRef(sourceID: 2, src: "./missing.mp4", stream: 0),
                                         atSeconds: 0, maxPixelSize: 64) == nil)
    }

    @Test func waveformRange() {
        let w = TimelineWaveform(bucketsPerSecond: 10, minima: [-0.1, -0.5, -0.2, 0], maxima: [0.1, 0.2, 0.9, 0])
        #expect(w.range(from: 0, to: 0.1)! == (-0.1, 0.1))
        #expect(w.range(from: 0.05, to: 0.25)! == (-0.5, 0.9))
        #expect(w.range(from: 1, to: 2) == nil)
    }

    /// Renders the user's vlog with real thumbnails and waveforms (read in place) for a visual check.
    @MainActor @Test func userVlogWithMedia() async throws {
        let bundle = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Moheshkali Dwip Vlog.cmproj")
        let file = bundle.appendingPathComponent("project.tscproj")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let model = TimelineModel(undo: UndoStack(project: try Project(contentsOf: file)))
        model.pointsPerSecond = 12
        let view = TimelineView(model: model)
        view.canvas.fitsOnFirstLayout = false
        view.frame = CGRect(x: 0, y: 0, width: 1600, height: 360)
        view.mediaProvider = MediaPoolTimelineProvider(pool: MediaPool(), bundleDirectory: bundle)
        _ = render(view)
        for _ in 0..<300 where !view.canvas.art.isIdle {
            try await Task.sleep(nanoseconds: 50_000_000)
            _ = render(view)
        }
        if ProcessInfo.processInfo.environment["WIZREC_TUI_PNG_DIR"] != nil { savePNG(render(view), "vlog-media") }
    }
}

