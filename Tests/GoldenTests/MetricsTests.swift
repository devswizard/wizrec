import CoreGraphics
import Foundation
import TestGenKit
import Testing

/// Deterministic pseudo-random numbers (SplitMix64) so metric tests never flake.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Standard normal sample (Box–Muller).
    mutating func gaussian() -> Double {
        let u1 = max(Double.ulpOfOne, Double.random(in: 0..<1, using: &self))
        let u2 = Double.random(in: 0..<1, using: &self)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// Grey image from a function of (x, y) → 0…255.
func grey(_ w: Int, _ h: Int, _ v: (Int, Int) -> Double) -> RGBAImage {
    var p = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let g = UInt8(max(0, min(255, v(x, y).rounded())))
            let o = 4 * (y * w + x)
            p[o] = g; p[o + 1] = g; p[o + 2] = g
        }
    }
    return RGBAImage(width: w, height: h, pixels: p)
}

/// A smooth-ish textured test image, values within 40…215 so ±3σ noise rarely clips.
func texture(_ w: Int, _ h: Int) -> RGBAImage {
    grey(w, h) { x, y in
        127.5 + 50 * sin(Double(x) / 7) * cos(Double(y) / 5) + 30 * sin(Double(x + 2 * y) / 13)
    }
}

func addNoise(_ img: RGBAImage, sigma: Double, seed: UInt64) -> RGBAImage {
    var rng = SplitMix(state: seed)
    var p = img.pixels
    for i in stride(from: 0, to: p.count, by: 4) {
        let n = sigma * rng.gaussian()
        for c in 0..<3 { p[i + c] = UInt8(max(0, min(255, (Double(p[i + c]) + n).rounded()))) }
    }
    return RGBAImage(width: img.width, height: img.height, pixels: p)
}

/// Straightforward SSIM: explicit 11×11 window sums over the valid region, in Double.
func naiveSSIM(_ a: RGBAImage, _ b: RGBAImage) -> Double {
    let x = Metrics.luma(a).map(Double.init), y = Metrics.luma(b).map(Double.init)
    let w = a.width, h = a.height, r = Metrics.windowSize / 2
    let g = Metrics.gaussian.map(Double.init)
    let c1 = (0.01 * 255.0) * (0.01 * 255.0), c2 = (0.03 * 255.0) * (0.03 * 255.0)
    var total = 0.0, count = 0
    for cy in r..<(h - r) {
        for cx in r..<(w - r) {
            var mx = 0.0, my = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
            for dy in -r...r {
                for dx in -r...r {
                    let k = g[dy + r] * g[dx + r], i = (cy + dy) * w + cx + dx
                    mx += k * x[i]; my += k * y[i]
                    sxx += k * x[i] * x[i]; syy += k * y[i] * y[i]; sxy += k * x[i] * y[i]
                }
            }
            let vx = sxx - mx * mx, vy = syy - my * my, cxy = sxy - mx * my
            total += ((2 * mx * my + c1) * (2 * cxy + c2)) / ((mx * mx + my * my + c1) * (vx + vy + c2))
            count += 1
        }
    }
    return total / Double(count)
}

@Suite struct MetricsTests {
    @Test func gaussianWindowIsNormalised() {
        #expect(Metrics.gaussian.count == 11)
        #expect(abs(Metrics.gaussian.reduce(0, +) - 1) < 1e-6)
        #expect(Metrics.gaussian[5] > Metrics.gaussian[4] && Metrics.gaussian[0] == Metrics.gaussian[10])
    }

    @Test func lumaUsesBT709Weights() {
        let img = RGBAImage(width: 3, height: 1, pixels: [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255])
        let y = Metrics.luma(img)
        #expect(abs(y[0] - 0.2126 * 255) < 1e-3)
        #expect(abs(y[1] - 0.7152 * 255) < 1e-3)
        #expect(abs(y[2] - 0.0722 * 255) < 1e-3)
    }

    @Test func identicalImagesScoreOneAndInfinity() {
        let img = texture(64, 48)
        #expect(Metrics.ssim(img, img).mean == 1)
        #expect(Metrics.psnr(img, img) == .infinity)
    }

    /// Flat images: the structure/contrast terms are C2/C2 = 1, so SSIM reduces to the
    /// luminance term (2ab + C1) / (a² + b² + C1).
    @Test func flatImagesMatchClosedForm() {
        let a = 100.0, b = 120.0, c1 = (0.01 * 255.0) * (0.01 * 255.0)
        let s = Metrics.ssim(grey(32, 32) { _, _ in a }, grey(32, 32) { _, _ in b })
        #expect(abs(s.mean - (2 * a * b + c1) / (a * a + b * b + c1)) < 1e-5)
        #expect(s.mapWidth == 22 && s.mapHeight == 22)
    }

    @Test func matchesNaiveImplementation() {
        let a = texture(40, 31)
        let b = addNoise(grey(40, 31) { x, y in 127.5 + 50 * sin(Double(x + 1) / 7) * cos(Double(y) / 5) }, sigma: 6, seed: 7)
        #expect(abs(Metrics.ssim(a, b).mean - naiveSSIM(a, b)) < 1e-4)
    }

    /// Additive white Gaussian noise of σ gives PSNR ≈ 20·log10(255/σ).
    @Test(arguments: [5.0, 10.0, 20.0])
    func psnrOfGaussianNoise(sigma: Double) {
        let img = texture(128, 96)
        let noisy = addNoise(img, sigma: sigma, seed: 42)
        let expected = 20 * log10(255 / sigma)
        #expect(abs(Metrics.psnr(img, noisy) - expected) < 0.35, "σ \(sigma)")
    }

    @Test func ssimFallsAsNoiseRises() {
        let img = texture(128, 96)
        let s = [2.0, 5.0, 10.0, 20.0, 40.0].map { Metrics.ssim(img, addNoise(img, sigma: $0, seed: 1)).mean }
        #expect(zip(s, s.dropFirst()).allSatisfy { $0 > $1 }, "\(s)")
        #expect(s[0] > 0.97 && s[0] < 1)
        #expect(s[4] < 0.7)
    }

    @Test func onePixelShiftOfSmoothRampStaysHigh() {
        let ramp = grey(96, 64) { x, y in Double(x) * 2 + Double(y) }
        let shifted = grey(96, 64) { x, y in Double(x + 1) * 2 + Double(y) }
        let s = Metrics.ssim(ramp, shifted).mean
        #expect(s > 0.99 && s < 1)
    }

    /// A 1-px checkerboard shifted by one pixel is its own negative: SSIM ≈ −1.
    @Test func shiftedCheckerboardIsAnticorrelated() {
        let a = grey(48, 48) { x, y in (x + y) % 2 == 0 ? 40 : 215 }
        let b = grey(48, 48) { x, y in (x + y + 1) % 2 == 0 ? 40 : 215 }
        #expect(Metrics.ssim(a, b).mean < -0.9)
        #expect(Metrics.ssim(a, grey(48, 48) { x, y in (x + y) % 2 == 0 ? 215 : 40 }).mean < -0.9)
    }

    @Test func autoDownsampleFollowsWang() {
        #expect(Metrics.autoDownsample(width: 1920, height: 1080) == 4)
        #expect(Metrics.autoDownsample(width: 640, height: 360) == 1)
        let img = texture(64, 64)
        let (d, w, h) = Metrics.downsample(Metrics.luma(img), width: 64, height: 64, by: 2)
        #expect(w == 32 && h == 32 && d.count == 1024)
        let l = Metrics.luma(img)
        #expect(abs(d[0] - (l[0] + l[1] + l[64] + l[65]) / 4) < 1e-4)
    }

    @Test func differenceImageIsScaledAbsoluteDifference() {
        let a = RGBAImage(width: 1, height: 1, fill: (10, 200, 100))
        let b = RGBAImage(width: 1, height: 1, fill: (20, 150, 100))
        let d = Metrics.difference(a, b, gain: 4)
        #expect(d.pixel(0, 0) == (40, 200, 0, 255))
    }

    /// `RGBAImage` reads 8-bit images byte-exact whatever the memory layout.
    @Test func rgbaImageReadsBGRAAndRGBA() throws {
        let src = RGBAImage(width: 2, height: 1, pixels: [255, 0, 0, 255, 10, 20, 30, 255])
        let rgba = try #require(src.cgImage())
        #expect(RGBAImage(rgba) == src)
        let ctx = try #require(CGContext(
            data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        ctx.draw(rgba, in: CGRect(x: 0, y: 0, width: 2, height: 1))
        let bgra = try #require(ctx.makeImage())
        #expect(RGBAImage(bgra) == src)
    }
}
