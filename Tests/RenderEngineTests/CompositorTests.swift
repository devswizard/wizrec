import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import MediaEngine
import Metal
import Testing
@testable import RenderEngine

let gpu = MTLCreateSystemDefaultDevice()
let hasGPU = gpu != nil

/// BGRA pixel (straight 0–255 values as stored).
struct Px: Equatable, CustomStringConvertible {
    var r, g, b, a: Int
    var description: String { "(\(r),\(g),\(b),\(a))" }
    func near(_ o: Px, _ tol: Int = 3) -> Bool {
        abs(r - o.r) <= tol && abs(g - o.g) <= tol && abs(b - o.b) <= tol && abs(a - o.a) <= tol
    }
    static let red = Px(r: 255, g: 0, b: 0, a: 255), green = Px(r: 0, g: 255, b: 0, a: 255)
    static let blue = Px(r: 0, g: 0, b: 255, a: 255), black = Px(r: 0, g: 0, b: 0, a: 255)
    static let white = Px(r: 255, g: 255, b: 255, a: 255)
}

enum GPUTest {
    /// IOSurface-backed, Metal-compatible 32BGRA buffer filled by `color(x, y)`.
    static func pixelBuffer(_ w: Int, _ h: Int, _ color: (Int, Int) -> Px) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<h {
            for x in 0..<w {
                let c = color(x, y), p = base + y * row + x * 4
                p[0] = UInt8(c.b); p[1] = UInt8(c.g); p[2] = UInt8(c.r); p[3] = UInt8(c.a)
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    static func frame(_ pb: CVPixelBuffer) -> VideoFrame {
        VideoFrame(pixelBuffer: pb, presentationTime: .zero, duration: .invalid)
    }

    static func request(_ name: String) -> FrameRequest {
        FrameRequest(url: URL(fileURLWithPath: "/synthetic/\(name).mov"), stream: 0, time: .zero)
    }

    struct Image {
        let width, height: Int
        let bytes: [UInt8]
        func at(_ x: Int, _ y: Int) -> Px {
            let i = (y * width + x) * 4
            return Px(r: Int(bytes[i + 2]), g: Int(bytes[i + 1]), b: Int(bytes[i]), a: Int(bytes[i + 3]))
        }
    }

    /// Composites `plan` into a `w`×`h` target and reads it back.
    static func render(_ plan: RenderPlan, frames: [FrameRequest: VideoFrame] = [:], _ w: Int = 192, _ h: Int = 108,
                       gpuTime: UnsafeMutablePointer<Double>? = nil) throws -> Image {
        let device = try #require(gpu)
        let comp = try Compositor(device: device)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: d))
        let queue = try #require(device.makeCommandQueue())
        let cb = try #require(queue.makeCommandBuffer())
        try comp.encode(plan, frames: frames, into: target, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        #expect(cb.status == .completed, "\(String(describing: cb.error))")
        gpuTime?.pointee = cb.gpuEndTime - cb.gpuStartTime
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        target.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return Image(width: w, height: h, bytes: bytes)
    }
}

private let canvas = CGSize(width: 192, height: 108)

private func plan(_ layers: [Layer], bg: RGBA = RGBA(0, 0, 0), canvasSize: CGSize = canvas) -> RenderPlan {
    RenderPlan(time: 0, canvasSize: canvasSize, background: bg, layers: layers)
}

private func solid(_ name: String, _ c: Px, _ w: Int = 16, _ h: Int = 16) -> (FrameRequest, VideoFrame) {
    (GPUTest.request(name), GPUTest.frame(GPUTest.pixelBuffer(w, h) { _, _ in c }))
}

@Suite(.enabled(if: hasGPU)) struct CompositorTests {
    @Test func backgroundFillsTarget() throws {
        let img = try GPUTest.render(plan([], bg: RGBA(1, 0, 0)))
        #expect(img.at(0, 0) == .red && img.at(191, 107) == .red && img.at(96, 54) == .red)
    }

    @Test func fullCanvasLayerCoversTarget() throws {
        let (rq, fr) = solid("g", .green)
        let l = Layer(clipID: 1, content: .video(rq), size: canvas)
        let img = try GPUTest.render(plan([l]), frames: [rq: fr])
        #expect(img.at(0, 0) == .green && img.at(191, 107) == .green)
    }

    @Test func translationIsCentreOriginYUp() throws {
        let (rq, fr) = solid("g", .green)
        // 20×20 layer at (+50, +30): occupies x 136…156, y (down) 14…34 in the target.
        let l = Layer(clipID: 1, content: .video(rq), size: CGSize(width: 20, height: 20),
                      transform: CGAffineTransform(translationX: 50, y: 30))
        let img = try GPUTest.render(plan([l]), frames: [rq: fr])
        #expect(img.at(146, 24) == .green)
        #expect(img.at(146, 84) == .black)  // mirrored y would be here
        #expect(img.at(137, 15) == .green && img.at(155, 33) == .green)
        #expect(img.at(134, 24) == .black && img.at(158, 24) == .black)
    }

    @Test func textureOrientationIsUpright() throws {
        // Top half red, bottom half blue in the source buffer (row 0 = top).
        let pb = GPUTest.pixelBuffer(16, 16) { _, y in y < 8 ? .red : .blue }
        let rq = GPUTest.request("tb")
        let img = try GPUTest.render(plan([Layer(clipID: 1, content: .video(rq), size: canvas)]),
                                     frames: [rq: GPUTest.frame(pb)])
        #expect(img.at(96, 10) == .red && img.at(96, 98) == .blue)
    }

    @Test func scaleAndRotation() throws {
        // Source: left half red, right half blue. 40×20 layer scaled ×2 then rotated 90° CCW:
        // the red (left) half ends up at the bottom.
        let pb = GPUTest.pixelBuffer(16, 16) { x, _ in x < 8 ? .red : .blue }
        let rq = GPUTest.request("lr")
        let t = CGAffineTransform(scaleX: 2, y: 2).concatenating(CGAffineTransform(rotationAngle: .pi / 2))
        let l = Layer(clipID: 1, content: .video(rq), size: CGSize(width: 40, height: 20), transform: t)
        let img = try GPUTest.render(plan([l]), frames: [rq: GPUTest.frame(pb)])
        // Rotated quad: 40 wide (x 76…116), 80 tall (y 14…94).
        #expect(img.at(96, 80) == .red)   // below centre
        #expect(img.at(96, 28) == .blue)  // above centre
        #expect(img.at(70, 54) == .black && img.at(122, 54) == .black)
    }

    @Test func opacityBlendsPremultiplied() throws {
        let (rq, fr) = solid("w", .white)
        let l = Layer(clipID: 1, content: .video(rq), size: canvas, opacity: 0.5)
        let px = try GPUTest.render(plan([l]), frames: [rq: fr]).at(96, 54)
        #expect(px.near(Px(r: 128, g: 128, b: 128, a: 255), 2), "\(px)")
    }

    @Test func translucentSourcePixelsAreComposited() throws {
        // Premultiplied 50 % red over the green layer below.
        let below = solid("g", .green), above = solid("r", Px(r: 128, g: 0, b: 0, a: 128))
        let img = try GPUTest.render(plan([Layer(clipID: 1, content: .video(below.0), size: canvas),
                                           Layer(clipID: 2, content: .video(above.0), size: canvas)]),
                                     frames: [below.0: below.1, above.0: above.1])
        #expect(img.at(96, 54).near(Px(r: 128, g: 127, b: 0, a: 255), 2), "\(img.at(96, 54))")
    }

    @Test func geometryCropTrimsWithoutMoving() throws {
        let pb = GPUTest.pixelBuffer(16, 16) { x, _ in x < 8 ? .red : .blue }
        let rq = GPUTest.request("lr")
        let l = Layer(clipID: 1, content: .video(rq), size: canvas, geometryCrop: Insets(left: 0.25, top: 0.5))
        let img = try GPUTest.render(plan([l]), frames: [rq: GPUTest.frame(pb)])
        #expect(img.at(20, 80) == .black)   // left quarter cropped
        #expect(img.at(70, 80) == .red)     // still red: pixels did not move
        #expect(img.at(150, 80) == .blue)
        #expect(img.at(150, 20) == .black)  // top half cropped
    }

    @Test func sourceCropTrimsInSourceSpace() throws {
        let pb = GPUTest.pixelBuffer(16, 16) { x, _ in x < 8 ? .red : .blue }
        let rq = GPUTest.request("lr")
        let l = Layer(clipID: 1, content: .video(rq), size: canvas, sourceCrop: Insets(right: 0.5))
        let img = try GPUTest.render(plan([l]), frames: [rq: GPUTest.frame(pb)])
        #expect(img.at(40, 54) == .red && img.at(150, 54) == .black)
    }

    @Test func canvasIsLetterboxedIntoTarget() throws {
        let (rq, fr) = solid("g", .green)
        let l = Layer(clipID: 1, content: .video(rq), size: canvas)
        let wide = Layer(clipID: 2, content: .video(rq), size: CGSize(width: 1000, height: 1000))
        // 192×108 canvas into a 100×100 target: fit scale 100/192, canvas rows 22…78.
        let img = try GPUTest.render(plan([wide, l], bg: RGBA(0, 0, 1)), frames: [rq: fr], 100, 100)
        #expect(img.at(50, 50) == .green)
        #expect(img.at(50, 5) == .blue && img.at(50, 95) == .blue)  // oversize layer clipped to canvas
    }

    @Test func flattenedGroupComposesTransforms() throws {
        let (rq, fr) = solid("g", .green)
        let child = Layer(clipID: 2, content: .video(rq), size: CGSize(width: 10, height: 10),
                          transform: CGAffineTransform(translationX: 10, y: 0))
        let group = Layer(clipID: 1, content: .group([child]), size: canvas,
                          transform: CGAffineTransform(scaleX: 2, y: 2).concatenating(.init(translationX: 0, y: 20)))
        let img = try GPUTest.render(plan([group]), frames: [rq: fr])
        // Child centre: group-local (10, 0) → ×2 → (20, 0) → +20 y → canvas (20, 20) → target (116, 34).
        #expect(img.at(116, 34) == .green)
        #expect(img.at(106, 34) == .green && img.at(126, 34) == .black)  // 20 px wide after ×2
    }

    @Test func translucentGroupIsIsolated() throws {
        // Two overlapping opaque children in a 50 % group: overlap shows only the top child at 50 %.
        let r = solid("r", .red), b = solid("b", .blue)
        let group = Layer(clipID: 1, content: .group([
            Layer(clipID: 2, content: .video(r.0), size: canvas),
            Layer(clipID: 3, content: .video(b.0), size: CGSize(width: 96, height: 108)),
        ]), size: canvas, opacity: 0.5)
        let img = try GPUTest.render(plan([group]), frames: [r.0: r.1, b.0: b.1])
        #expect(img.at(96, 54).near(Px(r: 0, g: 0, b: 128, a: 255), 2), "\(img.at(96, 54))")
        #expect(img.at(10, 54).near(Px(r: 128, g: 0, b: 0, a: 255), 2), "\(img.at(10, 54))")
    }

    @Test func croppedGroupClipsChildren() throws {
        let (rq, fr) = solid("g", .green)
        let group = Layer(clipID: 1, content: .group([Layer(clipID: 2, content: .video(rq), size: canvas)]),
                          size: canvas, geometryCrop: Insets(right: 0.5))
        let img = try GPUTest.render(plan([group]), frames: [rq: fr])
        #expect(img.at(40, 54) == .green && img.at(150, 54) == .black)
    }

    @Test func shaderFallbackIsFourCornerGradient() throws {
        let params: [String: Double] = [
            "Color0-red": 1, "Color0-green": 0, "Color0-blue": 0, "Color0-alpha": 1,
            "Color1-red": 0, "Color1-green": 1, "Color1-blue": 0, "Color1-alpha": 1,
            "Color2-red": 0, "Color2-green": 0, "Color2-blue": 1, "Color2-alpha": 1,
            "Color3-red": 1, "Color3-green": 1, "Color3-blue": 1, "Color3-alpha": 1,
        ]
        let l = Layer(clipID: 1, content: .shader(URL(fileURLWithPath: "/bg.tscshadervid"), parameters: params),
                      size: canvas)
        let img = try GPUTest.render(plan([l]))
        #expect(img.at(0, 0).near(.red, 6) && img.at(191, 0).near(.green, 6))
        #expect(img.at(0, 107).near(.blue, 6) && img.at(191, 107).near(.white, 6))
    }

    @Test func missingFramesAndUnsupportedLayersAreSkipped() throws {
        let l1 = Layer(clipID: 1, content: .video(GPUTest.request("missing")), size: canvas)
        let l2 = Layer(clipID: 2, content: .unsupported(type: "Callout"), size: canvas)
        let img = try GPUTest.render(plan([l1, l2], bg: RGBA(0, 1, 0)))
        #expect(img.at(96, 54) == .green)
    }

    @Test func imageLayerLoadsFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-render-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("red.png")
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
        let img = try GPUTest.render(plan([Layer(clipID: 1, content: .image(url), size: canvas)]))
        #expect(img.at(96, 54) == .red)
    }

    @Test func perf1080pEightLayers() throws {
        let size = CGSize(width: 1920, height: 1080)
        var frames: [FrameRequest: VideoFrame] = [:]
        var layers: [Layer] = []
        for i in 0..<8 {
            let rq = GPUTest.request("p\(i)")
            frames[rq] = GPUTest.frame(GPUTest.pixelBuffer(1920, 1080) { x, y in
                Px(r: (x + i) & 255, g: y & 255, b: 128, a: 255) })
            layers.append(Layer(clipID: Int64(i), content: .video(rq), size: size,
                                transform: CGAffineTransform(scaleX: 0.9, y: 0.9).concatenating(.init(rotationAngle: 0.1)),
                                opacity: 0.8))
        }
        let p = RenderPlan(time: 0, canvasSize: size, background: RGBA(0, 0, 0), layers: layers)
        var best = Double.infinity, t = 0.0
        for _ in 0..<5 {
            _ = try GPUTest.render(p, frames: frames, 1920, 1080, gpuTime: &t)
            best = min(best, t)
        }
        print("composite 1080p × 8 layers: \(String(format: "%.3f", best * 1000)) ms GPU")
        #expect(best < 0.004)
    }
}
