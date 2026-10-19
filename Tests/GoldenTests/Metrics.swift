import Accelerate
import Foundation
import TestGenKit

/// Image-quality metrics for golden-frame comparison, built on Accelerate.
///
/// SSIM follows Wang, Bovik, Sheikh & Simoncelli (2004): luma only, 11×11
/// Gaussian window with σ = 1.5, K1 = 0.01, K2 = 0.03, dynamic range L = 255,
/// mean over the "valid" region (no padding: a 5 px border is excluded).
/// Luma is BT.709 (0.2126 R + 0.7152 G + 0.0722 B) on the stored 8-bit values.
enum Metrics {
    struct SSIMResult {
        /// Mean SSIM, −1…1 (1 = identical).
        var mean: Double
        /// Per-pixel SSIM over the valid region, row-major.
        var map: [Float]
        /// Size of `map`, px.
        var mapWidth: Int
        var mapHeight: Int
    }

    static let windowSize = 11
    static let sigma: Float = 1.5
    static let k1: Float = 0.01, k2: Float = 0.03, dynamicRange: Float = 255

    /// Normalised 1-D Gaussian taps (the 2-D window is its outer product).
    static let gaussian: [Float] = {
        let r = windowSize / 2
        let taps = (-r...r).map { i in exp(-Float(i * i) / (2 * sigma * sigma)) }
        let sum = taps.reduce(0, +)
        return taps.map { $0 / sum }
    }()

    /// BT.709 luma, 0–255.
    static func luma(_ img: RGBAImage) -> [Float] {
        let n = img.width * img.height
        var r = [Float](repeating: 0, count: n), g = r, b = r
        img.pixels.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            vDSP_vfltu8(base, 4, &r, 1, vDSP_Length(n))
            vDSP_vfltu8(base + 1, 4, &g, 1, vDSP_Length(n))
            vDSP_vfltu8(base + 2, 4, &b, 1, vDSP_Length(n))
        }
        var y = vDSP.multiply(0.2126, r)
        y = vDSP.add(multiplication: (g, 0.7152), y)
        y = vDSP.add(multiplication: (b, 0.0722), y)
        return y
    }

    /// Block-mean downsampling by an integer factor (Wang's "automatic downsampling" uses
    /// `max(1, round(min(w, h) / 256))`). Returns the new plane and its size.
    static func downsample(_ x: [Float], width: Int, height: Int, by f: Int) -> ([Float], Int, Int) {
        guard f > 1 else { return (x, width, height) }
        let w = width / f, h = height / f
        var out = [Float](repeating: 0, count: w * h)
        let inv = 1 / Float(f * f)
        for oy in 0..<h {
            for ox in 0..<w {
                var s: Float = 0
                for dy in 0..<f {
                    let row = (oy * f + dy) * width + ox * f
                    for dx in 0..<f { s += x[row + dx] }
                }
                out[oy * w + ox] = s * inv
            }
        }
        return (out, w, h)
    }

    /// Gaussian-filtered plane (same size; edges extended, callers keep only the valid region).
    static func blur(_ x: [Float], width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: x.count)
        var src = x
        let k = gaussian
        src.withUnsafeMutableBufferPointer { sp in
            out.withUnsafeMutableBufferPointer { dp in
                var s = vImage_Buffer(data: sp.baseAddress, height: vImagePixelCount(height),
                                      width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.stride)
                var d = vImage_Buffer(data: dp.baseAddress, height: vImagePixelCount(height),
                                      width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.stride)
                _ = vImageSepConvolve_PlanarF(&s, &d, nil, 0, 0, k, UInt32(k.count), k, UInt32(k.count),
                                              0, 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
        return out
    }

    /// Crops the `windowSize/2` border that a valid-mode convolution would not produce.
    static func valid(_ x: [Float], width: Int, height: Int) -> ([Float], Int, Int) {
        let r = windowSize / 2
        let w = width - 2 * r, h = height - 2 * r
        var out = [Float]()
        out.reserveCapacity(w * h)
        for y in r..<(height - r) { out.append(contentsOf: x[(y * width + r)..<(y * width + r + w)]) }
        return (out, w, h)
    }

    /// SSIM of two equally sized luma planes (0–255).
    static func ssim(lumaA x: [Float], lumaB y: [Float], width: Int, height: Int) -> SSIMResult {
        precondition(x.count == width * height && y.count == x.count, "plane size mismatch")
        precondition(width >= windowSize && height >= windowSize, "image smaller than the SSIM window")
        let c1 = (k1 * dynamicRange) * (k1 * dynamicRange)
        let c2 = (k2 * dynamicRange) * (k2 * dynamicRange)
        // (Co)variances are shift-invariant: compute them on values centred at 128 so
        // E[x²] − μ² doesn't lose Float precision on bright pixels.
        let xc = vDSP.add(-128, x), yc = vDSP.add(-128, y)
        let m1 = blur(xc, width: width, height: height)
        let m2 = blur(yc, width: width, height: height)
        let ex2 = blur(vDSP.square(xc), width: width, height: height)
        let ey2 = blur(vDSP.square(yc), width: width, height: height)
        let exy = blur(vDSP.multiply(xc, yc), width: width, height: height)
        let s1 = vDSP.subtract(ex2, vDSP.square(m1)), s2 = vDSP.subtract(ey2, vDSP.square(m2))
        let s12 = vDSP.subtract(exy, vDSP.multiply(m1, m2))
        let mu1 = vDSP.add(128, m1), mu2 = vDSP.add(128, m2)
        let mu1sq = vDSP.square(mu1), mu2sq = vDSP.square(mu2), mu12 = vDSP.multiply(mu1, mu2)
        let num = vDSP.multiply(vDSP.add(c1, vDSP.multiply(2, mu12)), vDSP.add(c2, vDSP.multiply(2, s12)))
        let den = vDSP.multiply(vDSP.add(c1, vDSP.add(mu1sq, mu2sq)), vDSP.add(c2, vDSP.add(s1, s2)))
        let full = vDSP.divide(num, den)
        let (map, w, h) = valid(full, width: width, height: height)
        return SSIMResult(mean: Double(vDSP.mean(map)), map: map, mapWidth: w, mapHeight: h)
    }

    /// SSIM of two equally sized images. `downsample` > 1 block-averages luma first.
    static func ssim(_ a: RGBAImage, _ b: RGBAImage, downsample f: Int = 1) -> SSIMResult {
        precondition(a.width == b.width && a.height == b.height, "image size mismatch")
        let (x, w, h) = downsample(luma(a), width: a.width, height: a.height, by: f)
        let (y, _, _) = downsample(luma(b), width: b.width, height: b.height, by: f)
        return ssim(lumaA: x, lumaB: y, width: w, height: h)
    }

    /// Wang's recommended downsampling factor for an image of this size.
    static func autoDownsample(width: Int, height: Int) -> Int {
        max(1, Int((Double(min(width, height)) / 256).rounded()))
    }

    /// PSNR over R, G and B (alpha ignored), peak 255, dB. `+infinity` when identical.
    static func psnr(_ a: RGBAImage, _ b: RGBAImage) -> Double {
        precondition(a.width == b.width && a.height == b.height, "image size mismatch")
        let n = a.width * a.height
        var sse: Double = 0
        for c in 0..<3 {
            var fa = [Float](repeating: 0, count: n), fb = fa
            a.pixels.withUnsafeBufferPointer { vDSP_vfltu8($0.baseAddress! + c, 4, &fa, 1, vDSP_Length(n)) }
            b.pixels.withUnsafeBufferPointer { vDSP_vfltu8($0.baseAddress! + c, 4, &fb, 1, vDSP_Length(n)) }
            sse += Double(vDSP.distanceSquared(fa, fb))
        }
        let mse = sse / Double(3 * n)
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    /// |a − b| per channel × `gain`, opaque, for eyeballing failures.
    static func difference(_ a: RGBAImage, _ b: RGBAImage, gain: Int = 4) -> RGBAImage {
        var out = [UInt8](repeating: 255, count: a.pixels.count)
        for i in stride(from: 0, to: out.count, by: 4) {
            for c in 0..<3 {
                let d = abs(Int(a.pixels[i + c]) - Int(b.pixels[i + c])) * gain
                out[i + c] = UInt8(min(255, d))
            }
        }
        return RGBAImage(width: a.width, height: a.height, pixels: out)
    }

    /// SSIM map as a grey image: white = 1 (equal), black ≤ 0.
    static func mapImage(_ r: SSIMResult) -> RGBAImage {
        var out = [UInt8](repeating: 255, count: r.map.count * 4)
        for (i, v) in r.map.enumerated() {
            let g = UInt8(max(0, min(255, (v * 255).rounded())))
            out[4 * i] = g; out[4 * i + 1] = g; out[4 * i + 2] = g
        }
        return RGBAImage(width: r.mapWidth, height: r.mapHeight, pixels: out)
    }
}
