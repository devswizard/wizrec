import CoreGraphics
import Foundation
import Testing
@testable import RenderEngine

/// Clip geometry keys per `docs/specs/transform.md` (§1, §4, §11).
struct TransformConventionTests {
    private func params(_ v: [String: Double]) -> SParams {
        var p = SParams()
        for (k, x) in v.sorted(by: { $0.key < $1.key }) { p.names.append(k); p.values[k] = SParam(base: x) }
        return p
    }

    private func apply(_ v: [String: Double], _ pt: CGPoint) -> CGPoint {
        pt.applying(Conventions.transform(params(v), at: 0))
    }

    private func close(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9 }

    @Test func missingKeysAreIdentity() {
        #expect(Conventions.transform(params([:]), at: 0) == .identity)
    }

    @Test func positiveRotation2IsCounterClockwiseInYUpSpace() {
        // +π/2 (Rotation Z +90°, same sign in the file [obs]) turns +x into +y (up).
        #expect(close(apply(["rotation2": .pi / 2], CGPoint(x: 1, y: 0)), CGPoint(x: 0, y: 1)))
        #expect(close(apply(["rotation2": .pi / 6, "translation0": 10], CGPoint(x: 0, y: 0)), CGPoint(x: 10, y: 0)))
    }

    @Test func rotationYAndXForeshortenOrthographically() {
        // Tilt Left/Right animate rotation1 to ±π/6 [obs]: width × cos, sign-independent.
        let a = apply(["rotation1": .pi / 3], CGPoint(x: 100, y: 50))
        #expect(close(a, CGPoint(x: 50, y: 50)))
        #expect(close(apply(["rotation1": -.pi / 3], CGPoint(x: 100, y: 50)), a))
        #expect(close(apply(["rotation0": .pi / 3, "scale1": 2], CGPoint(x: 100, y: 50)), CGPoint(x: 100, y: 50)))
    }

    @Test func shear0IsDegreesAlongX() {
        #expect(close(apply(["shear0": 45], CGPoint(x: 0, y: 10)), CGPoint(x: 10, y: 10)))
        #expect(close(apply(["shear0": 45, "scale0": 2, "scale1": 2], CGPoint(x: 0, y: 5)), CGPoint(x: 10, y: 10)))
        // Clamped short of 90°: finite.
        let p = apply(["shear0": 90], CGPoint(x: 0, y: 1))
        #expect(p.x.isFinite && p.x > 50)
    }

    @Test func transformKeysCoverTheNewGeometryKeys() {
        #expect(Set(Conventions.transformKeys).isSuperset(of: ["rotation0", "rotation1", "rotation2", "shear0"]))
    }
}
