import CoreGraphics
import Foundation
import TestGenKit
import Testing
import TimelineEngine
import TSCProjKit

/// CE3 builds through TimelineEngine commands from any recording (a synthetic movie here).
@Suite struct CursorSheetTests {
    @Test @MainActor func ce3FromSyntheticRecording() async throws {
        let dir = try scratchDir("ce3")
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = dir.appendingPathComponent("rec.mp4")
        let info = try MediaWriter.writeH264(to: movie, width: 320, height: 200, fps: 30, frameCount: 90) { _, ctx in
            ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        }
        let bundleURL = try await CursorSheet.write(recording: movie, to: dir.appendingPathComponent("ce3")) { _, src in
            SourceDescriptor(src: src, lastModified: Date(), tracks: [
                .init(type: 0, editRate: Int64(info.timescale), rangeEnd: Int64(info.frameCount) * 1000, width: 320,
                      height: 200, sampleRate: Rational(30), bitDepth: 24, channelCount: 0),
            ])
        }
        let bytes = try Data(contentsOf: bundleURL.appendingPathComponent("project.tscproj"))
        let project = try Project(data: bytes)
        #expect(project.serialized() == bytes)
        let clips = project.tracks.flatMap(\.clips)
        #expect(clips.count == 6)
        let fit = min(1920.0 / 320, 1080.0 / 200)
        for (i, clip) in clips.enumerated() {
            let p = clip.object["parameters"]?.object
            #expect(abs((p?["scale0"]?.object?["defaultValue"]?.double ?? 0) - fit / 3) < 1e-9)
            #expect(p?["cursorScale"]?.object?["defaultValue"]?.double == (i == 4 ? 1 : 4))
        }
        let fx = clips.map { $0.object["effects"]?.array?.items.compactMap { $0.object?["effectName"]?.string } ?? [] }
        #expect(fx == [["CursorColor"], ["CursorColor"], ["CursorColor"], ["CursorShadow"], [], []])
        #expect(DocPrefs.playhead(in: bundleURL) == 1_058_400_000)  // half of 3 s (frame 45)
        let manifest = try SheetManifest.load(dir.appendingPathComponent("ce3/sheet.json"))
        #expect(manifest.cells.count == 6 && manifest.group == "research/cursor")
    }
}
