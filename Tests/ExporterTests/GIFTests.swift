import CoreGraphics
import Foundation
import ImageIO
import MediaEngine
import RenderEngine
import TestGenKit
import Testing
import TSCProjKit
import WizRecTestSupport
@testable import Exporter

/// Decoded GIF: composited frames (ImageIO applies disposal and transparency) and delays in s.
struct DecodedGIF {
    var frames: [RGBAImage]
    var delays: [Double]
    var loopCount: Int?
}

func decodeGIF(_ url: URL) throws -> DecodedGIF {
    let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    #expect(CGImageSourceGetType(src) as String? == "com.compuserve.gif")
    let n = CGImageSourceGetCount(src)
    var frames: [RGBAImage] = [], delays: [Double] = []
    for i in 0..<n {
        let img = try #require(CGImageSourceCreateImageAtIndex(src, i, nil))
        frames.append(RGBAImage(img))
        let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [String: Any]
        let gif = props?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        let d = (gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double)
            ?? (gif?[kCGImagePropertyGIFDelayTime as String] as? Double) ?? 0
        delays.append(d)
    }
    let fileProps = CGImageSourceCopyProperties(src, nil) as? [String: Any]
    let loop = (fileProps?[kCGImagePropertyGIFDictionary as String] as? [String: Any])?[
        kCGImagePropertyGIFLoopCount as String] as? Int
    return DecodedGIF(frames: frames, delays: delays, loopCount: loop)
}

struct GIFEncoderTests {
    /// Deterministic pseudo-random bytes.
    func noise(_ n: Int, mod: Int, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) -> [UInt8] {
        var s = seed
        return (0..<n).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(Int(s >> 33) % mod)
        }
    }

    /// LZW output (incl. table-full clears and code-size steps) decodes to the exact indices.
    @Test(arguments: [2, 4, 16, 255])
    func lzwRoundTripsThroughImageIO(colors: Int) throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let w = 211, h = 157
        // Mix of noise (fills the table fast) and runs (long codes).
        var idx = noise(w * h, mod: colors)
        for i in stride(from: 0, to: idx.count, by: 977) { for k in i..<min(i + 300, idx.count) { idx[k] = 1 } }
        let palette = Palette(colors: (0..<colors).map { (i: Int) -> (UInt8, UInt8, UInt8) in
            let r: Int = i * 37 % 256, g: Int = i * 91 % 256, b: Int = 255 - i
            return (UInt8(r), UInt8(g), UInt8(b))
        })
        let url = dir.appendingPathComponent("lzw.gif")
        let f = try GIFFileWriter(url: url, width: w, height: h, loopCount: 0)
        try f.addFrame(indices: idx, rect: (0, 0, w, h), palette: palette, transparent: nil, delay: 10)
        try f.close()
        let g = try decodeGIF(url)
        #expect(g.frames.count == 1)
        let img = try #require(g.frames.first)
        var mismatches = 0
        for i in 0..<(w * h) {
            let c = palette.colors[Int(idx[i])]
            let p = 4 * i
            if img.pixels[p] != c.r || img.pixels[p + 1] != c.g || img.pixels[p + 2] != c.b { mismatches += 1 }
        }
        #expect(mismatches == 0)
    }

    @Test func subRectFramesWithTransparencyComposite() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pal = Palette(colors: [(255, 0, 0), (0, 0, 255)])
        let url = dir.appendingPathComponent("sub.gif")
        let f = try GIFFileWriter(url: url, width: 8, height: 8, loopCount: 3)
        try f.addFrame(indices: [UInt8](repeating: 0, count: 64), rect: (0, 0, 8, 8), palette: pal,
                       transparent: nil, delay: 7)
        // 2×2 patch at (3,3): top-left blue, rest transparent (index 2).
        try f.addFrame(indices: [1, 2, 2, 2], rect: (3, 3, 2, 2), palette: pal, transparent: 2, delay: 9)
        try f.close()
        let g = try decodeGIF(url)
        #expect(g.frames.count == 2)
        #expect(g.loopCount == 4, "ImageIO reports total plays: 1 + NETSCAPE repeat count")
        #expect(abs(g.delays[0] - 0.07) < 1e-6 && abs(g.delays[1] - 0.09) < 1e-6)
        let second = g.frames[1]
        #expect(second.pixel(3, 3).b == 255 && second.pixel(3, 3).r == 0)
        #expect(second.pixel(4, 4).r == 255, "transparent pixel keeps the previous frame")
        #expect(second.pixel(0, 0).r == 255)
    }

    @Test func delaysSumExactly() {
        for fps in [7, 10, 15, 24, 30, 50] {
            let total = (0..<(fps * 3)).reduce(0) { $0 + GIFFileWriter.delay(frame: $1, fps: fps) }
            #expect(total == 300, "fps \(fps)")
        }
    }

    @Test func medianCutKeepsDistinctColoursAndIsDeterministic() {
        let colours: [[UInt8]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 255]]
        let img = (0..<400).flatMap { colours[$0 % 4] }
        let p = Palette.medianCut([img], maxColors: 8)
        #expect(p.colors.count == 4)
        for c in colours {
            #expect(p.colors.contains { $0 == (c[0], c[1], c[2]) })
        }
        #expect(Palette.medianCut([img], maxColors: 8) == p)
        let two = Palette.medianCut([img], maxColors: 2)
        #expect(two.colors.count == 2)
        // Never more than the cap, even for noisy input.
        let noisy = noise(30_000, mod: 256)
        #expect(Palette.medianCut([noisy], maxColors: 255).colors.count <= 255)
    }

    @Test func ditherOffMapsToNearest() {
        var q = Quantizer(palette: Palette(colors: [(0, 0, 0), (255, 255, 255)]))
        let out = q.indices([10, 10, 10, 250, 250, 250, 100, 100, 100], width: 3, height: 1, dither: false)
        #expect(out == [0, 1, 0])
    }
}

@Suite(.enabled(if: hasGPU), .serialized) struct GIFExportTests {
    @Test func gifMatchesPreviewFramesAndTiming() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await movingProject(frames: 30)  // 1 s at 30 fps
        var s = ExportSettings(format: .gif(fps: 10))
        s.size = CGSize(width: 240, height: 240)
        let out = dir.appendingPathComponent("a.gif")
        try await export(p, s, to: out)
        let g = try decodeGIF(out)
        #expect(g.loopCount == 0)
        let totalDelay: Double = g.delays.reduce(0, +)
        #expect(abs(totalDelay - 1.0) < 1e-6, "\(g.delays)")
        #expect(g.frames.first?.width == 240 && g.frames.first?.height == 135)
        // Rebuild the per-output-frame image list (merged identical frames last longer).
        var shown: [RGBAImage] = []
        for (f, d) in zip(g.frames, g.delays) {
            for _ in 0..<Int((d * 10).rounded()) { shown.append(f) }
        }
        #expect(shown.count == 10)
        let renderer = OfflineRenderer(scene: p.scene, pool: MediaPool())
        let timing = FrameTiming(editRate: p.scene.timebase.editRate, fps: Rational(10), range: 0..<p.scene.duration)
        for n in [0, 3, 9] where n < shown.count {
            let ref = RGBAImage(try await renderer.image(at: timing.ticks(frame: n), size: CGSize(width: 240, height: 135)))
            let score = ssim(shown[n], ref)
            #expect(score >= 0.85, "GIF frame \(n): SSIM \(score)")
        }
    }

    @Test func staticSceneCollapsesToOneFrame() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await makeProject { b, m in
            b.tracks = [[b.image(m[.card]!, start: 0, duration: 30 * tpf)]]
        }
        var s = ExportSettings(format: .gif(fps: 15))
        s.gif.dither = false
        let out = dir.appendingPathComponent("still.gif")
        try await export(p, s, to: out)
        let g = try decodeGIF(out)
        #expect(g.frames.count == 1)
        #expect(abs((g.delays.first ?? 0) - 1.0) < 1e-6)
    }

    @Test func cancelledGIFLeavesNothing() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await movingProject(frames: 290)
        let out = dir.appendingPathComponent("c.gif")
        let session = ExportSession(scene: p.scene, audio: p.audio, pool: MediaPool(),
                                    settings: ExportSettings(format: .gif(fps: 30)), output: out)
        let run = Task { try await session.run() }
        try await Deadline.poll("export progress to reach 5 %", seconds: 60) { await session.progress >= 0.05 }
        await session.cancel()
        await #expect(throws: ExportError.cancelled) {
            try await Deadline.value(of: run, "export to stop after cancel", seconds: 60)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}
