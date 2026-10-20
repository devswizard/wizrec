// Parallel row-band swscale conversion (same size, no vertical chroma subsampling).

import CFFmpeg
import Foundation

/// Same-size swscale conversion in parallel row bands, one context per band (contexts are not
/// thread-safe). Valid only for bands from `FrameConverter.swsBands` (no vertical chroma
/// subsampling on either side, 8-row aligned): the bytes then equal a one-pass conversion.
/// Not thread-safe itself: owned by one converter.
final class BandedSws {
    private var contexts: [UnsafeMutablePointer<SwsContext>] = []
    private var key: [Int32] = []

    deinit { for c in contexts { sws_freeContext(c) } }

    /// Converts `frame` into the destination planes (base address, bytes per row), rebuilding the
    /// band contexts with `make(bandHeight)` when `key` or the bands change.
    func run(_ frame: UnsafeMutablePointer<AVFrame>, bands: [Range<Int>], key k: [Int32], dst: [(UInt, Int)],
             make: (Int) throws -> UnsafeMutablePointer<SwsContext>) throws {
        let fullKey = k + bands.map { Int32($0.count) }
        if key != fullKey {
            for c in contexts { sws_freeContext(c) }
            contexts = []
            key = []
            for b in bands { contexts.append(try make(b.count)) }
            key = fullKey
        }
        let planes = Int(av_pix_fmt_count_planes(AVPixelFormat(frame.pointee.format)))
        guard planes > 0, planes <= 4, !dst.isEmpty, dst.count <= 4 else {
            throw MediaError.decodeFailed("unexpected plane count \(planes)/\(dst.count)")
        }
        // Addresses cross into the workers as integers (pointers are not Sendable); the frame and
        // the destination stay alive (and locked) until `concurrentPerform` returns.
        let d = frame.pointee.data, l = frame.pointee.linesize
        let srcBase: [UInt] = [d.0, d.1, d.2, d.3].prefix(planes).map { $0.map { UInt(bitPattern: $0) } ?? 0 }
        let srcStride: [Int] = [l.0, l.1, l.2, l.3].prefix(planes).map(Int.init)
        guard !srcBase.contains(0), !dst.contains(where: { $0.0 == 0 }) else {
            throw MediaError.decodeFailed("picture without planes")
        }
        let ctxs = contexts.map { UInt(bitPattern: $0) }
        let results = UnsafeMutableBufferPointer<Int32>.allocate(capacity: bands.count)
        defer { results.deallocate() }
        results.initialize(repeating: 0)
        let resultBase = UInt(bitPattern: results.baseAddress)
        DispatchQueue.concurrentPerform(iterations: bands.count) { i in
            let rows = bands[i]
            guard let ctx = UnsafeMutablePointer<SwsContext>(bitPattern: ctxs[i]),
                  let rc = UnsafeMutablePointer<Int32>(bitPattern: resultBase + UInt(i * 4)) else { return }
            // No vertical chroma subsampling: every plane advances one line per row.
            let src: [UnsafePointer<UInt8>?] = (0..<4).map { p in
                p < planes ? UnsafePointer<UInt8>(bitPattern: srcBase[p] + UInt(rows.lowerBound * srcStride[p])) : nil
            }
            let srcStrides: [Int32] = (0..<4).map { p in p < planes ? Int32(srcStride[p]) : 0 }
            var out: [UnsafeMutablePointer<UInt8>?] = (0..<4).map { p in
                p < dst.count ? UnsafeMutablePointer<UInt8>(bitPattern: dst[p].0 + UInt(rows.lowerBound * dst[p].1)) : nil
            }
            var outStrides: [Int32] = (0..<4).map { p in p < dst.count ? Int32(dst[p].1) : 0 }
            rc.pointee = sws_scale(ctx, src, srcStrides, 0, Int32(rows.count), &out, &outStrides)
        }
        guard results.allSatisfy({ $0 > 0 }) else { throw MediaError.decodeFailed("sws_scale failed in a band") }
    }
}
