// The vectorised SW-lane staging copy equals the scalar reference byte for byte.

import Foundation
import Testing
@testable import MediaEngine

/// One synthetic planar picture plus two destination buffers (vectorised, reference).
private final class StagingFixture {
    let w: Int, h: Int, cw: Int, ch: Int, depth: Int
    let bps: Int
    var src: [[UInt8]] // y, cb, cr
    let srcRowBytes: [Int]
    var dstVec: [[UInt8]], dstRef: [[UInt8]] // luma, chroma
    let dstRowBytes: [Int]

    init(width: Int, height: Int, log2cw: Int, log2ch: Int, depth: Int, seed: UInt64) {
        w = width; h = height; self.depth = depth
        cw = (width + (1 << log2cw) - 1) >> log2cw
        ch = (height + (1 << log2ch) - 1) >> log2ch
        bps = depth > 8 ? 2 : 1
        var rng = seed
        func next() -> UInt64 { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return rng >> 33 }
        // Odd paddings so rows are not 16-byte aligned.
        let bps = depth > 8 ? 2 : 1, cw = self.cw, ch = self.ch
        let srb = [width * bps + 6, cw * bps + 10, cw * bps + 2]
        srcRowBytes = srb
        let rows = [height, ch, ch]
        let mask = UInt16((1 << depth) - 1)
        src = (0..<3).map { i in
            var a = [UInt8](repeating: 0, count: srb[i] * rows[i] + 16)
            if depth > 8 {
                for k in stride(from: 0, to: a.count - 1, by: 2) {
                    let v = UInt16(truncatingIfNeeded: next()) & mask
                    a[k] = UInt8(v & 0xFF); a[k + 1] = UInt8(v >> 8)
                }
            } else {
                for k in 0..<a.count { a[k] = UInt8(truncatingIfNeeded: next()) }
            }
            return a
        }
        dstRowBytes = [w * bps + 64, 2 * cw * bps + 32]
        let garbage: (Int) -> [UInt8] = { [UInt8](repeating: 0xAB, count: $0) }
        dstVec = [garbage(dstRowBytes[0] * h), garbage(dstRowBytes[1] * ch)]
        dstRef = dstVec
    }

    /// Runs the copy `iterations` times; returns the mean wall time of one copy (ms).
    @discardableResult
    func run(vectorised: Bool, iterations: Int = 1) -> Double {
        var ms = 0.0
        let (sr, dr, w, h, cw, ch, depth) = (srcRowBytes, dstRowBytes, self.w, self.h, self.cw, self.ch, self.depth)
        var d0 = vectorised ? dstVec[0] : dstRef[0], d1 = vectorised ? dstVec[1] : dstRef[1]
        let s0 = src[0], s1 = src[1], s2 = src[2]
        s0.withUnsafeBytes { y in s1.withUnsafeBytes { cb in s2.withUnsafeBytes { cr in
            d0.withUnsafeMutableBytes { dl in d1.withUnsafeMutableBytes { dc in
                guard let yb = y.baseAddress, let cbb = cb.baseAddress, let crb = cr.baseAddress,
                      let dlb = dl.baseAddress, let dcb = dc.baseAddress else { return }
                let p = StagingCopy.Planes(y: yb, yRowBytes: sr[0], cb: cbb, cbRowBytes: sr[1],
                                           cr: crb, crRowBytes: sr[2], width: w, height: h,
                                           chromaWidth: cw, chromaHeight: ch, depth: depth,
                                           luma: dlb, lumaRowBytes: dr[0], chroma: dcb, chromaRowBytes: dr[1])
                let t0 = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<iterations {
                    if vectorised { StagingCopy.copy(p) } else { StagingCopy.copyReference(p) }
                }
                ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / Double(iterations)
            } }
        } } }
        if vectorised { dstVec = [d0, d1] } else { dstRef = [d0, d1] }
        return ms
    }
}

struct StagingCopyTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let w: Int, h: Int, cw: Int, ch: Int, depth: Int
        var testDescription: String { "\(w)x\(h) \(cw == 0 ? "444" : ch == 0 ? "422" : "420") \(depth)-bit" }
    }

    static let cases: [Case] = [
        Case(w: 3840, h: 2160, cw: 1, ch: 1, depth: 10),
        Case(w: 2704, h: 1520, cw: 1, ch: 1, depth: 10),
        Case(w: 2704, h: 1520, cw: 1, ch: 0, depth: 10),
        Case(w: 1921, h: 1081, cw: 1, ch: 1, depth: 10),
        Case(w: 333, h: 77, cw: 0, ch: 0, depth: 10),
        Case(w: 3840, h: 2160, cw: 1, ch: 1, depth: 8),
        Case(w: 17, h: 9, cw: 1, ch: 1, depth: 8),
        Case(w: 1279, h: 721, cw: 1, ch: 0, depth: 8),
        Case(w: 7, h: 3, cw: 1, ch: 1, depth: 10),
    ]

    @Test(arguments: cases)
    func vectorisedEqualsReference(_ c: Case) {
        let f = StagingFixture(width: c.w, height: c.h, log2cw: c.cw, log2ch: c.ch, depth: c.depth, seed: UInt64(c.w * 31 + c.h))
        f.run(vectorised: false)
        f.run(vectorised: true)
        #expect(f.dstVec[0] == f.dstRef[0], "luma differs")
        #expect(f.dstVec[1] == f.dstRef[1], "chroma differs")
    }
}

/// Staging-copy throughput, vectorised vs scalar (`WIZREC_PERF=1`; numbers only, no thresholds
/// beyond "not slower").
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WIZREC_PERF"] == "1", "set WIZREC_PERF=1"), .serialized)
struct StagingCopyPerfTests {
    @Test(arguments: [(2704, 1520), (3840, 2160)])
    func tenBitThroughput(_ size: (Int, Int)) {
        let f = StagingFixture(width: size.0, height: size.1, log2cw: 1, log2ch: 1, depth: 10, seed: 7)
        f.run(vectorised: false); f.run(vectorised: true) // warm
        let ref = f.run(vectorised: false, iterations: 10), vec = f.run(vectorised: true, iterations: 30)
        print("PERF staging \(size.0)x\(size.1) 10-bit 4:2:0: scalar \(String(format: "%.2f", ref)) ms, vectorised \(String(format: "%.2f", vec)) ms (\(String(format: "%.1f", ref / vec))×)")
        #expect(vec <= ref)
    }
}
