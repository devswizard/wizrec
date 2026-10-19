import CoreGraphics
import Foundation
import ImageIO
import os

/// Reads the cursor streams of a `.trec` recording's top-level `TSCM` atom (`docs/specs/trec.md`) into a
/// `CursorTrack`. Only the cursor, cursor-image, button, region and scale streams are decoded; every other
/// record (several hold window titles and device names) is skipped unread and never logged.
enum TrecCursor {
    /// Stream GUIDs share this suffix; only the first group differs [trec.md §1].
    static let guidSuffix: [UInt8] = [0x7a, 0x1f, 0x11, 0xe2, 0x83, 0xd0, 0x00, 0x17, 0xf2, 0x00, 0xbe, 0x7f]
    static let positions: UInt32 = 0x2b7b_6af2
    static let images: UInt32 = 0x2b7b_6af1
    static let buttons: UInt32 = 0x2b7b_6af0
    static let region: UInt32 = 0x2b7b_6af6
    static let scale: UInt32 = 0x2b7b_6afb

    /// Events outside [−60 s, duration + 60 s] are junk (Windows pre-roll artefacts) [trec.md §1].
    static let timeSlack = 60.0

    /// The `TSCM` atom's body, read by walking top-level atoms (header seeks only; the video is never read).
    static func tscm(_ url: URL) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let end = try? h.seekToEnd() else { return nil }
        var pos: UInt64 = 0
        while pos + 8 <= end {
            guard (try? h.seek(toOffset: pos)) != nil, let head = try? h.read(upToCount: 16), head.count >= 8 else { return nil }
            var size = UInt64(be32(head, 0))
            let type = String(bytes: head[head.startIndex + 4..<head.startIndex + 8], encoding: .ascii) ?? ""
            var headerLength: UInt64 = 8
            if size == 1 {
                guard head.count >= 16 else { return nil }
                size = be64(head, 8); headerLength = 16
            } else if size == 0 {
                size = end - pos
            }
            guard size >= headerLength, pos + size <= end else { return nil }
            if type == "TSCM" {
                guard (try? h.seek(toOffset: pos + headerLength)) != nil else { return nil }
                return try? h.read(upToCount: Int(size - headerLength))
            }
            pos += size
        }
        return nil
    }

    /// Splits `TSCM` into records and returns the payloads of the wanted streams, keyed by GUID prefix,
    /// with each record's format field `a` and element size.
    static func streams(_ body: Data, wanted: Set<UInt32>) -> [UInt32: [(a: UInt32, elementSize: UInt32, payload: Data)]] {
        var out: [UInt32: [(UInt32, UInt32, Data)]] = [:]
        let b = [UInt8](body)
        var p = 0
        while p + 40 <= b.count {
            guard be32(b, p) == 1, b[p + 4] == 0x44, b[p + 5] == 0x41, b[p + 6] == 0x54, b[p + 7] == 0x41 else { break }
            let length = Int(clamping: be64(b, p + 8))
            guard length >= 40, p + length <= b.count else { break }
            let guidPrefix = be32(b, p + 16)
            let suffixOK = Array(b[(p + 20)..<(p + 32)]) == guidSuffix
            if suffixOK, wanted.contains(guidPrefix) {
                out[guidPrefix, default: []].append((le32(b, p + 32), le32(b, p + 36), Data(b[(p + 40)..<(p + length)])))
            }
            p += length
        }
        return out
    }

    /// Loads the cursor of `url` (a `.trec`); `duration` = video length in seconds (for junk filtering).
    static func load(_ url: URL, duration: Double?) -> CursorTrack? {
        guard let body = tscm(url) else { return nil }
        let s = streams(body, wanted: [positions, images, buttons, region, scale])
        let maxT = (duration ?? .infinity) + timeSlack
        func ok(_ t: Double) -> Bool { t.isFinite && t >= -timeSlack && t <= maxT }

        // Region and scale: latest at or before t; a single event in every observed file [trec.md §5].
        var regionRect: CGRect?
        for r in s[region] ?? [] where r.elementSize >= 24 {
            let b = [UInt8](r.payload)
            var i = 0
            while i + 24 <= b.count {
                if ok(leF64(b, i)), regionRect == nil {
                    regionRect = CGRect(x: Double(leI32(b, i + 8)), y: Double(leI32(b, i + 12)),
                                        width: Double(leI32(b, i + 16)), height: Double(leI32(b, i + 20)))
                }
                i += Int(r.elementSize)
            }
        }
        var factor = 1.0
        for r in s[scale] ?? [] where r.elementSize >= 12 {
            let b = [UInt8](r.payload)
            if b.count >= 12, le32(b, 8) > 0 { factor = Double(le32(b, 8)) }
        }
        guard let region = regionRect, region.width > 0, region.height > 0 else { return nil }
        let video = CGSize(width: region.width * factor, height: region.height * factor)
        let kx = video.width / region.width, ky = video.height / region.height

        var pos: [(t: Double, x: Double, y: Double)] = []
        for r in s[positions] ?? [] where r.elementSize >= 16 {
            let b = [UInt8](r.payload)
            var i = 0
            while i + 16 <= b.count {
                let t = leF64(b, i)
                if ok(t) {
                    pos.append((t, (Double(leI32(b, i + 8)) - region.minX) * kx, (Double(leI32(b, i + 12)) - region.minY) * ky))
                }
                i += Int(r.elementSize)
            }
        }
        var clicks: [CursorTrack.Click] = []
        for r in s[buttons] ?? [] where r.elementSize >= 12 {
            let b = [UInt8](r.payload)
            var i = 0
            while i + 12 <= b.count {
                let t = leF64(b, i), code = le32(b, i + 8)
                if ok(t) {
                    // Bit flags: 1/2 left down/up, 4/8 right down/up; 256 = start marker, not a click [trec.md §4].
                    if code & 1 != 0 { clicks.append(.init(t: t, button: .left, down: true)) }
                    if code & 2 != 0 { clicks.append(.init(t: t, button: .left, down: false)) }
                    if code & 4 != 0 { clicks.append(.init(t: t, button: .right, down: true)) }
                    if code & 8 != 0 { clicks.append(.init(t: t, button: .right, down: false)) }
                }
                i += Int(r.elementSize)
            }
        }
        var shapes: [(t: Double, id: Int)] = []
        var imgs: [Int: CursorTrack.Image] = [:]
        for r in s[images] ?? [] {
            let b = [UInt8](r.payload)
            var i = 0
            while i + 4 <= b.count {
                let l = Int(le32(b, i))
                let evEnd = min(i + 4 + l, b.count)
                guard l >= 16, i + 4 + 16 <= b.count else { break }
                let t = leF64(b, i + 4), id = Int(le32(b, i + 12))
                if ok(t) { shapes.append((t, id)) }
                var q = i + 4 + 16
                if q + 4 <= evEnd, imgs[id] == nil {
                    let inner = Int(le32(b, q)); q += 4
                    if r.a >= 2 {
                        if inner > 24, q + 12 <= evEnd {
                            let pngLength = Int(le32(b, q))
                            let hx = Double(leI32(b, q + 4)), hy = Double(leI32(b, q + 8))
                            let start = q + 12
                            if pngLength > 0 {
                                imgs[id] = image(Data(b[start..<min(start + pngLength, b.count)]), hotX: hx, hotYFromBottom: hy,
                                                 url: url, id: id)
                            }
                        }
                    } else if inner > 8, q + 8 <= b.count {
                        let hx = Double(leI32(b, q)), hy = Double(leI32(b, q + 4))
                        let start = q + 8
                        // R2's PNG runs past its record: take what exists [trec.md §3].
                        imgs[id] = image(Data(b[start..<min(start + inner - 8, b.count)]), hotX: hx, hotYFromBottom: hy,
                                         url: url, id: id)
                    }
                }
                i = evEnd
            }
        }
        let cleanImages = imgs.compactMapValues { $0 }
        guard !pos.isEmpty, !cleanImages.isEmpty else { return nil }
        // Before the first cursor event, the first image [trec.md §3].
        if let first = shapes.min(by: { $0.t < $1.t }) { shapes.insert((-Double.infinity, first.id), at: 0) }
        func sortedStable<T>(_ a: [T], _ key: (T) -> Double) -> [T] {
            a.enumerated().sorted { (key($0.element), $0.offset) < (key($1.element), $1.offset) }.map(\.element)
        }
        pos = sortedStable(pos) { $0.t }
        // Before the first sample, the first sample [trec.md §2].
        if let f = pos.first { pos.insert((-Double.infinity, f.x, f.y), at: 0) }
        return CursorTrack(videoSize: video, images: cleanImages, positions: pos, shapes: sortedStable(shapes) { $0.t },
                           clicks: sortedStable(clicks) { $0.t })
    }

    /// Registers the PNG under a synthetic URL and converts the hotspot to top-down px.
    private static func image(_ png: Data, hotX: Double, hotYFromBottom: Double, url: URL, id: Int) -> CursorTrack.Image? {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 else { return nil }
        let key = CursorImageStore.url(source: url, id: id)
        CursorImageStore.shared.put(png, for: key)
        return CursorTrack.Image(url: key, size: CGSize(width: w, height: h), hotspot: CGPoint(x: hotX, y: h - hotYFromBottom))
    }

    /// Cached per file and modification date.
    static func cached(_ url: URL, duration: Double?) -> CursorTrack? {
        let stamp = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
        if let hit = cache.withLock({ $0[url] }), hit.stamp == stamp { return hit.track }
        let track = load(url, duration: duration)
        cache.withLock { $0[url] = (stamp, track) }
        return track
    }

    private static let cache = OSAllocatedUnfairLock<[URL: (stamp: Date, track: CursorTrack?)]>(initialState: [:])

    // MARK: Bytes

    static func be32(_ d: some RandomAccessCollection<UInt8>, _ o: Int) -> UInt32 {
        let i = d.index(d.startIndex, offsetBy: o)
        return d[i..<d.index(i, offsetBy: 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }
    static func be64(_ d: some RandomAccessCollection<UInt8>, _ o: Int) -> UInt64 {
        let i = d.index(d.startIndex, offsetBy: o)
        return d[i..<d.index(i, offsetBy: 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }
    static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
    static func leI32(_ b: [UInt8], _ o: Int) -> Int32 { Int32(bitPattern: le32(b, o)) }
    static func leF64(_ b: [UInt8], _ o: Int) -> Double {
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(b[o + k]) << (8 * UInt64(k)) }
        return Double(bitPattern: v)
    }
}

/// In-memory cursor PNGs embedded in recordings, addressed by synthetic `wizrec-cursor:` URLs so plans stay
/// small value types. Process-wide; entries are a few KB each.
final class CursorImageStore: Sendable {
    static let shared = CursorImageStore()
    private let data = OSAllocatedUnfairLock<[URL: Data]>(initialState: [:])

    static func url(source: URL, id: Int) -> URL {
        var c = URLComponents()
        c.scheme = "wizrec-cursor"
        c.path = source.path
        c.queryItems = [URLQueryItem(name: "id", value: String(id))]
        return c.url ?? URL(fileURLWithPath: "/wizrec-cursor/\(id)")
    }

    func put(_ d: Data, for url: URL) { data.withLock { $0[url] = d } }
    func get(_ url: URL) -> Data? { data.withLock { $0[url] } }
}
