import CoreVideo
import Foundation
import MediaEngine
import RenderEngine

/// A frame waiting to be written (its delay grows while following frames are identical).
private struct PendingGIFFrame {
    var indices: [UInt8]
    var rect: (x: Int, y: Int, w: Int, h: Int)
    var palette: Palette
    var transparent: Int?
    var delay: Int
}

extension ExportSession {
    /// Memory budget for one palette segment's buffered RGB frames.
    static let gifSegmentBytes = 256 << 20

    /// Writes an animated GIF: frames from the render path, one median-cut palette per segment
    /// (a segment ends when the visible top-level clips change or after `maxSegmentFrames`),
    /// Floyd–Steinberg dithering, unchanged pixels transparent, identical frames merged.
    func writeGIF(to url: URL, resolved r: ResolvedExport) async throws {
        let timing = r.timing
        let frameCount = timing.frameCount
        guard frameCount > 0 else { throw ExportError.failed("no frames in range") }
        let w = Int(r.size.width), h = Int(r.size.height)
        let fps = Int(timing.fps.num / max(timing.fps.den, 1))
        let opts = settings.gif
        let perFrame = max(w * h * 3, 1)
        let segmentLimit = max(1, min(opts.maxSegmentFrames, Self.gifSegmentBytes / perFrame))

        let file = try GIFFileWriter(url: url, width: w, height: h, loopCount: opts.loopCount)
        var closed = false
        defer { if !closed { try? file.close() } }
        let renderer = OfflineRenderer(scene: scene, pool: pool)
        let buffers = try Self.makeBufferPool(width: w, height: h)

        var displayed: [UInt8]? = nil  // what the GIF shows so far, packed RGB
        var pending: PendingGIFFrame? = nil
        var segment: [[UInt8]] = []
        var segmentKey: [Int64]? = nil
        var segmentStart = 0

        func flushSegment() throws {
            guard !segment.isEmpty else { return }
            let stride = max(1, segment.count * w * h / 1_000_000)
            let samples: [[UInt8]] = stride == 1 ? segment : segment.map { f in
                var s: [UInt8] = []
                s.reserveCapacity(f.count / stride + 3)
                var i = 0
                while i + 2 < f.count { s += [f[i], f[i + 1], f[i + 2]]; i += 3 * stride }
                return s
            }
            let palette = Palette.medianCut(samples, maxColors: min(opts.maxColors, 255))
            var q = Quantizer(palette: palette)
            let tIndex = palette.colors.count
            for (k, rgb) in segment.enumerated() {
                let n = segmentStart + k
                let delay = GIFFileWriter.delay(frame: n, fps: fps)
                let full = q.indices(rgb, width: w, height: h, dither: opts.dither)
                var shown = [UInt8](repeating: 0, count: w * h * 3)
                for i in 0..<(w * h) {
                    let c = palette.colors[Int(full[i])]
                    shown[3 * i] = c.r; shown[3 * i + 1] = c.g; shown[3 * i + 2] = c.b
                }
                guard let prev = displayed else {
                    pending = PendingGIFFrame(indices: full, rect: (0, 0, w, h), palette: palette,
                                              transparent: nil, delay: delay)
                    displayed = shown
                    continue
                }
                // Bounding box of pixels whose shown colour changes.
                var x0 = w, y0 = h, x1 = -1, y1 = -1
                for y in 0..<h {
                    let row = y * w * 3
                    for x in 0..<w {
                        let p = row + 3 * x
                        if prev[p] != shown[p] || prev[p + 1] != shown[p + 1] || prev[p + 2] != shown[p + 2] {
                            if x < x0 { x0 = x }; if x > x1 { x1 = x }
                            if y < y0 { y0 = y }; if y > y1 { y1 = y }
                        }
                    }
                }
                if x1 < 0 {
                    pending?.delay += delay  // identical frame: show the previous one longer
                    continue
                }
                if let p = pending {
                    try file.addFrame(indices: p.indices, rect: p.rect, palette: p.palette,
                                      transparent: p.transparent, delay: p.delay)
                }
                let rw = x1 - x0 + 1, rh = y1 - y0 + 1
                var sub = [UInt8](repeating: UInt8(tIndex), count: rw * rh)
                for y in 0..<rh {
                    for x in 0..<rw {
                        let i = (y0 + y) * w + (x0 + x), p = 3 * i
                        if prev[p] != shown[p] || prev[p + 1] != shown[p + 1] || prev[p + 2] != shown[p + 2] {
                            sub[y * rw + x] = full[i]
                        }
                    }
                }
                pending = PendingGIFFrame(indices: sub, rect: (x0, y0, rw, rh), palette: palette,
                                          transparent: tIndex, delay: delay)
                displayed = shown
            }
            segmentStart += segment.count
            segment.removeAll(keepingCapacity: true)
        }

        for n in 0..<frameCount {
            if isCancelled { throw ExportError.cancelled }
            let ticks = timing.ticks(frame: n)
            let key = scene.evaluate(at: ticks).layers.map(\.clipID)
            if segment.count >= segmentLimit || (segmentKey != nil && key != segmentKey) {
                try flushSegment()
            }
            segmentKey = key
            nonisolated(unsafe) let pb = try Self.buffer(from: buffers)
            try await renderer.render(at: ticks, into: pb)
            segment.append(Self.rgb(pb))
            report(Double(n + 1) / Double(frameCount) * 0.95)
        }
        try flushSegment()
        if let p = pending {
            try file.addFrame(indices: p.indices, rect: p.rect, palette: p.palette, transparent: p.transparent,
                              delay: p.delay)
        }
        try file.close()
        closed = true
    }

    static func makeBufferPool(width: Int, height: Int) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        guard let pool else { throw ExportError.failed("pixel buffer pool") }
        return pool
    }

    static func buffer(from pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { throw ExportError.failed("pixel buffer allocation") }
        return pb
    }

    /// Packed RGB of a premultiplied BGRA buffer (alpha dropped: composited over black).
    static func rgb(_ pb: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), rb = CVPixelBufferGetBytesPerRow(pb)
        var out = [UInt8](repeating: 0, count: w * h * 3)
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return out }
        out.withUnsafeMutableBufferPointer { dst in
            for y in 0..<h {
                let row = base + y * rb
                for x in 0..<w {
                    let o = 3 * (y * w + x)
                    dst[o] = row[4 * x + 2]; dst[o + 1] = row[4 * x + 1]; dst[o + 2] = row[4 * x]
                }
            }
        }
        return out
    }
}
