import CoreGraphics
import Foundation
import MediaEngine
import Metal
import RenderEngine
import Testing
import TestGenKit
import TSCProjKit

// Extend Frame (edit-semantics.md ED1): an IMFile whose source is a video holds that video's frame at
// the IMFile's `mediaStart`, decoded through MediaPool, for the whole segment.

@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
@MainActor struct ExtendFrameIntegrationTests {
    static let fps = 30, frames = 30, w = 160, h = 90

    /// A 1 s movie whose frame n is a flat grey of level 8·n; a StitchedMedia [VMFile 0–1 s, IMFile at the
    /// last frame (29/30 s) with a huge segment duration], 1.5 s long.
    private func bundle(in dir: URL) async throws -> ProjectBundle {
        let pkg = dir.appendingPathComponent("extend.cmproj", isDirectory: true)
        let media = pkg.appendingPathComponent("media/1", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let w = Self.w, h = Self.h
        let movie = try await MediaWriter.writeH264(to: media.appendingPathComponent("ramp.mp4"), width: w, height: h,
                                                    fps: Self.fps, frameCount: Self.frames) { n, ctx in
            let g = CGFloat(8 * n) / 255
            ctx.setFillColor(CGColor(srgbRed: g, green: g, blue: g, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        let b = ProjectBuilder(title: "extend", width: Self.w, height: Self.h, fps: Int64(Self.fps))
        let src = b.addVideoSource(src: "./media/1/ramp.mp4", movie: movie)
        let st = b.stitched(src, segments: [(mediaStart: 0, duration: b.frames(30))], start: 0, duration: b.frames(45))
        let frame = b.image(src, start: b.frames(30), duration: b.frames(30) * 3600)
        frame["mediaStart"] = .number(JSONNumber(b.frames(29)))
        st["medias"] = .array(JSONArray((st["medias"]?.array?.items ?? []) + [.object(frame)]))
        b.tracks = [[st]]
        try b.build().serialized().write(to: pkg.appendingPathComponent("project.tscproj"))
        return try ProjectBundle(url: pkg)
    }

    private func centre(_ img: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(img, in: CGRect(x: -img.width / 2, y: -img.height / 2, width: img.width, height: img.height))
        return px
    }

    @Test func heldFrameIsTheVideosLastFrame() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-extend-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try await bundle(in: dir)
        let r = OfflineRenderer(scene: SceneModel(project: bundle.project, resolve: bundle.resolve),
                                pool: MediaPool(diskCacheDirectory: nil))
        let f = bundle.project.timebase.editRate / Int64(Self.fps)
        let first = centre(try await r.image(at: 0))
        let last = centre(try await r.image(at: 29 * f))
        #expect(abs(Int(last[0]) - 232) <= 6 && abs(Int(first[0]) - 0) <= 6)
        // Every time in the extension shows exactly that frame (the IMFile's duration/trim do not choose it).
        for n in [30, 37, 44] {
            #expect(centre(try await r.image(at: Int64(n) * f)) == last, "frame \(n)")
        }
    }
}
