import CoreGraphics
import Foundation
import RenderEngine
import Testing
@testable import PlayerKit

/// On-canvas handles (APP15-1a): hit testing and the values handle drags produce.
@Suite struct CanvasGeometryTests {
    /// A 400×200 px clip at (100, 50), scale 0.5, on a 1920×1080 canvas.
    let frame = CanvasFrame(clipID: 7, size: CGSize(width: 400, height: 200),
                            transform: CGAffineTransform(scaleX: 0.5, y: 0.5).concatenating(CGAffineTransform(translationX: 100, y: 50)),
                            crop: .zero)
    let canvas = CGSize(width: 1920, height: 1080)
    /// View at half the canvas size: 1 view point = 2 canvas px.
    let view = CGSize(width: 960, height: 540)

    @Test func cornersCenterAndViewMapping() {
        #expect(frame.center == CGPoint(x: 100, y: 50))
        #expect(frame.corners == [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0), CGPoint(x: 200, y: 100), CGPoint(x: 0, y: 100)])
        let v = CanvasGeometry.viewPoint(CGPoint(x: 200, y: 100), viewSize: view, canvasSize: canvas)
        #expect(v == CGPoint(x: 580, y: 320))
        #expect(CanvasGeometry.canvasPoint(v, viewSize: view, canvasSize: canvas) == CGPoint(x: 200, y: 100))
        var cropped = frame
        cropped.crop = Insets(left: 0.25, top: 0, right: 0, bottom: 0.5)
        #expect(cropped.corners.first == CGPoint(x: 50, y: 50))
        #expect(cropped.fullCorners == frame.corners)
    }

    @Test func handlesAreHitByProximity() {
        func at(_ canvasPoint: CGPoint, dx: Double = 0, crop: Bool = false) -> CanvasHandle? {
            var v = CanvasGeometry.viewPoint(canvasPoint, viewSize: view, canvasSize: canvas)
            v.x += dx
            return CanvasGeometry.handle(at: v, frame: frame, cropMode: crop, viewSize: view, canvasSize: canvas)
        }
        #expect(at(CGPoint(x: 200, y: 100)) == .corner(2))
        #expect(at(CGPoint(x: 0, y: 0), dx: 5) == .corner(0))
        #expect(at(CGPoint(x: 100, y: 50)) == .body)
        #expect(at(CGPoint(x: 500, y: 50)) == nil)
        let knob = CanvasGeometry.rotateKnob(frame, viewSize: view, canvasSize: canvas)
        #expect(knob == CGPoint(x: 530, y: 320 + CanvasGeometry.rotateKnobOffset))
        #expect(CanvasGeometry.handle(at: knob, frame: frame, cropMode: false, viewSize: view, canvasSize: canvas) == .rotate)
        // Crop mode: edge handles instead of corners and knob.
        #expect(at(CGPoint(x: 0, y: 50), crop: true) == .crop(.left))
        #expect(at(CGPoint(x: 100, y: 100), crop: true) == .crop(.top))
        #expect(at(CGPoint(x: 200, y: 100), crop: true) == .body)
        #expect(CanvasGeometry.handle(at: knob, frame: frame, cropMode: true, viewSize: view, canvasSize: canvas) == nil)
    }

    @Test func cornerDragScalesAboutTheCentre() {
        // The corner 2× as far from the centre doubles the scale.
        #expect(CanvasGeometry.scale(from: 0.5, center: CGPoint(x: 100, y: 50), start: CGPoint(x: 200, y: 100),
                                     current: CGPoint(x: 300, y: 150)) == 1)
        #expect(CanvasGeometry.scale(from: 0.5, center: .zero, start: CGPoint(x: 10, y: 0), current: .zero) == 0.01)
        #expect(CanvasGeometry.scale(from: 0.8, center: .zero, start: .zero, current: CGPoint(x: 5, y: 5)) == 0.8)
    }

    @Test func knobDragRotatesCounterClockwisePositive() {
        let r = CanvasGeometry.rotation(from: 0, center: .zero, start: CGPoint(x: 0, y: 10), current: CGPoint(x: -10, y: 0),
                                        snap: false)
        #expect(abs(r - .pi / 2) < 1e-6)
        let snapped = CanvasGeometry.rotation(from: 0, center: .zero, start: CGPoint(x: 10, y: 0),
                                              current: CGPoint(x: 10, y: 1.9), snap: true)
        #expect(abs(snapped - .pi / 12) < 1e-6)
        let wrapped = CanvasGeometry.rotation(from: 3, center: .zero, start: CGPoint(x: 10, y: 0), current: CGPoint(x: 0, y: 10),
                                              snap: false)
        #expect(wrapped > -Double.pi && wrapped < 0)
    }

    @Test func edgeDragCropsInMediaFractions() {
        // 50 canvas px right on a 400 px wide media at scale 0.5 = 100 media px = 0.25.
        #expect(CanvasGeometry.crop(.left, frame: frame, start: CGPoint(x: 0, y: 50), current: CGPoint(x: 50, y: 50)) == 0.25)
        #expect(CanvasGeometry.crop(.right, frame: frame, start: CGPoint(x: 200, y: 50), current: CGPoint(x: 150, y: 50)) == 0.25)
        #expect(CanvasGeometry.crop(.top, frame: frame, start: CGPoint(x: 100, y: 100), current: CGPoint(x: 100, y: 75)) == 0.25)
        #expect(CanvasGeometry.crop(.bottom, frame: frame, start: CGPoint(x: 100, y: 0), current: CGPoint(x: 100, y: 25)) == 0.25)
        // Never past the opposite edge, never negative.
        var f = frame
        f.crop = Insets(left: 0, top: 0, right: 0.5, bottom: 0)
        #expect(CanvasGeometry.crop(.left, frame: f, start: .zero, current: CGPoint(x: 500, y: 0)) == 0.49)
        #expect(CanvasGeometry.crop(.left, frame: frame, start: .zero, current: CGPoint(x: -50, y: 0)) == 0)
        // Rotated 90°: dragging up in canvas space is "right" in media space.
        var r = frame
        r.transform = CGAffineTransform(rotationAngle: .pi / 2)
        #expect(CanvasGeometry.crop(.left, frame: r, start: .zero, current: CGPoint(x: 0, y: 40)) == 0.1)
    }

    @Test func cropEdgesWriteTheirInspectorFields() {
        #expect(CanvasCropEdge.allCases.map(\.field) == [.cropLeft, .cropTop, .cropRight, .cropBottom])
        #expect(CanvasCropEdge.allCases.map { $0.field.keys } == [["geometryCrop0"], ["geometryCrop1"], ["geometryCrop2"], ["geometryCrop3"]])
    }
}
