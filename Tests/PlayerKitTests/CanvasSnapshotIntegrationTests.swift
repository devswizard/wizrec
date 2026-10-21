import CoreGraphics
import Foundation
import MediaEngine
import Metal
import MetalKit
import PlayerKit
import RenderEngine
import TestGenKit
import Testing
import WizRecTestSupport

/// QA11-3 (APP11-1 merged): the snapshot path of `--snapshot-at` (seek, wait until settled,
/// `CanvasRenderer.renderImage`) on a project with real media shows the frame at the playhead,
/// the same picture the offline renderer (export path) makes at that time.
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
@MainActor struct CanvasSnapshotIntegrationTests {
    @Test func snapshotShowsTheFrameAtThePlayhead() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qa11-snap-\(UUID().uuidString)",
                                                                              isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (w, h) = (320, 180)
        let card = TestCard(width: w, height: h, label: "C")
        let movie = dir.appendingPathComponent("card.mp4")
        try await MediaWriter.writeH264(to: movie, width: w, height: h, fps: 30, frameCount: 45) { n, ctx in
            card.draw(frame: n, fps: 30, in: ctx)
        }
        let doc = try EditorDocumentModel.untitled(width: w, height: h, in: dir)
        _ = try await doc.importAndInsert(movie, at: 0)
        let engine = doc.makeEngine(audio: false)
        defer { engine.shutdown() }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: w, height: h), device: MTLCreateSystemDefaultDevice())
        let renderer = try #require(CanvasRenderer(view: view))
        renderer.engine = engine
        let offline = OfflineRenderer(scene: doc.scene, pool: MediaPool(diskCacheDirectory: nil))

        for n: Int64 in [0, 17, 44, 9] {
            engine.seek(toFrame: n)
            #expect(await engine.waitUntilSettled(timeout: 30 * Deadline.scale), "frame \(n) never settled")
            let render = Task { @MainActor in await renderer.renderImage(size: CGSize(width: w, height: h)) }
            let snapshot = RGBAImage(try #require(try await Deadline.value(of: render, "snapshot of frame \(n)",
                                                                           seconds: GPUWait.defaultSeconds)))
            #expect(card.decodeFrameNumber(snapshot) == Int(n), "snapshot at frame \(n) shows \(String(describing: card.decodeFrameNumber(snapshot)))")
            let reference = RGBAImage(try await offline.image(at: engine.currentTicks, size: CGSize(width: w, height: h)))
            let d = meanAbsDifference(snapshot, reference)
            #expect(d < 2, "frame \(n): snapshot differs from the offline render by \(d) per channel on average")
        }
    }

    /// Mean absolute RGB difference per channel, 0–255.
    private func meanAbsDifference(_ a: RGBAImage, _ b: RGBAImage) -> Double {
        guard a.width == b.width, a.height == b.height else { return 255 }
        var sum = 0, n = 0
        for y in stride(from: 0, to: a.height, by: 2) {
            for x in stride(from: 0, to: a.width, by: 2) {
                let p = a.pixel(x, y), q = b.pixel(x, y)
                sum += abs(Int(p.r) - Int(q.r)) + abs(Int(p.g) - Int(q.g)) + abs(Int(p.b) - Int(q.b))
                n += 3
            }
        }
        return n > 0 ? Double(sum) / Double(n) : 255
    }
}
