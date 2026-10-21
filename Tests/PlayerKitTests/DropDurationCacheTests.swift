import CoreGraphics
import Foundation
import MediaEngine
import TestGenKit
import Testing
import TimelineEngine
@testable import PlayerKit

/// APP15-2: Finder files dragged over the timeline are probed once, asynchronously; the landing
/// preview then shows the clip length the drop would make.
@Suite @MainActor struct DropDurationCacheTests {
    @Test func probesEachFileOnceAndAnswersAfterwards() async {
        var calls: [URL] = []
        let cache = DropDurationCache { url in
            calls.append(url)
            return url.lastPathComponent == "clip.mp4" ? 150 : nil
        }
        let clip = URL(fileURLWithPath: "/tmp/x/../x/clip.mp4"), other = URL(fileURLWithPath: "/tmp/x/notes.txt")
        #expect(cache.duration(of: clip) == nil)       // probing starts
        #expect(cache.duration(of: clip) == nil)       // not twice
        #expect(cache.duration(of: other) == nil)
        await cache.settle()
        #expect(cache.duration(of: URL(fileURLWithPath: "/tmp/x/clip.mp4")) == 150)
        #expect(cache.duration(of: other) == nil)
        #expect(calls.count == 2)
        cache.reset()
        _ = cache.duration(of: clip)
        await cache.settle()
        #expect(calls.count == 3)
    }

    /// The model's duration for a probed file equals the clip a drop then makes, and asking leaves
    /// the project unchanged.
    @Test func modelDurationMatchesTheDroppedClip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-dropdur-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("voice.wav")
        try AudioSignals.writeWAV(AudioSignals.pinkNoise(seconds: 1.5, lufs: -23), to: wav)
        let png = dir.appendingPathComponent("still.png")
        try MediaWriter.writePNG(to: png, width: 32, height: 32) { ctx in
            ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let doc = try EditorDocumentModel.untitled(in: dir)
        for file in [wav, png] {
            let before = doc.project.serialized()
            let info = try await doc.thumbnailPool.probe(file)
            let d = try #require(doc.dropClipDuration(for: info))
            #expect(doc.project.serialized() == before)
            let id = try await doc.importAndInsert(file, at: 0)
            #expect(doc.project.tracks.flatMap(\.clips).first { $0.id == id }?.duration == d)
        }
    }
}
