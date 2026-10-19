import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import RenderEngine

/// Builds a synthetic `.trec`-shaped file (our own bytes, laid out per `docs/specs/trec.md`).
private enum TrecBuilder {
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func be64(_ v: UInt64) -> [UInt8] { (0..<8).reversed().map { UInt8(v >> (UInt64($0) * 8) & 0xFF) } }
    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(v >> (UInt32($0) * 8) & 0xFF) } }
    static func le32(_ v: Int32) -> [UInt8] { le32(UInt32(bitPattern: v)) }
    static func f64(_ v: Double) -> [UInt8] { (0..<8).map { UInt8(v.bitPattern >> (UInt64($0) * 8) & 0xFF) } }

    static func guid(_ prefix: UInt32) -> [UInt8] { be32(prefix) + TrecCursor.guidSuffix }

    static func record(_ prefix: UInt32, a: UInt32 = 1, elementSize: UInt32, _ payload: [UInt8]) -> [UInt8] {
        be32(1) + Array("DATA".utf8) + be64(UInt64(40 + payload.count)) + guid(prefix) + le32(a) + le32(elementSize) + payload
    }

    static func atom(_ type: String, _ body: [UInt8]) -> [UInt8] { be32(UInt32(8 + body.count)) + Array(type.utf8) + body }

    /// A 10×20 opaque PNG.
    static func png() -> [UInt8] {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 10, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 20))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return [UInt8](data as Data)
    }

    static let secret = "SECRET WINDOW TITLE"

    static func file(format a: UInt32 = 2) throws -> URL {
        let p = png()
        var positions: [UInt8] = []
        for (t, x, y) in [(0.5, 110, 60), (1.0, 150, 80)] as [(Double, Int32, Int32)] {
            positions += f64(t) + le32(x) + le32(y)
        }
        let imagePayload: [UInt8]
        if a == 2 {
            let trailer = le32(Int32(-1)) + le32(UInt32(0)) + le32(UInt32(0)) + le32(UInt32(0)) + le32(Float(1).bitPattern)
                + le32(Float(0.5).bitPattern)
            let inner = le32(UInt32(p.count)) + le32(Int32(3)) + le32(Int32(15)) + p + trailer
            let withImage = f64(0) + le32(UInt32(0)) + le32(UInt32(0)) + le32(UInt32(inner.count)) + inner
            let idOnly = f64(2.0) + le32(UInt32(0)) + le32(UInt32(0)) + le32(UInt32(24)) + trailer
            imagePayload = le32(UInt32(withImage.count)) + withImage + le32(UInt32(idOnly.count)) + idOnly
        } else {
            let inner = le32(Int32(3)) + le32(Int32(15)) + p
            let withImage = f64(0) + le32(UInt32(0)) + le32(UInt32(0)) + le32(UInt32(inner.count)) + inner
            imagePayload = le32(UInt32(withImage.count)) + withImage
        }
        let tscm = record(0x2b7b_6afc, elementSize: 0, Array(secret.utf8))          // private text: must be skipped
            + record(TrecCursor.positions, elementSize: 16, positions)
            + record(TrecCursor.images, a: a, elementSize: 0, imagePayload)
            + record(TrecCursor.buttons, elementSize: 12, f64(0.0) + le32(UInt32(256)) + f64(0.9) + le32(UInt32(1))
                     + f64(1.0) + le32(UInt32(2)) + f64(-103050.5) + le32(UInt32(1)))
            + record(TrecCursor.region, elementSize: 24, f64(0) + le32(Int32(100)) + le32(Int32(50)) + le32(Int32(200))
                     + le32(Int32(100)))
            + record(TrecCursor.scale, elementSize: 12, f64(0) + le32(UInt32(2)))
        let bytes = atom("ftyp", Array("qt  ".utf8) + be32(0)) + atom("moov", [UInt8](repeating: 0, count: 32))
            + atom("TSCR", Array("test".utf8)) + atom("TSCM", tscm)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-trec-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Rec.trec")
        try Data(bytes).write(to: url)
        return url
    }
}

@Suite struct TrecCursorTests {
    @Test func decodesCursorStreams() throws {
        let track = try #require(TrecCursor.load(try TrecBuilder.file(), duration: 2))
        // Region (100, 50, 200, 100) × 2 → 400×200 video px.
        #expect(track.videoSize == CGSize(width: 400, height: 200))
        #expect(track.sample(at: 0.2)?.position == CGPoint(x: 20, y: 20))   // before the first sample: the first
        #expect(track.sample(at: 0.7)?.position == CGPoint(x: 20, y: 20))
        #expect(track.sample(at: 1.5)?.position == CGPoint(x: 100, y: 60))
        let img = try #require(track.sample(at: 1)?.image)
        #expect(img.size == CGSize(width: 10, height: 20))
        #expect(img.hotspot == CGPoint(x: 3, y: 5))                         // hotY 15 from the bottom of 20
        #expect(CursorImageStore.shared.get(img.url) != nil)
        // Bit-flag buttons; the 256 marker and the absurd time are dropped.
        #expect(track.leftDowns == [0.9])
        #expect(track.clicks.count == 2)
    }

    @Test func decodesFormatOne() throws {
        let track = try #require(TrecCursor.load(try TrecBuilder.file(format: 1), duration: 2))
        #expect(track.sample(at: 1)?.image.hotspot == CGPoint(x: 3, y: 5))
    }

    /// Text records (window titles, device names) are never decoded: only the wanted numeric/image
    /// streams come out of the TSCM split, and nothing in the result holds their bytes.
    @Test func privateTextRecordsAreSkipped() throws {
        let url = try TrecBuilder.file()
        let body = try #require(TrecCursor.tscm(url))
        let wanted: Set<UInt32> = [TrecCursor.positions, TrecCursor.images, TrecCursor.buttons, TrecCursor.region,
                                   TrecCursor.scale]
        let streams = TrecCursor.streams(body, wanted: wanted)
        #expect(Set(streams.keys).isSubset(of: wanted))
        #expect(streams[0x2b7b_6afc] == nil)
        let secret = Data(TrecBuilder.secret.utf8)
        for (_, records) in streams { for r in records { #expect(r.payload.range(of: secret) == nil) } }
        let track = try #require(TrecCursor.load(url, duration: 2))
        for img in track.images.values {
            #expect(CursorImageStore.shared.get(img.url)?.range(of: secret) == nil)
        }
    }

    @Test func nonTrecFilesHaveNoCursor() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-trec-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("x.trec")
        try Data(TrecBuilder.atom("ftyp", Array("qt  ".utf8))).write(to: url)
        #expect(TrecCursor.load(url, duration: nil) == nil)
    }
}

@Suite struct CursorEffectEvaluateTests {
    @Test func clickScalingPulses() {
        let e = EffectInstance(name: "LeftClickScaling", parameters: ["scale": 3, "speed": 7.5], bypassed: false)
        let d = CursorEffects.Spec.clickPulseSpeedSeconds / 7.5
        #expect(CursorEffects.clickScale(e, leftDowns: [1], at: 0.5) == 1)
        #expect(approx(CursorEffects.clickScale(e, leftDowns: [1], at: 1 + d / 2), 3))
        #expect(approx(CursorEffects.clickScale(e, leftDowns: [1], at: 1 + d), 1))
        #expect(CursorEffects.clickScale(nil, leftDowns: [1], at: 1 + d / 2) == 1)
    }

    @Test func cursorEffectsAreNotClipEffects() {
        #expect(CursorEffects.isCursorEffect("CursorShadow") && CursorEffects.isCursorEffect("LeftClickScaling"))
        #expect(!CursorEffects.isCursorEffect("DropShadow"))
        let mapped = CursorEffects.layerEffects([
            EffectInstance(name: "CursorShadow", parameters: ["offset": 7], bypassed: false),
            EffectInstance(name: "CursorPhysics", parameters: [:], bypassed: false),
        ])
        #expect(mapped.map(\.name) == ["DropShadow"])
    }
}
