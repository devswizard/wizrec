import Foundation

/// An RGB palette: up to 255 opaque colours (index `count` is reserved for "transparent").
struct Palette: Equatable {
    /// Colours, 0–255 per component.
    var colors: [(r: UInt8, g: UInt8, b: UInt8)]

    static func == (a: Palette, b: Palette) -> Bool {
        a.colors.count == b.colors.count && zip(a.colors, b.colors).allSatisfy { $0 == $1 }
    }

    /// Median-cut palette of at most `maxColors` colours from packed RGB `samples` (3 bytes/px).
    /// Works on a 5-bit-per-channel histogram; each colour is the mean of its box. Deterministic.
    static func medianCut(_ samples: [[UInt8]], maxColors: Int) -> Palette {
        let maxColors = min(max(maxColors, 2), 255)
        var count = [Int](repeating: 0, count: 32768)
        var sr = [Int](repeating: 0, count: 32768), sg = sr, sb = sr
        for buf in samples {
            buf.withUnsafeBufferPointer { p in
                var i = 0
                while i + 2 < p.count {
                    let r = Int(p[i]), g = Int(p[i + 1]), b = Int(p[i + 2])
                    let k = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
                    count[k] += 1; sr[k] += r; sg[k] += g; sb[k] += b
                    i += 3
                }
            }
        }
        var bins = (0..<32768).filter { count[$0] > 0 }
        guard !bins.isEmpty else { return Palette(colors: [(0, 0, 0), (255, 255, 255)]) }

        struct Box { var lo: Int; var hi: Int }  // range in `bins`
        func comp(_ k: Int, _ axis: Int) -> Int { (k >> (10 - 5 * axis)) & 31 }
        func extent(_ b: Box) -> (axis: Int, span: Int, weight: Int) {
            var mn = [31, 31, 31], mx = [0, 0, 0], w = 0
            for i in b.lo..<b.hi {
                let k = bins[i]
                for a in 0..<3 { let v = comp(k, a); mn[a] = min(mn[a], v); mx[a] = max(mx[a], v) }
                w += count[k]
            }
            let spans = (0..<3).map { mx[$0] - mn[$0] }
            let axis = spans.firstIndex(of: spans.max() ?? 0) ?? 0
            return (axis, spans[axis], w)
        }
        var boxes = [Box(lo: 0, hi: bins.count)]
        while boxes.count < maxColors {
            // Split the box with the largest span × weight that can be split.
            var best = -1, bestScore = 0, bestAxis = 0
            for (i, b) in boxes.enumerated() where b.hi - b.lo > 1 {
                let e = extent(b)
                let score = e.span * Int(Double(e.weight).squareRoot() + 1)
                if e.span > 0, score > bestScore { best = i; bestScore = score; bestAxis = e.axis }
            }
            guard best >= 0 else { break }
            let b = boxes[best]
            bins[b.lo..<b.hi].sort { (comp($0, bestAxis), $0) < (comp($1, bestAxis), $1) }
            let total = (b.lo..<b.hi).reduce(0) { $0 + count[bins[$1]] }
            var acc = 0, cut = b.lo + 1
            for i in b.lo..<b.hi {
                acc += count[bins[i]]
                if acc * 2 >= total { cut = min(max(i + 1, b.lo + 1), b.hi - 1); break }
            }
            boxes[best] = Box(lo: b.lo, hi: cut)
            boxes.append(Box(lo: cut, hi: b.hi))
        }
        var colors: [(r: UInt8, g: UInt8, b: UInt8)] = boxes.map { b in
            var n = 0, r = 0, g = 0, bl = 0
            for i in b.lo..<b.hi { let k = bins[i]; n += count[k]; r += sr[k]; g += sg[k]; bl += sb[k] }
            n = max(n, 1)
            return (UInt8((r + n / 2) / n), UInt8((g + n / 2) / n), UInt8((bl + n / 2) / n))
        }
        if colors.count == 1 { colors.append(colors[0] == (0, 0, 0) ? (255, 255, 255) : (0, 0, 0)) }
        return Palette(colors: colors)
    }
}

/// Maps RGB pixels to palette indices, optionally with Floyd–Steinberg error diffusion.
struct Quantizer {
    let palette: Palette
    private var lut: [Int16]  // 6 bits per channel → nearest index, -1 = not computed

    init(palette: Palette) {
        self.palette = palette
        lut = [Int16](repeating: -1, count: 1 << 18)
    }

    private mutating func nearest(_ r: Int, _ g: Int, _ b: Int) -> Int {
        let k = (r >> 2) << 12 | (g >> 2) << 6 | (b >> 2)
        let cached = lut[k]
        if cached >= 0 { return Int(cached) }
        // Search from the bin's centre so every pixel in the bin maps the same way (deterministic).
        let cr = (r >> 2) << 2 | 2, cg = (g >> 2) << 2 | 2, cb = (b >> 2) << 2 | 2
        var best = 0, bestD = Int.max
        for (i, c) in palette.colors.enumerated() {
            let dr = cr - Int(c.r), dg = cg - Int(c.g), db = cb - Int(c.b)
            let d = 2 * dr * dr + 4 * dg * dg + db * db
            if d < bestD { bestD = d; best = i }
        }
        lut[k] = Int16(best)
        return best
    }

    /// Palette indices for `width`×`height` packed RGB.
    mutating func indices(_ rgb: [UInt8], width: Int, height: Int, dither: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        guard dither else {
            for i in 0..<(width * height) {
                out[i] = UInt8(nearest(Int(rgb[3 * i]), Int(rgb[3 * i + 1]), Int(rgb[3 * i + 2])))
            }
            return out
        }
        // Errors in 1/16 units, current and next row, 3 channels, with a 1 px margin each side.
        var cur = [Int32](repeating: 0, count: (width + 2) * 3)
        var nxt = cur
        for y in 0..<height {
            for i in nxt.indices { nxt[i] = 0 }
            for x in 0..<width {
                let p = 3 * (y * width + x), e = 3 * (x + 1)
                let r = Self.clamp(Int(rgb[p]) + Int(cur[e]) / 16)
                let g = Self.clamp(Int(rgb[p + 1]) + Int(cur[e + 1]) / 16)
                let b = Self.clamp(Int(rgb[p + 2]) + Int(cur[e + 2]) / 16)
                let idx = nearest(r, g, b)
                out[y * width + x] = UInt8(idx)
                let c = palette.colors[idx]
                let er = Int32(r - Int(c.r)), eg = Int32(g - Int(c.g)), eb = Int32(b - Int(c.b))
                for (ch, err) in [(0, er), (1, eg), (2, eb)] {
                    cur[e + 3 + ch] += err * 7
                    nxt[e - 3 + ch] += err * 3
                    nxt[e + ch] += err * 5
                    nxt[e + 3 + ch] += err
                }
            }
            swap(&cur, &nxt)
        }
        return out
    }

    private static func clamp(_ v: Int) -> Int { min(max(v, 0), 255) }
}

/// GIF89a LZW image data (variable-width codes, clear on a full table).
enum LZW {
    /// Compressed bytes (no sub-block framing) for `indices`, each < 2^`minCodeSize`.
    static func encode(_ indices: [UInt8], minCodeSize: Int) -> [UInt8] {
        let clear = 1 << minCodeSize, eoi = clear + 1
        var codeSize = minCodeSize + 1
        var next = eoi + 1
        var clearFlag = false
        var table = [Int16](repeating: -1, count: 4096 * 256)
        var used: [Int] = []
        used.reserveCapacity(4096)
        var out: [UInt8] = []
        out.reserveCapacity(indices.count / 2)
        var acc: UInt32 = 0, bits = 0

        func output(_ code: Int) {
            acc |= UInt32(code) << UInt32(bits)
            bits += codeSize
            while bits >= 8 { out.append(UInt8(acc & 0xFF)); acc >>= 8; bits -= 8 }
            if clearFlag {
                codeSize = minCodeSize + 1
                clearFlag = false
            } else if next > (1 << codeSize) - 1, codeSize < 12 {
                codeSize += 1
            }
        }

        output(clear)
        guard var prefix = indices.first.map(Int.init) else {
            output(eoi)
            if bits > 0 { out.append(UInt8(acc & 0xFF)) }
            return out
        }
        for k in indices.dropFirst() {
            let key = prefix << 8 | Int(k)
            let hit = table[key]
            if hit >= 0 { prefix = Int(hit); continue }
            output(prefix)
            if next < 4096 {
                table[key] = Int16(next); used.append(key); next += 1
            } else {
                for u in used { table[u] = -1 }
                used.removeAll(keepingCapacity: true)
                next = eoi + 1
                clearFlag = true
                output(clear)
            }
            prefix = Int(k)
        }
        output(prefix)
        output(eoi)
        if bits > 0 { out.append(UInt8(acc & 0xFF)) }
        return out
    }
}

/// Streams a GIF89a file: local colour table per frame, optional transparency, centisecond delays.
final class GIFFileWriter {
    private let handle: FileHandle
    let width: Int, height: Int

    init(url: URL, width: Int, height: Int, loopCount: Int) throws {
        guard width > 0, height > 0, width <= 65535, height <= 65535 else {
            throw ExportError.failed("GIF size \(width)×\(height) out of range")
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        self.width = width; self.height = height
        var h: [UInt8] = Array("GIF89a".utf8)
        h += Self.u16(width) + Self.u16(height) + [0x00, 0x00, 0x00]  // no global table
        // NETSCAPE2.0 application extension: loop count.
        h += [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [0x03, 0x01] + Self.u16(min(max(loopCount, 0), 65535)) + [0x00]
        try handle.write(contentsOf: Data(h))
    }

    static func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

    /// Appends one image. `indices` covers `rect` (x, y, w, h) row-major; `transparent` is the
    /// index drawn as "keep the previous pixel" (or nil). `delay` in centiseconds.
    func addFrame(indices: [UInt8], rect: (x: Int, y: Int, w: Int, h: Int), palette: Palette,
                  transparent: Int?, delay: Int) throws {
        let entries = palette.colors.count + (transparent == nil ? 0 : 1)
        var tableBits = 1
        while (1 << tableBits) < entries { tableBits += 1 }
        var b: [UInt8] = []
        // Graphic control extension: disposal 1 (leave in place), transparency flag.
        let packed: UInt8 = (1 << 2) | (transparent == nil ? 0 : 1)
        b += [0x21, 0xF9, 0x04, packed] + Self.u16(min(max(delay, 0), 65535)) + [UInt8(transparent ?? 0), 0x00]
        b += [0x2C] + Self.u16(rect.x) + Self.u16(rect.y) + Self.u16(rect.w) + Self.u16(rect.h)
        b += [0x80 | UInt8(tableBits - 1)]
        for i in 0..<(1 << tableBits) {
            if i < palette.colors.count {
                let c = palette.colors[i]; b += [c.r, c.g, c.b]
            } else {
                b += [0, 0, 0]
            }
        }
        let minCode = max(2, tableBits)
        b.append(UInt8(minCode))
        let data = LZW.encode(indices, minCodeSize: minCode)
        var i = 0
        while i < data.count {
            let n = min(255, data.count - i)
            b.append(UInt8(n)); b += data[i..<(i + n)]
            i += n
        }
        b.append(0x00)
        try handle.write(contentsOf: Data(b))
    }

    func close() throws {
        try handle.write(contentsOf: Data([0x3B]))
        try handle.close()
    }

    /// Centiseconds shown by frame `n` at `fps` (accumulated so the total stays exact).
    static func delay(frame n: Int, fps: Int) -> Int {
        let f = max(fps, 1)
        func t(_ k: Int) -> Int { (k * 100 + f / 2) / f }
        return t(n + 1) - t(n)
    }
}
