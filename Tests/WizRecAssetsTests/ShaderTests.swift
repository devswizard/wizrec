import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
import WizRecAssets
import WizRecTestSupport
@testable import RenderEngine

private let device = MTLCreateSystemDefaultDevice()
private let hasGPU = device != nil

/// Draws one shader-background layer through RenderEngine's public compositor and returns
/// RGBA bytes (row-major, top row first).
private struct ShaderRig {
    let compositor: Compositor
    let queue: any MTLCommandQueue
    let dir: URL
    let width: Int, height: Int

    init(width: Int = 64, height: Int = 36) throws {
        self.width = width; self.height = height
        let d = try #require(device)
        compositor = try Compositor(device: d)
        queue = try #require(d.makeCommandQueue())
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-assets-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func write(_ data: Data, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// True when RenderEngine translates and compiles the file (no fallback gradient).
    func compiles(_ url: URL) throws -> String? {
        let sb = ShaderBackgrounds(device: compositor.device)
        return sb.program(url) == nil ? (sb.failures[url] ?? "unknown failure") : nil
    }

    func render(_ url: URL, parameters: [String: Double] = [:], time: Double = 0) throws -> [SIMD4<UInt8>] {
        let size = CGSize(width: width, height: height)
        let plan = RenderPlan(time: 0, canvasSize: size, background: RGBA(0, 0, 0, 0),
                              layers: [Layer(clipID: 1, content: .shader(url, parameters: parameters, time: time),
                                             size: size)])
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                            mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        let tex = try #require(compositor.device.makeTexture(descriptor: desc))
        let cb = try #require(queue.makeCommandBuffer())
        try compositor.encode(plan, frames: [:], into: tex, commandBuffer: cb)
        try GPUWait.commitAndWait(cb, "shader render \(url.lastPathComponent)")
        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        tex.getBytes(&bgra, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return stride(from: 0, to: bgra.count, by: 4).map { SIMD4(bgra[$0 + 2], bgra[$0 + 1], bgra[$0], bgra[$0 + 3]) }
    }
}

private func maxDiff(_ a: [SIMD4<UInt8>], _ b: [SIMD4<UInt8>]) -> Int {
    zip(a, b).map { x, y in
        (0..<4).map { abs(Int(x[$0]) - Int(y[$0])) }.max() ?? 0
    }.max() ?? 0
}

@Suite(.enabled(if: hasGPU)) struct BackgroundShaderTests {
    @Test(arguments: AssetCatalog.backgrounds.map(\.id))
    func compilesRendersOpaqueAndAnimates(id: String) throws {
        let bg = try #require(AssetCatalog.background(id: id))
        let rig = try ShaderRig()
        let url = try rig.write(try bg.shaderVidData(), bg.fileName)
        if let failure = try rig.compiles(url) {
            Issue.record("\(id) does not compile: \(failure)")
            return
        }
        let params = Dictionary(uniqueKeysWithValues: bg.sourceEffectParameters.map { ($0.key, $0.value) })
        let a = try rig.render(url, parameters: params, time: 0)
        let b = try rig.render(url, parameters: params, time: 3)
        #expect(a.allSatisfy { $0.w == 255 }, "\(id) is not opaque")
        #expect(Set(a.map { $0.x }).count > 1 || Set(a.map { $0.z }).count > 1, "\(id) is flat")
        #expect(maxDiff(a, b) > 2, "\(id) does not animate")
        // Speed 0 freezes it.
        var still = params
        still["Speed"] = 0
        #expect(maxDiff(try rig.render(url, parameters: still, time: 0), try rig.render(url, parameters: still, time: 3)) == 0)
    }
}

/// Wraps a transition so it runs as a background: `_Progress` becomes a uniform and the two
/// inputs are test patterns. A = (1, u, v), B = (0, u, v); transparent outside 0…1.
private func harness(_ t: TransitionAsset) -> String {
    """
    uniform float _Progress;
    vec4 textureA(vec2 uv) {
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) { return vec4(0.0); }
        return vec4(1.0, uv.x, uv.y, 1.0);
    }
    vec4 textureB(vec2 uv) {
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) { return vec4(0.0); }
        return vec4(0.0, uv.x, uv.y, 1.0);
    }
    \(t.glsl)
    """
}

@Suite(.enabled(if: hasGPU)) struct TransitionShaderTests {
    @Test(arguments: AssetCatalog.transitions.map(\.name))
    func showsAAtStartAndBAtEnd(name: String) throws {
        let t = try #require(AssetCatalog.transition(named: name))
        let rig = try ShaderRig()
        let obj: [String: Any] = ["name": name, "width": 1920, "height": 1080, "effectDef": [[String: Any]](),
                                  "code": harness(t)]
        let url = try rig.write(try JSONSerialization.data(withJSONObject: obj), "\(name).tscshadervid")
        if let failure = try rig.compiles(url) {
            Issue.record("\(name) does not compile: \(failure)")
            return
        }
        func expected(red: UInt8) -> [SIMD4<UInt8>] {
            (0..<rig.height).flatMap { y in
                (0..<rig.width).map { x in
                    SIMD4(red, UInt8((Double(x) + 0.5) / Double(rig.width) * 255),
                          UInt8((Double(y) + 0.5) / Double(rig.height) * 255), 255)
                }
            }
        }
        let start = try rig.render(url, parameters: ["Progress": 0])
        let end = try rig.render(url, parameters: ["Progress": 1])
        let mid = try rig.render(url, parameters: ["Progress": 0.5])
        #expect(maxDiff(start, expected(red: 255)) <= 4, "\(name) at 0 is not A")
        #expect(maxDiff(end, expected(red: 0)) <= 4, "\(name) at 1 is not B")
        #expect(maxDiff(mid, start) > 8 && maxDiff(mid, end) > 8, "\(name) does nothing mid-way")
    }
}

/// `WIZREC_ASSET_DUMP=<dir> swift test --filter AssetPreview` writes a PNG per background,
/// transition (at progress 0.35) and cursor, for eyeballing changes to the library.
@Suite(.enabled(if: hasGPU && ProcessInfo.processInfo.environment["WIZREC_ASSET_DUMP"] != nil))
struct AssetPreview {
    private func png(_ px: [SIMD4<UInt8>], _ w: Int, _ h: Int, _ url: URL) throws {
        var bytes = px.flatMap { [$0.x, $0.y, $0.z, $0.w] }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let img = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test func dump() throws {
        let out = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WIZREC_ASSET_DUMP"]))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let rig = try ShaderRig(width: 480, height: 270)
        for bg in AssetCatalog.backgrounds {
            let url = try rig.write(try bg.shaderVidData(), bg.fileName)
            let params = Dictionary(uniqueKeysWithValues: bg.sourceEffectParameters.map { ($0.key, $0.value) })
            try png(try rig.render(url, parameters: params, time: 2), rig.width, rig.height,
                    out.appendingPathComponent("bg-\(bg.id).png"))
        }
        for t in AssetCatalog.transitions {
            let obj: [String: Any] = ["name": t.name, "effectDef": [[String: Any]](), "code": harness(t)]
            let url = try rig.write(try JSONSerialization.data(withJSONObject: obj), "\(t.name).tscshadervid")
            try png(try rig.render(url, parameters: ["Progress": 0.35]), rig.width, rig.height,
                    out.appendingPathComponent("tr-\(t.name).png"))
        }
        for c in AssetCatalog.cursors {
            try c.pngData(scale: 4)?.write(to: out.appendingPathComponent("cursor-\(c.id).png"))
        }
    }
}
