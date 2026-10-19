import CoreGraphics
import ImageIO
import Foundation
import MediaEngine
import TSCProjKit
import Testing
@testable import RenderEngine

/// Effects on the user's demo project (skips when absent).
@Suite(.enabled(if: FileManager.default.fileExists(atPath: demoBundleURL.path)))
struct DemoEffectsTests {
    @Test func cameraCarriesMaskAndRoundCorners() throws {
        let bundle = try ProjectBundle(url: demoBundleURL)
        let plan = SceneModel(project: bundle.project, resolve: bundle.resolve).evaluate(at: 0)
        func all(_ ls: [Layer]) -> [Layer] {
            ls.flatMap { l -> [Layer] in
                if case .group(let c) = l.content { return [l] + all(c) }
                return [l]
            }
        }
        let layers = all(plan.layers)
        let camera = try #require(layers.first { $0.clipID == 8 })
        #expect(camera.effects.map(\.name) == ["RoundCorners", "Mask"])
        #expect(EffectRegistry.active(camera.effects).map(\.0.name) == ["Mask", "RoundCorners"])
        let screen = try #require(layers.first { $0.clipID == 6 })
        #expect(screen.effects.first?.name == "DropShadow")
    }

    /// The translated shader background matches Camtasia's own render of the demo: the
    /// `ProjectThumbnail` (640×360, playhead 8537760000 ticks = 12.1 s) in the strips where only
    /// the background shows [shader-backgrounds.md S2].
    @Test(.enabled(if: hasGPU)) func shaderBackgroundMatchesProjectThumbnail() async throws {
        let bundle = try ProjectBundle(url: demoBundleURL)
        let b64 = try #require(bundle.project.root["metadata"]?.object?["ProjectThumbnail"]?.string)
        let data = try #require(Data(base64Encoded: b64))
        let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let thumb = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(thumb.width == 640 && thumb.height == 360)

        let scene = SceneModel(project: bundle.project, resolve: bundle.resolve)
        let renderer = OfflineRenderer(scene: scene, pool: MediaPool())
        let img = try await renderer.image(at: 8_537_760_000, size: CGSize(width: 640, height: 360))
        let a = RGBABitmap(thumb), b = RGBABitmap(img)
        var sum = 0.0, n = 0.0, worst = 0
        for y in stride(from: 0, to: 360, by: 3) {
            for x in Array(0..<25) + Array(615..<640) {
                let p = a.at(x, y), q = b.at(x, y)
                for (u, v) in [(p.r, q.r), (p.g, q.g), (p.b, q.b)] {
                    sum += Double((u - v) * (u - v)); n += 1; worst = max(worst, abs(u - v))
                }
            }
        }
        let rms = (sum / n).squareRoot()
        if let dir = ProcessInfo.processInfo.environment["WIZREC_RENDER_OUT"] {
            try writePNG(img, to: URL(fileURLWithPath: dir).appendingPathComponent("demo-thumb-ours.png"))
        }
        print("demo background vs ProjectThumbnail: RMS \(rms), max \(worst) (0–255)")
        #expect(rms < 2.0)
        #expect(worst <= 8)
    }
}

/// A CGImage drawn into straight-alpha sRGB RGBA bytes.
struct RGBABitmap {
    let width, height: Int
    let bytes: [UInt8]
    init(_ img: CGImage) {
        let w = img.width, h = img.height
        width = w; height = h
        var b = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        b.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        bytes = b
    }
    func at(_ x: Int, _ y: Int) -> Px {
        let i = (y * width + x) * 4
        return Px(r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]), a: Int(bytes[i + 3]))
    }
}
