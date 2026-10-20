// HDR (PQ / HLG) to SDR BT.709 tone mapping of YCbCr buffers into BGRA, on the CPU.
//
// Both decoder lanes hand the same bi-planar YCbCr bytes to `ToneMapper.convert`, and the
// conversion is plain deterministic Swift arithmetic, so HDR frames stay byte-identical across
// the VideoToolbox and software lanes (VideoToolbox's own HDR handling is not used).

import CFFmpeg
import CoreVideo
import Foundation
import os

/// HDR transfer characteristic of a stream, from its stream-level colour tags.
enum HDRTransfer: Sendable, Equatable {
    /// SMPTE ST 2084 (HDR10 / Dolby Vision base layer): absolute luminance up to 10 000 cd/m².
    case pq
    /// ARIB STD-B67 / BT.2100 HLG: relative, scene-referred.
    case hlg

    /// The stream's HDR transfer, or nil for SDR streams.
    static func of(_ trc: AVColorTransferCharacteristic) -> HDRTransfer? {
        switch trc {
        case AVCOL_TRC_SMPTE2084: return .pq
        case AVCOL_TRC_ARIB_STD_B67: return .hlg
        default: return nil
        }
    }
}

/// Converts HDR YCbCr pictures to SDR BT.709 BGRA bytes (8 bits per channel, alpha 255).
///
/// The tone-map curve is a WizRec choice [WizRec], not a reproduction of any other product:
///
/// 1. YCbCr → non-linear R'G'B' with the stream's matrix (BT.2020 NCL when untagged), from the
///    stream's range (limited: Y 64–940, C 64–960 at 10 bits; full: 0–1023). Chroma is
///    upsampled linearly: horizontally co-sited (left), vertically centred (4:2:0).
/// 2. Linearise, in units where 1.0 = HDR reference white, 203 cd/m² (ITU-R BT.2408):
///    - PQ: ST 2084 EOTF, cd/m² ÷ 203.
///    - HLG: BT.2100 inverse OETF, then the HLG OOTF for a 1000 cd/m² display
///      (system gamma 1.2, applied on BT.2020 luminance), ÷ 203. Signal 0.75 → 1.0.
/// 3. Gamut-map BT.2020 (or Display P3) primaries to BT.709 in linear light; negative
///    components clip to 0.
/// 4. Tone-map on m = max(R, G, B), scaling all three channels by f(m)/m (hue-preserving):
///    f(m) = m for m ≤ 0.8; above, f(m) = 0.8 + 0.2 · (1 − e^(−(m − 0.8)/0.2)), a soft
///    shoulder with continuous slope that approaches 1.0 (SDR peak) asymptotically.
///    Example: 203 cd/m² → 0.926, 1000 cd/m² → ≈1.0.
/// 5. Encode with the BT.709 OETF (V = 4.5L below 0.018, else 1.099·L^0.45 − 0.099), rounded to
///    8 bits, as SDR BT.709 video is encoded.
final class ToneMapper: Sendable {
    let transfer: HDRTransfer
    /// Luma coefficients of the YCbCr matrix.
    let kr: Float, kb: Float
    /// Linear source-primaries → BT.709 matrix, by rows.
    let gamut: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
    /// Samples are full range.
    let fullRange: Bool
    /// Non-linear signal [0, 1] → linear (PQ: relative to 203 cd/m²; HLG: scene light [0, 1]),
    /// `eotfSize + 1` entries, nearest entry (16-bit signal resolution, finer than any source).
    let eotf: [Float]
    /// HLG OOTF gain Lw · Ys^(γ−1) ÷ 203 over Ys ∈ [0, 1], `ootfSize + 1` entries, interpolated.
    let ootf: [Float]
    static let ootfSize = 4096
    /// Linear [0, 1] → 8-bit BT.709 OETF code, `encodeSize` entries.
    let encode: [UInt8]
    static let eotfSize = 65536
    static let encodeSize = 65536

    /// SDR reference white in cd/m² (BT.2408): linear 1.0.
    static let referenceWhite: Float = 203
    /// Nominal HLG display peak (cd/m²) for the OOTF.
    static let hlgPeak: Float = 1000
    /// Start of the shoulder of the tone curve (linear, 1.0 = reference white).
    static let knee: Float = 0.8

    init(transfer: HDRTransfer, colorSpace: AVColorSpace, primaries: AVColorPrimaries, fullRange: Bool) {
        self.transfer = transfer
        self.fullRange = fullRange
        switch colorSpace {
        case AVCOL_SPC_BT709: (kr, kb) = (0.2126, 0.0722)
        case AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M: (kr, kb) = (0.299, 0.114)
        default: (kr, kb) = (0.2627, 0.0593) // BT.2020 (tagged or assumed for HDR)
        }
        switch primaries {
        case AVCOL_PRI_BT709: gamut = ([1, 0, 0], [0, 1, 0], [0, 0, 1])
        case AVCOL_PRI_SMPTE432:
            gamut = ([1.224940, -0.224940, 0], [-0.042057, 1.042057, 0], [-0.019638, -0.078636, 1.098274])
        default:
            gamut = ([1.660491, -0.587641, -0.072850], [-0.124551, 1.132900, -0.008349], [-0.018151, -0.100579, 1.118730])
        }
        eotf = (0...Self.eotfSize).map { Self.linearise(Float($0) / Float(Self.eotfSize), transfer) }
        ootf = (0...Self.ootfSize).map { Self.hlgGain(Float($0) / Float(Self.ootfSize)) }
        encode = (0..<Self.encodeSize).map { Self.oetf709(Float($0) / Float(Self.encodeSize - 1)) }
    }

    /// Mapper for a stream, or nil when its transfer is SDR.
    convenience init?(par: UnsafeMutablePointer<AVCodecParameters>) {
        guard let t = HDRTransfer.of(par.pointee.color_trc) else { return nil }
        self.init(transfer: t, colorSpace: par.pointee.color_space, primaries: par.pointee.color_primaries,
                  fullRange: FrameConverter.isFullRange(par))
    }

    // MARK: - Curves

    /// PQ: cd/m² ÷ 203. HLG: scene-linear light [0, 1] (OOTF applied per pixel).
    static func linearise(_ v: Float, _ t: HDRTransfer) -> Float {
        let e = min(max(v, 0), 1)
        switch t {
        case .pq:
            let m1: Float = 0.1593017578125, m2: Float = 78.84375
            let c1: Float = 0.8359375, c2: Float = 18.8515625, c3: Float = 18.6875
            let p = powf(e, 1 / m2)
            return powf(max(p - c1, 0) / (c2 - c3 * p), 1 / m1) * 10000 / referenceWhite
        case .hlg:
            let a: Float = 0.17883277, b: Float = 0.28466892, c: Float = 0.55991073
            return e <= 0.5 ? e * e / 3 : (expf((e - c) / a) + b) / 12
        }
    }

    /// HLG OOTF gain for scene luminance `ys` [0, 1]: Lw · Ys^(γ−1) ÷ 203, γ = 1.2, Lw = 1000.
    static func hlgGain(_ ys: Float) -> Float {
        ys > 0 ? hlgPeak * powf(ys, 0.2) / referenceWhite : 0
    }

    /// The tone curve f(m) on linear light relative to reference white; result in [0, 1).
    static func curve(_ m: Float) -> Float {
        guard m > knee else { return m }
        return knee + (1 - knee) * (1 - expf(-(m - knee) / (1 - knee)))
    }

    /// BT.709 OETF of linear [0, 1] as an 8-bit code.
    static func oetf709(_ l: Float) -> UInt8 {
        let v = l < 0.018 ? 4.5 * l : 1.099 * powf(l, 0.45) - 0.099
        return UInt8(min(max(v * 255 + 0.5, 0), 255))
    }

    // MARK: - Per pixel

    /// Tone-maps one pixel given normalised Y' [0, 1] and Cb/Cr [−0.5, 0.5]; returns (r, g, b).
    @inline(__always)
    func map(y: Float, cb: Float, cr: Float, eotf e: UnsafePointer<Float>, ootf o: UnsafePointer<Float>,
             encode enc: UnsafePointer<UInt8>) -> (UInt8, UInt8, UInt8) {
        let kg = 1 - kr - kb
        let r1 = y + 2 * (1 - kr) * cr
        let b1 = y + 2 * (1 - kb) * cb
        let g1 = (y - kr * r1 - kb * b1) / kg
        @inline(__always) func lin(_ v: Float) -> Float {
            e[Int(min(max(v, 0), 1) * Float(Self.eotfSize) + 0.5)]
        }
        var r = lin(r1), g = lin(g1), b = lin(b1)
        if transfer == .hlg {
            // OOTF on source (BT.2020) luminance: Fd = Lw · Ys^(γ−1) · E, γ = 1.2.
            let ys = 0.2627 * r + 0.6780 * g + 0.0593 * b
            let x = min(max(ys, 0), 1) * Float(Self.ootfSize)
            let i = min(Int(x), Self.ootfSize - 1)
            let s = o[i] + (o[i + 1] - o[i]) * (x - Float(i))
            r *= s; g *= s; b *= s
        }
        let (m0, m1, m2) = gamut
        var R = max(m0.x * r + m0.y * g + m0.z * b, 0)
        var G = max(m1.x * r + m1.y * g + m1.z * b, 0)
        var B = max(m2.x * r + m2.y * g + m2.z * b, 0)
        let peak = max(R, max(G, B))
        if peak > Self.knee {
            let s = Self.curve(peak) / peak
            R *= s; G *= s; B *= s
        }
        @inline(__always) func out(_ v: Float) -> UInt8 {
            enc[min(Int(v * Float(Self.encodeSize - 1) + 0.5), Self.encodeSize - 1)]
        }
        return (out(R), out(G), out(B))
    }

    // MARK: - Buffers

    /// Bit depth, chroma subsampling (log2 w, log2 h) of a bi-planar YCbCr format.
    static func layout(_ f: OSType) -> (depth: Int, cw: Int, ch: Int)? {
        switch f {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return (8, 1, 1)
        case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8BiPlanarFullRange: return (8, 1, 0)
        case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange: return (8, 0, 0)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: return (10, 1, 1)
        case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange: return (10, 1, 0)
        case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange: return (10, 0, 0)
        default: return nil
        }
    }

    /// Tone-maps a bi-planar YCbCr buffer (8-bit, or 10-bit in the 16-bit MSBs) into a BGRA
    /// buffer of the same size. Rows are processed in `bands` parallel bands (default: 2 per
    /// core); the output does not depend on it.
    func convert(_ src: CVPixelBuffer, into dst: CVPixelBuffer, bands: Int? = nil) throws {
        guard let lay = Self.layout(CVPixelBufferGetPixelFormatType(src)) else {
            throw MediaError.decodeFailed("tone mapping: unsupported pixel format")
        }
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        guard CVPixelBufferGetWidth(dst) == w, CVPixelBufferGetHeight(dst) == h else {
            throw MediaError.decodeFailed("tone mapping: size mismatch")
        }
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(src, 0), let cBase = CVPixelBufferGetBaseAddressOfPlane(src, 1),
              let oBase = CVPixelBufferGetBaseAddress(dst) else {
            throw MediaError.decodeFailed("tone mapping: buffer has no memory")
        }
        let ry = CVPixelBufferGetBytesPerRowOfPlane(src, 0), rc = CVPixelBufferGetBytesPerRowOfPlane(src, 1)
        let ro = CVPixelBufferGetBytesPerRow(dst)
        let cwid = CVPixelBufferGetWidthOfPlane(src, 1), chgt = CVPixelBufferGetHeightOfPlane(src, 1)
        guard cwid > 0, chgt > 0 else { throw MediaError.decodeFailed("tone mapping: empty chroma plane") }

        // Sample codes → normalised Y' [0, 1] and C [−0.5, 0.5].
        let ten = lay.depth > 8
        let maxCode: Float = ten ? 1023 : 255, unit: Float = ten ? 4 : 1 // unit: 8-bit step in codes
        let yOff: Float = fullRange ? 0 : 16 * unit, yScale: Float = fullRange ? 1 / maxCode : 1 / (219 * unit)
        let cOff: Float = 128 * unit, cScale: Float = fullRange ? 1 / maxCode : 1 / (224 * unit)
        let yb = UInt(bitPattern: yBase), cb = UInt(bitPattern: cBase), ob = UInt(bitPattern: oBase)

        let bands = max(1, min(h, bands ?? ProcessInfo.processInfo.activeProcessorCount * 2))
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            eotf.withUnsafeBufferPointer { e in ootf.withUnsafeBufferPointer { o in
                encode.withUnsafeBufferPointer { enc in
                    guard let ep = e.baseAddress, let op0 = o.baseAddress, let encp = enc.baseAddress else { return }
                    let y0 = band * h / bands, y1 = (band + 1) * h / bands
                    var cbRow = [Float](repeating: 0, count: cwid), crRow = [Float](repeating: 0, count: cwid)
                    for y in y0..<y1 {
                        // Code of a chroma sample.
                        @inline(__always) func chroma(_ row: Int, _ x: Int, _ k: Int) -> Float {
                            // Plane base addresses are non-null (checked above).
                            guard let p = UnsafeRawPointer(bitPattern: cb + UInt(row * rc)) else { return 0 }
                            return ten ? Float(p.load(fromByteOffset: (2 * x + k) * 2, as: UInt16.self) >> 6)
                                : Float(p.load(fromByteOffset: 2 * x + k, as: UInt8.self))
                        }
                        // Vertical chroma interpolation for this luma row.
                        let cy: Int, cy2: Int, wv: Float
                        if lay.ch == 1 {
                            cy = min(y >> 1, chgt - 1)
                            cy2 = (y & 1) == 0 ? max(cy - 1, 0) : min(cy + 1, chgt - 1)
                            wv = 0.25
                        } else {
                            cy = min(y, chgt - 1); cy2 = cy; wv = 0
                        }
                        for x in 0..<cwid {
                            let u = chroma(cy, x, 0) * (1 - wv) + chroma(cy2, x, 0) * wv
                            let v = chroma(cy, x, 1) * (1 - wv) + chroma(cy2, x, 1) * wv
                            cbRow[x] = (u - cOff) * cScale
                            crRow[x] = (v - cOff) * cScale
                        }
                        guard let yp = UnsafeRawPointer(bitPattern: yb + UInt(y * ry)),
                              let op = UnsafeMutablePointer<UInt8>(bitPattern: ob + UInt(y * ro)) else { continue }
                        for x in 0..<w {
                            let code = ten ? Float(yp.load(fromByteOffset: 2 * x, as: UInt16.self) >> 6)
                                : Float(yp.load(fromByteOffset: x, as: UInt8.self))
                            let yn = (code - yOff) * yScale
                            let u: Float, v: Float
                            if lay.cw == 1 {
                                let i = min(x >> 1, cwid - 1)
                                if (x & 1) == 0 {
                                    u = cbRow[i]; v = crRow[i]
                                } else {
                                    let j = min(i + 1, cwid - 1)
                                    u = (cbRow[i] + cbRow[j]) * 0.5; v = (crRow[i] + crRow[j]) * 0.5
                                }
                            } else {
                                let i = min(x, cwid - 1)
                                u = cbRow[i]; v = crRow[i]
                            }
                            let (r, g, b) = map(y: yn, cb: u, cr: v, eotf: ep, ootf: op0, encode: encp)
                            op[4 * x] = b; op[4 * x + 1] = g; op[4 * x + 2] = r; op[4 * x + 3] = 255
                        }
                    }
                }
            } }
        }
    }
}

/// Thread-safe tally of tone-mapped frames for one `MediaPool` (its decoders run on many queues).
final class ToneMapCounter: Sendable {
    enum Path { case gpu, cpu, cpuFallback }
    private let state = OSAllocatedUnfairLock(initialState: ToneMapStats())

    func count(_ path: Path) {
        state.withLock {
            switch path {
            case .gpu: $0.gpuFrames += 1
            case .cpu: $0.cpuFrames += 1
            case .cpuFallback: $0.cpuFallbackFrames += 1
            }
        }
    }

    var stats: ToneMapStats { state.withLock { $0 } }
}
