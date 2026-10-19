import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A cursor image, drawn as vectors so it is sharp at any scale. Original WizRec artwork.
/// Geometry is in points of a `width × height` box with a top-left origin, y down.
public struct CursorAsset: Sendable, Hashable, Identifiable {
    /// Stable identifier, e.g. `arrow`, `hand`, `ibeam`.
    public var id: String
    public var displayName: String
    /// Box size, pt.
    public var width: Double = 32
    public var height: Double = 32
    /// The click point, pt from the top-left of the box (y down).
    public var hotspot: SIMD2<Double>
    let art: CursorArt

    /// The cursor rendered at `scale` px per pt (sRGB, premultiplied RGBA). Nil only if
    /// CoreGraphics cannot allocate the bitmap.
    public func image(scale: Double = 2) -> CGImage? {
        Raster.draw(width: width, height: height, scale: scale) { ctx in art.draw(ctx) }
    }

    /// `image(scale:)` as PNG bytes (for `CursorOverlay.image` files and exports).
    public func pngData(scale: Double = 2) -> Data? { image(scale: scale).flatMap(Raster.png) }
}

/// The drawing of one built-in cursor.
enum CursorArt: String, Sendable, Hashable {
    case arrow, arrowLight, hand, ibeam, crosshair

    private static let ink = CGColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)
    private static let paper = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    func draw(_ ctx: CGContext) {
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        switch self {
        case .arrow, .arrowLight:
            let p = CGMutablePath()
            p.addLines(between: [CGPoint(x: 4, y: 2), CGPoint(x: 4, y: 24), CGPoint(x: 9.5, y: 19),
                                 CGPoint(x: 13, y: 27.5), CGPoint(x: 16.5, y: 26), CGPoint(x: 13, y: 17.8),
                                 CGPoint(x: 20, y: 17.8)])
            p.closeSubpath()
            let (fill, edge) = self == .arrow ? (Self.ink, Self.paper) : (Self.paper, Self.ink)
            outlined(ctx, p, fill: fill, edge: edge, width: 2.5)
        case .hand:
            let p = CGMutablePath()
            p.addRoundedRect(in: CGRect(x: 10, y: 2, width: 6, height: 17), cornerWidth: 3, cornerHeight: 3)
            p.addRoundedRect(in: CGRect(x: 15.5, y: 10, width: 5, height: 10), cornerWidth: 2.5, cornerHeight: 2.5)
            p.addRoundedRect(in: CGRect(x: 20, y: 11.5, width: 5, height: 10), cornerWidth: 2.5, cornerHeight: 2.5)
            p.addRoundedRect(in: CGRect(x: 4.5, y: 14, width: 7, height: 5), cornerWidth: 2.5, cornerHeight: 2.5)
            p.addRoundedRect(in: CGRect(x: 8, y: 14.5, width: 17, height: 14), cornerWidth: 5, cornerHeight: 5)
            // The fill covers the inner halves of the overlapping outlines: one silhouette remains.
            outlined(ctx, p, fill: Self.paper, edge: Self.ink, width: 2)
            // Knuckle creases.
            ctx.setStrokeColor(Self.ink); ctx.setLineWidth(1.2)
            for x in [15.7, 20.2] {
                ctx.move(to: CGPoint(x: x, y: 13)); ctx.addLine(to: CGPoint(x: x, y: 18))
            }
            ctx.strokePath()
        case .ibeam:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 12, y: 5)); p.addQuadCurve(to: CGPoint(x: 16, y: 7), control: CGPoint(x: 15, y: 5))
            p.addQuadCurve(to: CGPoint(x: 20, y: 5), control: CGPoint(x: 17, y: 5))
            p.move(to: CGPoint(x: 16, y: 7)); p.addLine(to: CGPoint(x: 16, y: 25))
            p.move(to: CGPoint(x: 12, y: 27)); p.addQuadCurve(to: CGPoint(x: 16, y: 25), control: CGPoint(x: 15, y: 27))
            p.addQuadCurve(to: CGPoint(x: 20, y: 27), control: CGPoint(x: 17, y: 27))
            p.move(to: CGPoint(x: 13.5, y: 16)); p.addLine(to: CGPoint(x: 18.5, y: 16))
            stroked(ctx, p, width: 1.6)
        case .crosshair:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 16, y: 3)); p.addLine(to: CGPoint(x: 16, y: 12))
            p.move(to: CGPoint(x: 16, y: 20)); p.addLine(to: CGPoint(x: 16, y: 29))
            p.move(to: CGPoint(x: 3, y: 16)); p.addLine(to: CGPoint(x: 12, y: 16))
            p.move(to: CGPoint(x: 20, y: 16)); p.addLine(to: CGPoint(x: 29, y: 16))
            p.addEllipse(in: CGRect(x: 14.5, y: 14.5, width: 3, height: 3))
            stroked(ctx, p, width: 1.6)
        }
    }

    /// Edge colour stroked behind, then the fill: a crisp outline that reads on any background.
    private func outlined(_ ctx: CGContext, _ p: CGPath, fill: CGColor, edge: CGColor, width: Double) {
        ctx.addPath(p); ctx.setStrokeColor(edge); ctx.setLineWidth(width * 2); ctx.strokePath()
        ctx.addPath(p); ctx.setFillColor(fill); ctx.fillPath()
    }

    /// A light halo stroke under a dark line (for line-art cursors).
    private func stroked(_ ctx: CGContext, _ p: CGPath, width: Double) {
        ctx.addPath(p); ctx.setStrokeColor(Self.paper); ctx.setLineWidth(width + 2.4); ctx.strokePath()
        ctx.addPath(p); ctx.setStrokeColor(Self.ink); ctx.setLineWidth(width); ctx.strokePath()
    }
}

enum BuiltInCursors {
    static let all: [CursorAsset] = [
        CursorAsset(id: "arrow", displayName: "Arrow", hotspot: SIMD2(4, 2), art: .arrow),
        CursorAsset(id: "arrow-light", displayName: "Arrow (Light)", hotspot: SIMD2(4, 2), art: .arrowLight),
        CursorAsset(id: "hand", displayName: "Pointing Hand", hotspot: SIMD2(13, 2), art: .hand),
        CursorAsset(id: "ibeam", displayName: "Text (I-Beam)", hotspot: SIMD2(16, 16), art: .ibeam),
        CursorAsset(id: "crosshair", displayName: "Crosshair", hotspot: SIMD2(16, 16), art: .crosshair),
    ]
}

/// Offscreen CoreGraphics drawing in a top-left, y-down point space.
enum Raster {
    static func draw(width: Double, height: Double, scale: Double, _ body: (CGContext) -> Void) -> CGImage? {
        let w = max(Int((width * scale).rounded()), 1), h = max(Int((height * scale).rounded()), 1)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        ctx.setShouldAntialias(true)
        body(ctx)
        return ctx.makeImage()
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
