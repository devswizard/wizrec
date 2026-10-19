import CoreGraphics
import Foundation
import ImageIO
import MediaEngine
import Testing
import TSCProjKit
@testable import RenderEngine

private let s = P.rate

/// Reads one pixel of a CGImage as straight 0–255 RGBA (via an sRGB bitmap context).
func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> Px {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    var b = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &b, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
    return Px(r: Int(b[0]), g: Int(b[1]), b: Int(b[2]), a: Int(b[3]))
}

func writePNG(_ img: CGImage, to url: URL) throws {
    guard let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(d, img, nil)
    guard CGImageDestinationFinalize(d) else { throw CocoaError(.fileWriteUnknown) }
}

@Suite(.enabled(if: hasGPU)) struct OfflineRendererTests {
    private func scene() throws -> SceneModel {
        let p = try P.project(tracks: [
            P.track(0, [P.clip("VMFile", id: 10, src: 1, start: 0, duration: s, mediaStart: 2 * s)]),
            P.track(1, [P.clip("VMFile", id: 11, src: 5, start: 0, duration: s, parameters: [
                "scale0": 0.25, "scale1": 0.25, "translation0": 480.0,
            ])]),
        ], sources: P.defaultSources + [P.source(5, "./media/missing.mp4", w: 1920, h: 1080, tracks: [0])],
           background: [0, 0, 255, 255])
        return P.scene(p)
    }

    @Test func rendersPlanWithInjectedFrames() async throws {
        let green = GPUTest.frame(GPUTest.pixelBuffer(32, 18) { _, _ in .green })
        let renderer = OfflineRenderer(scene: try scene(), pool: MediaPool()) { req in
            if req.url.lastPathComponent == "missing.mp4" { throw MediaError.fileNotFound(req.url) }
            #expect(req.time.value == 2 * s && req.stream == 0)
            return green
        }
        let img = try await renderer.image(at: 0)
        #expect(img.width == 1920 && img.height == 1080)
        #expect(pixel(img, 960, 540) == .green)
        #expect(pixel(img, 1400, 540) == .green)  // missing file: layer skipped, green shows through
        let small = try await renderer.image(at: 0, size: CGSize(width: 96, height: 54))
        #expect(small.width == 96 && pixel(small, 48, 27) == .green)
        let none = try await renderer.image(at: 2 * s)  // past the end: background only
        #expect(pixel(none, 960, 540) == .blue)
    }

    @Test func decodeErrorsPropagate() async throws {
        let renderer = OfflineRenderer(scene: try scene(), pool: MediaPool()) { _ in
            throw MediaError.decodeFailed("boom")
        }
        await #expect(throws: MediaError.self) { try await renderer.image(at: 0) }
    }

    @Test func outputIsDeterministic() async throws {
        let pb = GPUTest.frame(GPUTest.pixelBuffer(64, 36) { x, y in Px(r: x * 4, g: y * 7, b: 99, a: 255) })
        let renderer = OfflineRenderer(scene: try scene(), pool: MediaPool()) { _ in pb }
        let a = try await renderer.image(at: s / 2), b = try await renderer.image(at: s / 2)
        #expect(a.dataProvider?.data as Data? == b.dataProvider?.data as Data?)
    }

    /// Visual smoke test on the user's demo project (skips when absent). Effects
    /// (drop shadow, rounded corners, mask, cursor FX) are not drawn in M1.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: demoBundleURL.path)))
    func rendersDemoProject() async throws {
        let bundle = try ProjectBundle(url: demoBundleURL)
        let scene = SceneModel(project: bundle.project, resolve: bundle.resolve)
        let renderer = OfflineRenderer(scene: scene, pool: MediaPool())
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("WizRecRenderDemo")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for sec in [0, 12, 25] {
            let img = try await renderer.image(at: Int64(sec) * s)
            #expect(img.width == 1920 && img.height == 1080)
            let url = out.appendingPathComponent("demo-\(sec)s.png")
            try writePNG(img, to: url)
            print("demo frame \(sec) s → \(url.path)")
            // Screen recording spans x 128…1792 at full height; the shader background shows at the sides.
            let side = pixel(img, 40, 540), centre = pixel(img, 960, 540)
            #expect(side.a == 255 && centre.a == 255)
            #expect(side != centre)
        }
    }

    /// Smoke test on the user's vlog (skips when absent): a plain clip and the 1.5× stitched clip 82.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: vlogBundleURL.path)))
    func rendersVlogProject() async throws {
        let bundle = try ProjectBundle(url: vlogBundleURL)
        let scene = SceneModel(project: bundle.project, resolve: bundle.resolve)
        let renderer = OfflineRenderer(scene: scene, pool: MediaPool())
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("WizRecRenderDemo")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (name, ticks) in [("vlog-3s", 3 * s), ("vlog-clip82", Int64(23_531_760_000 + 2_000_000_000))] {
            let img = try await renderer.image(at: ticks, size: CGSize(width: 960, height: 540))
            let url = out.appendingPathComponent("\(name).png")
            try writePNG(img, to: url)
            print("vlog frame → \(url.path)")
            // 2688×1512 at 0.714 = 1920×1080: fills the canvas, so the centre is not background black.
            #expect(pixel(img, 480, 270) != .black)
        }
    }
}
