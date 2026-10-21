import Accelerate
import CoreGraphics
import CoreVideo
import Foundation

/// 8-bit straight RGBA pixels, row-major, top row first. Values are taken as
/// stored (no colour management), so two images compare on their encoded values.
public struct RGBAImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// `width × height × 4` bytes: R, G, B, A.
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4, "pixel count mismatch")
        self.width = width; self.height = height; self.pixels = pixels
    }

    /// Same size and bytes. `memcmp` instead of the synthesized element loop, which is slow on
    /// megapixel arrays in debug test builds (QA11-2).
    public static func == (a: RGBAImage, b: RGBAImage) -> Bool {
        guard a.width == b.width, a.height == b.height, a.pixels.count == b.pixels.count else { return false }
        return a.pixels.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Bool in
            b.pixels.withUnsafeBytes { (q: UnsafeRawBufferPointer) -> Bool in
                guard let x = p.baseAddress, let y = q.baseAddress else { return p.count == q.count }
                return memcmp(x, y, p.count) == 0
            }
        }
    }

    /// Solid colour image.
    public init(width: Int, height: Int, fill: (UInt8, UInt8, UInt8)) {
        var p = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) { p[4 * i] = fill.0; p[4 * i + 1] = fill.1; p[4 * i + 2] = fill.2 }
        self.init(width: width, height: height, pixels: p)
    }

    /// Reads `image`. 8-bit 32-bpp images are read byte-exact; anything else is drawn into sRGB.
    public init(_ image: CGImage) {
        let w = image.width, h = image.height
        if image.bitsPerComponent == 8, image.bitsPerPixel == 32,
           let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data) {
            let alpha = image.alphaInfo
            let little = image.bitmapInfo.contains(.byteOrder32Little)
            let alphaFirst = alpha == .first || alpha == .premultipliedFirst || alpha == .noneSkipFirst
            let premul = alpha == .premultipliedFirst || alpha == .premultipliedLast
            let hasAlpha = !(alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast)
            // Byte offsets of R, G, B, A within each pixel as stored in memory.
            let (ri, gi, bi, ai): (Int, Int, Int, Int)
            switch (little, alphaFirst) {
            case (false, false): (ri, gi, bi, ai) = (0, 1, 2, 3)  // RGBA
            case (false, true): (ri, gi, bi, ai) = (1, 2, 3, 0)   // ARGB
            case (true, true): (ri, gi, bi, ai) = (2, 1, 0, 3)    // BGRA
            case (true, false): (ri, gi, bi, ai) = (3, 2, 1, 0)   // ABGR
            }
            var out = [UInt8](repeating: 255, count: w * h * 4)
            let bpr = image.bytesPerRow
            // Fast path (QA11-2): vImage reorders the bytes; per-pixel Swift loops over 1080p frames
            // dominated golden tests in debug builds. Same bytes as the loop below.
            if Self.permute(UnsafeRawPointer(base), bytesPerRow: bpr, width: w, height: h,
                            map: [UInt8(ri), UInt8(gi), UInt8(bi), UInt8(ai)], opaque: !hasAlpha, into: &out) {
                if premul { Self.unpremultiplyPartialAlpha(&out) }
                self.init(width: w, height: h, pixels: out)
                return
            }
            for y in 0..<h {
                let row = base + y * bpr
                for x in 0..<w {
                    let p = row + 4 * x
                    let o = 4 * (y * w + x)
                    let a = hasAlpha ? p[ai] : 255
                    var r = p[ri], g = p[gi], b = p[bi]
                    if premul, a > 0, a < 255 {
                        r = Self.unpremultiplied(r, alpha: a)
                        g = Self.unpremultiplied(g, alpha: a)
                        b = Self.unpremultiplied(b, alpha: a)
                    }
                    out[o] = r; out[o + 1] = g; out[o + 2] = b; out[o + 3] = a
                }
            }
            self.init(width: w, height: h, pixels: out)
            return
        }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { buf in
            if let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        self.init(width: w, height: h, pixels: out)
    }

    /// Straight colour from a premultiplied channel `c` with alpha `alpha` (1…254), rounded.
    /// Kept out of the pixel loop: inline, Swift 6.3 took ~280 ms to type-check each line.
    static func unpremultiplied(_ c: UInt8, alpha: UInt8) -> UInt8 {
        let a: Int = Int(alpha)
        let v: Int = (Int(c) * 255 + a / 2) / a
        return UInt8(Swift.min(v, 255))
    }

    /// Copies `height` rows of 4-byte pixels at `src` (row stride `bytesPerRow`) into `out`
    /// (tightly packed RGBA), output byte i of each pixel = input byte `map[i]`; `opaque` sets
    /// every alpha to 255. False when vImage refuses (the caller then uses its pixel loop).
    static func permute(_ src: UnsafeRawPointer, bytesPerRow: Int, width w: Int, height h: Int, map: [UInt8],
                        opaque: Bool, into out: inout [UInt8]) -> Bool {
        guard w > 0, h > 0, out.count == w * h * 4 else { return false }
        return out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Bool in
            var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src), height: vImagePixelCount(h),
                                  width: vImagePixelCount(w), rowBytes: bytesPerRow)
            var d = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w),
                                  rowBytes: w * 4)
            guard vImagePermuteChannels_ARGB8888(&s, &d, map, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
                return false
            }
            guard opaque else { return true }
            // copyMask 0x1 = the fourth channel (alpha here).
            return vImageOverwriteChannelsWithScalar_ARGB8888(255, &d, &d, 0x1, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
    }

    /// Un-premultiplies, in place, the pixels of packed RGBA `p` whose alpha is 1…254.
    static func unpremultiplyPartialAlpha(_ p: inout [UInt8]) {
        p.withUnsafeMutableBufferPointer { (b: inout UnsafeMutableBufferPointer<UInt8>) -> Void in
            var o = 0
            while o + 3 < b.count {
                let a = b[o + 3]
                if a > 0, a < 255 {
                    b[o] = unpremultiplied(b[o], alpha: a)
                    b[o + 1] = unpremultiplied(b[o + 1], alpha: a)
                    b[o + 2] = unpremultiplied(b[o + 2], alpha: a)
                }
                o += 4
            }
        }
    }

    /// Copies a `32BGRA` pixel buffer.
    public init?(pixelBuffer pb: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        var out = [UInt8](repeating: 255, count: w * h * 4)
        if Self.permute(UnsafeRawPointer(base), bytesPerRow: bpr, width: w, height: h, map: [2, 1, 0, 3],
                        opaque: false, into: &out) {
            self.init(width: w, height: h, pixels: out)
            return
        }
        for y in 0..<h {
            let row = base + y * bpr
            for x in 0..<w {
                let o = 4 * (y * w + x), p = row + 4 * x
                out[o] = p[2]; out[o + 1] = p[1]; out[o + 2] = p[0]; out[o + 3] = p[3]
            }
        }
        self.init(width: w, height: h, pixels: out)
    }

    /// An sRGB-tagged `CGImage` of these pixels (for PNG output).
    public func cgImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Pixel at (`x`, `y`), top-left origin.
    public func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let o = 4 * (y * width + x)
        return (pixels[o], pixels[o + 1], pixels[o + 2], pixels[o + 3])
    }
}
