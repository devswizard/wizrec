// The Metal tone mapper matches the CPU reference (`ToneMapper.convert`) within its documented
// tolerance: max |Δ| ≤ 1 code per channel, ≥ 99.9 % of channel values identical.

import CFFmpeg
import CoreVideo
import Foundation
import Testing
@testable import MediaEngine

/// Deterministic pseudo-random bi-planar YCbCr pictures for parity tests.
enum HDRPicture {
    /// IOSurface-backed `format` buffer of `w`×`h` filled from a fixed-seed generator, with a
    /// smooth gradient region (left half) and noise (right half) to cover edges and extremes.
    static func make(_ format: OSType, _ w: Int, _ h: Int, seed: UInt64 = 1) throws -> CVPixelBuffer {
        var buf: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
                                      kCVPixelBufferMetalCompatibilityKey: true]
        let rc = CVPixelBufferCreate(nil, w, h, format, attrs as CFDictionary, &buf)
        guard rc == kCVReturnSuccess, let b = buf else { throw MediaError.decodeFailed("CVPixelBufferCreate \(rc)") }
        let ten = (ToneMapper.layout(format)?.depth ?? 8) > 8
        var state = seed
        func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        CVPixelBufferLockBaseAddress(b, [])
        defer { CVPixelBufferUnlockBaseAddress(b, []) }
        for plane in 0..<2 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(b, plane) else { continue }
            let rb = CVPixelBufferGetBytesPerRowOfPlane(b, plane), ph = CVPixelBufferGetHeightOfPlane(b, plane)
            let pw = CVPixelBufferGetWidthOfPlane(b, plane) * (plane == 0 ? 1 : 2)
            for y in 0..<ph {
                for x in 0..<pw {
                    let gradient = x < pw / 2
                    let maxCode = ten ? 1023 : 255
                    let v = gradient ? (plane == 0 ? (x * maxCode) / max(pw / 2, 1) : (maxCode / 2 + (y * 7 + x) % 64 - 32))
                        : Int(next() % UInt64(maxCode + 1))
                    if ten {
                        (base + y * rb).assumingMemoryBound(to: UInt16.self)[x] = UInt16(min(max(v, 0), 1023)) << 6
                    } else {
                        (base + y * rb).assumingMemoryBound(to: UInt8.self)[x] = UInt8(min(max(v, 0), 255))
                    }
                }
            }
        }
        return b
    }

    /// (max |Δ|, fraction of identical channel values) between two BGRA buffers (B, G, R only).
    static func compare(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> (maxDiff: Int, exact: Double) {
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        guard let pa = CVPixelBufferGetBaseAddress(a), let pb = CVPixelBufferGetBaseAddress(b) else { return (255, 0) }
        let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
        let ra = CVPixelBufferGetBytesPerRow(a), rbb = CVPixelBufferGetBytesPerRow(b)
        var maxDiff = 0, same = 0
        for y in 0..<h {
            let rowA = (pa + y * ra).assumingMemoryBound(to: UInt8.self)
            let rowB = (pb + y * rbb).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                for c in 0..<4 {
                    let d = abs(Int(rowA[4 * x + c]) - Int(rowB[4 * x + c]))
                    if c == 3 { maxDiff = max(maxDiff, d == 0 ? 0 : 255); continue } // alpha must be 255 on both
                    maxDiff = max(maxDiff, d)
                    if d == 0 { same += 1 }
                }
            }
        }
        return (maxDiff, Double(same) / Double(w * h * 3))
    }
}

@Suite(.enabled(if: MetalToneMapper.shared != nil, "no Metal device"))
struct ToneMapMetalTests {
    struct Case: Sendable, CustomStringConvertible {
        let format: OSType, name: String, transfer: HDRTransfer, primaries: AVColorPrimaries, fullRange: Bool
        var description: String { "\(name) \(transfer) \(fullRange ? "full" : "video")" }
    }

    static let cases: [Case] = {
        var c: [Case] = []
        let formats: [(OSType, OSType, String)] = [
            (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, "P010"),
            (kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, "P210"),
            (kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange, "P410"),
            (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, "NV12"),
        ]
        for (video, full, name) in formats {
            for t in [HDRTransfer.pq, .hlg] {
                c.append(Case(format: video, name: name, transfer: t, primaries: AVCOL_PRI_BT2020, fullRange: false))
            }
            c.append(Case(format: full, name: name, transfer: .pq, primaries: AVCOL_PRI_BT2020, fullRange: true))
        }
        c.append(Case(format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, name: "P010 P3", transfer: .hlg,
                      primaries: AVCOL_PRI_SMPTE432, fullRange: false))
        return c
    }()

    @Test(arguments: cases)
    func matchesCPUReference(_ k: Case) throws {
        // Odd sizes exercise the clamped last chroma column / row.
        let (w, h) = (k.name.hasPrefix("P4") ? 317 : 318, 181)
        let src = try HDRPicture.make(k.format, w, h)
        let cpu = ToneMapper(transfer: k.transfer, colorSpace: AVCOL_SPC_BT2020_NCL, primaries: k.primaries,
                             fullRange: k.fullRange)
        let gpu = try #require(MetalToneMapper(cpu))
        let pool = try BGRAPool(width: w, height: h)
        let a = try pool.make(), b = try pool.make()
        try cpu.convert(src, into: a)
        try gpu.convert(src, into: b)
        let (maxDiff, exact) = HDRPicture.compare(a, b)
        print("TONEMAP parity \(k): max |Δ| \(maxDiff), exact \(String(format: "%.5f", exact * 100)) %")
        #expect(maxDiff <= 1)
        #expect(exact >= 0.999)
    }

    /// A large 4:4:4 picture (every 10-bit luma code in the gradient half, ~0.5 M random
    /// YCbCr triples in the other) for both transfers.
    @Test(arguments: [HDRTransfer.pq, .hlg])
    func largeSweep(_ t: HDRTransfer) throws {
        let (w, h) = (2048, 512)
        let src = try HDRPicture.make(kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, w, h, seed: 7)
        let cpu = ToneMapper(transfer: t, colorSpace: AVCOL_SPC_BT2020_NCL, primaries: AVCOL_PRI_BT2020, fullRange: false)
        let gpu = try #require(MetalToneMapper(cpu))
        let pool = try BGRAPool(width: w, height: h)
        let a = try pool.make(), b = try pool.make()
        try cpu.convert(src, into: a)
        try gpu.convert(src, into: b)
        let (maxDiff, exact) = HDRPicture.compare(a, b)
        print("TONEMAP sweep \(t): max |Δ| \(maxDiff), exact \(String(format: "%.5f", exact * 100)) %")
        #expect(maxDiff <= 1)
        #expect(exact >= 0.999)
    }

    @Test func rejectsNonIOSurfaceAndMismatchedBuffers() throws {
        let cpu = ToneMapper(transfer: .pq, colorSpace: AVCOL_SPC_BT2020_NCL, primaries: AVCOL_PRI_BT2020, fullRange: false)
        let gpu = try #require(MetalToneMapper(cpu))
        let src = try HDRPicture.make(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 64, 32)
        let small = try BGRAPool(width: 32, height: 32).make()
        #expect(throws: MediaError.self) { try gpu.convert(src, into: small) }
        var plain: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_32BGRA, nil, &plain)
        let p = try #require(plain)
        #expect(throws: MediaError.self) { try gpu.convert(src, into: p) }
    }
}

/// GPU tone-mapping throughput at 4K (`WIZREC_PERF=1`; numbers only, budget 16.7 ms for 60 fps).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WIZREC_PERF"] == "1" && MetalToneMapper.shared != nil,
                "set WIZREC_PERF=1"), .serialized)
struct ToneMapMetalPerfTests {
    @Test func p010At4K() throws {
        let (w, h) = (3840, 2160)
        let src = try HDRPicture.make(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, w, h)
        let pool = try BGRAPool(width: w, height: h)
        for t in [HDRTransfer.pq, .hlg] {
            let cpu = ToneMapper(transfer: t, colorSpace: AVCOL_SPC_BT2020_NCL, primaries: AVCOL_PRI_BT2020, fullRange: false)
            let gpu = try #require(MetalToneMapper(cpu))
            let dst = try pool.make()
            try gpu.convert(src, into: dst) // warm
            let n = 30, t0 = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<n { try gpu.convert(src, into: dst) }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / Double(n)
            let c0 = DispatchTime.now().uptimeNanoseconds
            try cpu.convert(src, into: dst)
            let cms = Double(DispatchTime.now().uptimeNanoseconds - c0) / 1e6
            print("PERF GPU tone map \(t) \(w)x\(h): \(String(format: "%.2f", ms)) ms/frame (CPU all cores \(String(format: "%.2f", cms)) ms)")
            #expect(ms < 16.7)
        }
    }
}
