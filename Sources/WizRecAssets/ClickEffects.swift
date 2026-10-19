import CoreGraphics
import Foundation

/// A click animation drawn around the click point. Original WizRec artwork, procedural so
/// it can be tinted and rendered at any scale. The box is `size × size` pt, centred on the
/// click point.
public struct ClickEffectAsset: Sendable, Hashable, Identifiable {
    /// The animation's shape.
    public enum Style: String, Sendable, CaseIterable {
        /// One ring that expands and fades.
        case ring
        /// Two staggered rings.
        case ripple
        /// Eight short rays bursting outward.
        case burst
        /// A filled dot that shrinks and fades.
        case dot
    }

    /// Stable identifier, e.g. `ring`.
    public var id: String
    public var displayName: String
    public var style: Style
    /// Default tint.
    public var color: AssetColor
    /// Animation length, seconds.
    public var duration: Double
    /// Box edge, pt.
    public var size: Double = 96

    /// The frame at `progress` (0 = click, 1 = end; clamped) at `scale` px per pt, tinted with
    /// `tint` (default `color`). Fully transparent at progress 1.
    public func image(progress: Double, scale: Double = 2, tint: AssetColor? = nil) -> CGImage? {
        let p = min(max(progress, 0), 1)
        let c = tint ?? color
        let half = size / 2
        return Raster.draw(width: size, height: size, scale: scale) { ctx in
            let centre = CGPoint(x: half, y: half)
            func colour(_ alpha: Double) -> CGColor {
                CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha * max(alpha, 0))
            }
            func ring(_ q: Double) {
                guard q > 0, q < 1 else { return }
                let e = 1 - (1 - q) * (1 - q)   // ease out
                let r = 6 + (half - 6) * e
                ctx.setStrokeColor(colour(1 - q))
                ctx.setLineWidth(4 * (1 - q) + 1)
                ctx.strokeEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r))
            }
            switch style {
            case .ring:
                ring(p)
            case .ripple:
                ring(p * 1.4)
                ring(p * 1.4 - 0.4)
            case .burst:
                guard p < 1 else { return }
                let e = 1 - (1 - p) * (1 - p)
                ctx.setStrokeColor(colour(1 - p))
                ctx.setLineWidth(3)
                ctx.setLineCap(.round)
                for k in 0..<8 {
                    let a = Double(k) * .pi / 4
                    let r0 = 8 + (half - 20) * e, r1 = r0 + 12 * (1 - p) + 2
                    ctx.move(to: CGPoint(x: centre.x + r0 * cos(a), y: centre.y + r0 * sin(a)))
                    ctx.addLine(to: CGPoint(x: centre.x + r1 * cos(a), y: centre.y + r1 * sin(a)))
                }
                ctx.strokePath()
            case .dot:
                guard p < 1 else { return }
                let r = 18 * (1 - p)
                ctx.setFillColor(colour(0.8 * (1 - p)))
                ctx.fillEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r))
            }
        }
    }
}

enum BuiltInClickEffects {
    static let all: [ClickEffectAsset] = [
        ClickEffectAsset(id: "ring", displayName: "Ring", style: .ring,
                         color: AssetColor(hex: "FACC15") ?? AssetColor(1, 1, 0), duration: 0.45),
        ClickEffectAsset(id: "ripple", displayName: "Ripple", style: .ripple,
                         color: AssetColor(hex: "38BDF8") ?? AssetColor(0, 0.7, 1), duration: 0.6),
        ClickEffectAsset(id: "burst", displayName: "Burst", style: .burst,
                         color: AssetColor(hex: "F43F5E") ?? AssetColor(1, 0.2, 0.4), duration: 0.4),
        ClickEffectAsset(id: "dot", displayName: "Dot", style: .dot,
                         color: AssetColor(hex: "F43F5E") ?? AssetColor(1, 0.2, 0.4), duration: 0.35),
    ]
}
