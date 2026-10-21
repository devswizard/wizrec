import CoreGraphics
import Foundation
import RenderEngine
import TSCProjKit

/// Where a selected clip sits on the canvas, for the on-canvas handles (ui-workflow.md §8, our
/// own design). Canvas px: origin at the canvas centre, +y up.
public struct CanvasFrame: Equatable, Sendable {
    /// The top-level clip the frame belongs to.
    public var clipID: Int64
    /// Natural size of the clip's layer, px before its transform (`Layer.size`).
    public var size: CGSize
    /// Layer-local px (origin at the layer centre, +y up) → canvas px.
    public var transform: CGAffineTransform
    /// Geometry crop, fractions of `size`.
    public var crop: Insets

    public init(clipID: Int64, size: CGSize, transform: CGAffineTransform, crop: Insets) {
        self.clipID = clipID; self.size = size; self.transform = transform; self.crop = crop
    }

    /// Corners of the visible (cropped) rectangle in canvas px: bottom-left, bottom-right,
    /// top-right, top-left.
    public var corners: [CGPoint] { Self.corners(size, crop).map { $0.applying(transform) } }
    /// Corners of the uncropped media in canvas px (same order), shown faintly in crop mode.
    public var fullCorners: [CGPoint] { Self.corners(size, .zero).map { $0.applying(transform) } }
    /// Midpoints of the cropped rectangle's left, top, right and bottom edges, canvas px.
    public var edgeMidpoints: [CanvasCropEdge: CGPoint] {
        let c = corners
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        return [.left: mid(c[0], c[3]), .top: mid(c[3], c[2]), .right: mid(c[1], c[2]), .bottom: mid(c[0], c[1])]
    }
    /// The layer's centre (its translation), canvas px: the pivot of scale and rotation.
    public var center: CGPoint { CGPoint.zero.applying(transform) }

    static func corners(_ s: CGSize, _ c: Insets) -> [CGPoint] {
        let w = s.width, h = s.height
        let l = -w / 2 + c.left * w, r = w / 2 - c.right * w
        let b = -h / 2 + c.bottom * h, t = h / 2 - c.top * h
        return [CGPoint(x: l, y: b), CGPoint(x: r, y: b), CGPoint(x: r, y: t), CGPoint(x: l, y: t)]
    }
}

/// One edge of the crop rectangle.
public enum CanvasCropEdge: String, CaseIterable, Sendable {
    case left, top, right, bottom

    /// The inspector field that edge's crop writes (`geometryCrop0…3`).
    public var field: InspectorField {
        switch self {
        case .left: .cropLeft
        case .top: .cropTop
        case .right: .cropRight
        case .bottom: .cropBottom
        }
    }
}

/// What a press on the canvas grabs: a selected clip's handle, or its body.
public enum CanvasHandle: Equatable, Sendable {
    /// Corner `index` (bottom-left, bottom-right, top-right, top-left): uniform scale about the centre.
    case corner(Int)
    /// The knob above the top edge: rotation about the centre.
    case rotate
    /// A crop-mode edge handle.
    case crop(CanvasCropEdge)
    /// Inside the clip: move.
    case body
}

/// Pure maths of the on-canvas handles: hit testing, and the parameter values a handle drag
/// produces. Values use project units (translation px, rotation radians, crop fractions).
public enum CanvasGeometry {
    /// Handle hit radius, view points.
    public static let handleRadius: Double = 7
    /// Distance of the rotation knob above the top edge, view points.
    public static let rotateKnobOffset: Double = 22

    /// The frame of top-level clip `clipID` in `plan` (its own layer, also inside a transition in
    /// progress); nil when it draws nothing at this time.
    @MainActor
    public static func frame(of clipID: Int64, plan: RenderPlan, project: Project) -> CanvasFrame? {
        func search(_ layers: [Layer], _ parent: CGAffineTransform) -> CanvasFrame? {
            for layer in layers.reversed() {
                if case .transition(_, let from, let to) = layer.content {
                    let t = layer.transform.concatenating(parent)
                    if let f = search([from, to].compactMap { $0 }, t) { return f }
                    continue
                }
                let id = CanvasHitTest.topLevelClip(forLayer: layer.clipID, in: project) ?? layer.clipID
                guard id == clipID, layer.size.width > 0, layer.size.height > 0 else { continue }
                return CanvasFrame(clipID: clipID, size: layer.size, transform: layer.transform.concatenating(parent),
                                   crop: layer.geometryCrop)
            }
            return nil
        }
        return search(plan.layers, .identity)
    }

    /// The clip's media size on the canvas at scale 1 (its layer's natural size), px.
    @MainActor
    public static func mediaSize(of clipID: Int64, plan: RenderPlan, project: Project) -> CGSize? {
        frame(of: clipID, plan: plan, project: project)?.size
    }

    /// Canvas px → view points (+y up, aspect-fit canvas centred in a view of `viewSize`).
    public static func viewPoint(_ p: CGPoint, viewSize: CGSize, canvasSize: CGSize) -> CGPoint {
        let s = CanvasHitTest.scale(viewSize: viewSize, canvasSize: canvasSize)
        return CGPoint(x: viewSize.width / 2 + p.x * s, y: viewSize.height / 2 + p.y * s)
    }

    /// View points (+y up) → canvas px, not limited to the canvas (drags may leave it).
    public static func canvasPoint(_ v: CGPoint, viewSize: CGSize, canvasSize: CGSize) -> CGPoint {
        let s = max(CanvasHitTest.scale(viewSize: viewSize, canvasSize: canvasSize), 1e-9)
        return CGPoint(x: (v.x - viewSize.width / 2) / s, y: (v.y - viewSize.height / 2) / s)
    }

    /// Where the rotation knob sits, view points: above the top edge's midpoint, along the
    /// clip's own "up".
    public static func rotateKnob(_ f: CanvasFrame, viewSize: CGSize, canvasSize: CGSize) -> CGPoint {
        let c = f.corners.map { viewPoint($0, viewSize: viewSize, canvasSize: canvasSize) }
        let top = CGPoint(x: (c[2].x + c[3].x) / 2, y: (c[2].y + c[3].y) / 2)
        let bottom = CGPoint(x: (c[0].x + c[1].x) / 2, y: (c[0].y + c[1].y) / 2)
        var dx = top.x - bottom.x, dy = top.y - bottom.y
        let len = hypot(dx, dy)
        if len < 1e-6 { (dx, dy) = (0, 1) } else { dx /= len; dy /= len }
        return CGPoint(x: top.x + dx * rotateKnobOffset, y: top.y + dy * rotateKnobOffset)
    }

    /// The handle under view point `v` (+y up) for frame `f`: crop edges in crop mode, else the
    /// rotation knob and the corners; then the body. Nil outside.
    public static func handle(at v: CGPoint, frame f: CanvasFrame, cropMode: Bool, viewSize: CGSize,
                              canvasSize: CGSize) -> CanvasHandle? {
        func near(_ p: CGPoint) -> Bool { hypot(p.x - v.x, p.y - v.y) <= handleRadius }
        if cropMode {
            for edge in CanvasCropEdge.allCases {
                if let m = f.edgeMidpoints[edge], near(viewPoint(m, viewSize: viewSize, canvasSize: canvasSize)) {
                    return .crop(edge)
                }
            }
        } else {
            if near(rotateKnob(f, viewSize: viewSize, canvasSize: canvasSize)) { return .rotate }
            for (i, c) in f.corners.enumerated() where near(viewPoint(c, viewSize: viewSize, canvasSize: canvasSize)) {
                return .corner(i)
            }
        }
        let p = canvasPoint(v, viewSize: viewSize, canvasSize: canvasSize)
        let local = p.applying(f.transform.inverted())
        let c = CanvasFrame.corners(f.size, f.crop)
        let inside = local.x >= c[0].x && local.x <= c[1].x && local.y >= c[0].y && local.y <= c[2].y
        return inside ? .body : nil
    }

    /// Scale after dragging a corner from `start` to `current` (canvas px): `scale0` times the
    /// ratio of their distances from `center`, at least 0.01, rounded to 1/1000.
    public static func scale(from scale0: Double, center: CGPoint, start: CGPoint, current: CGPoint) -> Double {
        let d0 = hypot(start.x - center.x, start.y - center.y)
        let d1 = hypot(current.x - center.x, current.y - center.y)
        guard d0 > 1e-6 else { return scale0 }
        return max(0.01, (scale0 * d1 / d0 * 1000).rounded() / 1000)
    }

    /// Rotation (radians, counter-clockwise positive as `rotation2`) after dragging the knob
    /// from `start` to `current` about `center`; `snap` rounds to 15° steps.
    public static func rotation(from rotation0: Double, center: CGPoint, start: CGPoint, current: CGPoint,
                                snap: Bool) -> Double {
        let a0 = atan2(start.y - center.y, start.x - center.x)
        let a1 = atan2(current.y - center.y, current.x - center.x)
        var r = rotation0 + (a1 - a0)
        while r > .pi { r -= 2 * .pi }
        while r < -.pi { r += 2 * .pi }
        if snap {
            let step = Double.pi / 12
            r = (r / step).rounded() * step
        }
        return (r * 1e6).rounded() / 1e6
    }

    /// Crop fraction of `edge` after dragging it from `start` to `current` (canvas px), clamped
    /// so the opposite edge keeps at least 1 % of the media. Rounded to 1/10000.
    public static func crop(_ edge: CanvasCropEdge, frame f: CanvasFrame, start: CGPoint, current: CGPoint) -> Double {
        let inv = f.transform.inverted()
        let a = start.applying(inv), b = current.applying(inv)
        let dx = (b.x - a.x) / max(f.size.width, 1e-9), dy = (b.y - a.y) / max(f.size.height, 1e-9)
        let c = f.crop
        let (value, opposite): (Double, Double) = switch edge {
        case .left: (c.left + dx, c.right)
        case .right: (c.right - dx, c.left)
        case .bottom: (c.bottom + dy, c.top)
        case .top: (c.top - dy, c.bottom)
        }
        let clamped = min(max(0, value), max(0, 0.99 - opposite))
        return (clamped * 10_000).rounded() / 10_000
    }
}
