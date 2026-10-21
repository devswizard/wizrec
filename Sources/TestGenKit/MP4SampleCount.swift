import Foundation

/// Sample counts read straight from an MP4/MOV file's box tree (no AVFoundation, no decode):
/// `moov/trak/mdia/minf/stbl/stsz` per track, in file order. Used to check what an encode
/// really wrote (QA12-3).
public enum MP4SampleCount {
    /// Sample count of every track whose handler is `vide` (in file order); nil when the file
    /// can't be read or has no such box path.
    public static func videoTracks(_ url: URL) -> [Int]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let bytes = [UInt8](data)
        guard let moov = children(bytes, 0..<bytes.count).first(where: { $0.type == "moov" }) else { return nil }
        var counts: [Int] = []
        for trak in children(bytes, moov.body) where trak.type == "trak" {
            guard let mdia = children(bytes, trak.body).first(where: { $0.type == "mdia" }),
                  let hdlr = children(bytes, mdia.body).first(where: { $0.type == "hdlr" }),
                  hdlr.body.count >= 12, fourCC(bytes, hdlr.body.lowerBound + 8) == "vide",
                  let minf = children(bytes, mdia.body).first(where: { $0.type == "minf" }),
                  let stbl = children(bytes, minf.body).first(where: { $0.type == "stbl" }) else { continue }
            if let stsz = children(bytes, stbl.body).first(where: { $0.type == "stsz" }), stsz.body.count >= 12 {
                counts.append(Int(u32(bytes, stsz.body.lowerBound + 8)))
            } else if let stz2 = children(bytes, stbl.body).first(where: { $0.type == "stz2" }), stz2.body.count >= 12 {
                counts.append(Int(u32(bytes, stz2.body.lowerBound + 8)))
            }
        }
        return counts.isEmpty ? nil : counts
    }

    private struct Box { var type: String; var body: Range<Int> }

    /// The boxes directly inside `range` (stops at the first malformed size).
    private static func children(_ b: [UInt8], _ range: Range<Int>) -> [Box] {
        var out: [Box] = []
        var at = range.lowerBound
        while at + 8 <= range.upperBound {
            var size = Int(u32(b, at))
            var header = 8
            if size == 1 {
                guard at + 16 <= range.upperBound else { break }
                let big = (UInt64(u32(b, at + 8)) << 32) | UInt64(u32(b, at + 12))
                guard big <= UInt64(Int.max) else { break }
                size = Int(big); header = 16
            } else if size == 0 {
                size = range.upperBound - at
            }
            guard size >= header, at + size <= range.upperBound else { break }
            out.append(Box(type: fourCC(b, at + 4), body: (at + header)..<(at + size)))
            at += size
        }
        return out
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        let a: UInt32 = UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16
        return a | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    private static func fourCC(_ b: [UInt8], _ i: Int) -> String {
        String(decoding: b[i..<(i + 4)], as: UTF8.self)
    }
}
