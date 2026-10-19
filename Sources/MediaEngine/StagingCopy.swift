// Vectorised copy of planar YCbCr software pictures into bi-planar staging buffers
// (luma plane, then interleaved Cb/Cr; >8-bit samples moved to the 16-bit MSBs, the layout
// VideoToolbox returns). Output is byte-identical to the scalar reference.

import Accelerate
import Foundation

/// Copies one planar YCbCr picture into the two planes of a bi-planar buffer.
enum StagingCopy {
    /// Source planes and destination planes of one copy. Sizes in samples, row strides in bytes.
    // @unchecked: the pointers are only read (source planes) or written in disjoint row bands
    // (destination planes) while the caller keeps both pictures alive and locked.
    struct Planes: @unchecked Sendable {
        var y: UnsafeRawPointer, yRowBytes: Int
        var cb: UnsafeRawPointer, cbRowBytes: Int
        var cr: UnsafeRawPointer, crRowBytes: Int
        /// Luma size and chroma plane size (samples).
        var width: Int, height: Int, chromaWidth: Int, chromaHeight: Int
        /// Bits per sample: 8 (1 byte per sample) or 9–16 (2 bytes, LSB-aligned in the source).
        var depth: Int
        var luma: UnsafeMutableRawPointer, lumaRowBytes: Int
        var chroma: UnsafeMutableRawPointer, chromaRowBytes: Int
    }

    /// Luma bytes below which the copy runs on the calling thread only.
    private static let parallelThreshold = 1 << 20

    /// Vectorised copy: vImage interleave for 8-bit chroma, SIMD shift (and shift-interleave)
    /// for deeper samples, split into row bands across cores for large pictures.
    static func copy(_ p: Planes) {
        let bytes = p.width * p.height * (p.depth > 8 ? 2 : 1)
        let bands = bytes < parallelThreshold ? 1 : min(p.chromaHeight, ProcessInfo.processInfo.activeProcessorCount)
        if bands <= 1 {
            copyRows(p, lumaRows: 0..<p.height, chromaRows: 0..<p.chromaHeight)
            return
        }
        DispatchQueue.concurrentPerform(iterations: bands) { b in
            let c0 = b * p.chromaHeight / bands, c1 = (b + 1) * p.chromaHeight / bands
            // Luma rows that belong to these chroma rows (the last band takes any remainder).
            let ratio = max(1, (p.height + p.chromaHeight - 1) / p.chromaHeight)
            let l0 = min(c0 * ratio, p.height), l1 = b == bands - 1 ? p.height : min(c1 * ratio, p.height)
            copyRows(p, lumaRows: l0..<l1, chromaRows: c0..<c1)
        }
    }

    private static func copyRows(_ p: Planes, lumaRows: Range<Int>, chromaRows: Range<Int>) {
        if p.depth == 8 {
            for y in lumaRows {
                (p.luma + y * p.lumaRowBytes).copyMemory(from: p.y + y * p.yRowBytes, byteCount: p.width)
            }
            guard !chromaRows.isEmpty, p.chromaWidth > 0 else { return }
            let r0 = chromaRows.lowerBound, n = chromaRows.count
            var srcs = [
                vImage_Buffer(data: UnsafeMutableRawPointer(mutating: p.cb + r0 * p.cbRowBytes), height: vImagePixelCount(n),
                              width: vImagePixelCount(p.chromaWidth), rowBytes: p.cbRowBytes),
                vImage_Buffer(data: UnsafeMutableRawPointer(mutating: p.cr + r0 * p.crRowBytes), height: vImagePixelCount(n),
                              width: vImagePixelCount(p.chromaWidth), rowBytes: p.crRowBytes),
            ]
            let d = p.chroma + r0 * p.chromaRowBytes
            var dests: [UnsafeMutableRawPointer?] = [d, d + 1]
            srcs.withUnsafeMutableBufferPointer { sb in
                guard let s0 = sb.baseAddress else { return }
                var ptrs: [UnsafePointer<vImage_Buffer>?] = [UnsafePointer(s0), UnsafePointer(s0 + 1)]
                _ = vImageConvert_PlanarToChunky8(&ptrs, &dests, 2, 2, vImagePixelCount(p.chromaWidth),
                                                  vImagePixelCount(n), p.chromaRowBytes, vImage_Flags(kvImageDoNotTile))
            }
        } else {
            let shift = UInt16(16 - p.depth)
            for y in lumaRows {
                shiftRow(p.y + y * p.yRowBytes, into: p.luma + y * p.lumaRowBytes, count: p.width, shift: shift)
            }
            for y in chromaRows {
                interleaveRow(p.cb + y * p.cbRowBytes, p.cr + y * p.crRowBytes, into: p.chroma + y * p.chromaRowBytes,
                              count: p.chromaWidth, shift: shift)
            }
        }
    }

    /// dst[x] = src[x] << shift for `count` UInt16 samples, 8 lanes at a time.
    @inline(__always)
    private static func shiftRow(_ src: UnsafeRawPointer, into dst: UnsafeMutableRawPointer, count: Int, shift: UInt16) {
        let s = SIMD8<UInt16>(repeating: shift)
        var x = 0
        while x + 8 <= count {
            let v = src.loadUnaligned(fromByteOffset: 2 * x, as: SIMD8<UInt16>.self)
            dst.storeBytes(of: v &<< s, toByteOffset: 2 * x, as: SIMD8<UInt16>.self)
            x += 8
        }
        while x < count {
            dst.storeBytes(of: src.loadUnaligned(fromByteOffset: 2 * x, as: UInt16.self) &<< shift,
                           toByteOffset: 2 * x, as: UInt16.self)
            x += 1
        }
    }

    /// dst = (cb[0] << shift, cr[0] << shift, cb[1] << shift, …) for `count` pairs, 8 pairs at a
    /// time: each pair is one little-endian UInt32 (Cb low, Cr high).
    @inline(__always)
    private static func interleaveRow(_ cb: UnsafeRawPointer, _ cr: UnsafeRawPointer, into dst: UnsafeMutableRawPointer,
                                      count: Int, shift: UInt16) {
        let s = SIMD8<UInt16>(repeating: shift)
        var x = 0
        while x + 8 <= count {
            let u = SIMD8<UInt32>(truncatingIfNeeded: cb.loadUnaligned(fromByteOffset: 2 * x, as: SIMD8<UInt16>.self) &<< s)
            let v = SIMD8<UInt32>(truncatingIfNeeded: cr.loadUnaligned(fromByteOffset: 2 * x, as: SIMD8<UInt16>.self) &<< s)
            dst.storeBytes(of: u | (v &<< 16), toByteOffset: 4 * x, as: SIMD8<UInt32>.self)
            x += 8
        }
        while x < count {
            dst.storeBytes(of: cb.loadUnaligned(fromByteOffset: 2 * x, as: UInt16.self) &<< shift,
                           toByteOffset: 4 * x, as: UInt16.self)
            dst.storeBytes(of: cr.loadUnaligned(fromByteOffset: 2 * x, as: UInt16.self) &<< shift,
                           toByteOffset: 4 * x + 2, as: UInt16.self)
            x += 1
        }
    }

    /// Scalar reference (the original per-sample loops); the vectorised copy must match it byte for byte.
    static func copyReference(_ p: Planes) {
        if p.depth == 8 {
            for y in 0..<p.height { (p.luma + y * p.lumaRowBytes).copyMemory(from: p.y + y * p.yRowBytes, byteCount: p.width) }
            for y in 0..<p.chromaHeight {
                let u = (p.cb + y * p.cbRowBytes).assumingMemoryBound(to: UInt8.self)
                let v = (p.cr + y * p.crRowBytes).assumingMemoryBound(to: UInt8.self)
                let d = (p.chroma + y * p.chromaRowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<p.chromaWidth { d[2 * x] = u[x]; d[2 * x + 1] = v[x] }
            }
        } else {
            let shift = UInt16(16 - p.depth)
            for y in 0..<p.height {
                let s = (p.y + y * p.yRowBytes).assumingMemoryBound(to: UInt16.self)
                let d = (p.luma + y * p.lumaRowBytes).assumingMemoryBound(to: UInt16.self)
                for x in 0..<p.width { d[x] = s[x] << shift }
            }
            for y in 0..<p.chromaHeight {
                let u = (p.cb + y * p.cbRowBytes).assumingMemoryBound(to: UInt16.self)
                let v = (p.cr + y * p.crRowBytes).assumingMemoryBound(to: UInt16.self)
                let d = (p.chroma + y * p.chromaRowBytes).assumingMemoryBound(to: UInt16.self)
                for x in 0..<p.chromaWidth { d[2 * x] = u[x] << shift; d[2 * x + 1] = v[x] << shift }
            }
        }
    }
}
