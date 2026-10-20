import CoreGraphics
import CoreVideo
import Foundation
import MediaEngine
import Testing
import TSCProjKit
@testable import RenderEngine

/// `OfflineRenderer.render(at:into:)` (export hot path) must match `image(at:size:)` pixel for pixel.
@Suite(.enabled(if: hasGPU)) struct RenderIntoBufferTests {
    private let s = P.rate

    private func scene() throws -> SceneModel {
        let p = try P.project(tracks: [
            P.track(0, [P.clip("VMFile", id: 10, src: 1, start: 0, duration: s)]),
            P.track(1, [P.clip("VMFile", id: 11, src: 1, start: 0, duration: s, parameters: [
                "scale0": 0.25, "scale1": 0.25, "translation0": 480.0, "rotation2": 0.3, "opacity": 0.6,
            ])]),
        ], background: [10, 20, 200, 255])
        return P.scene(p)
    }

    private static func outputBuffer(_ w: Int, _ h: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let pb else { throw RenderError.noMetalDevice }
        return pb
    }

    private static func bytes(_ pb: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), rb = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return [] }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { memcpy(&out[y * w * 4], base + y * rb, w * 4) }
        return out
    }

    private static func bytes(_ img: CGImage) -> [UInt8] {
        guard let data = img.dataProvider?.data as Data? else { return [] }
        let w = img.width, rb = img.bytesPerRow
        var out = [UInt8](repeating: 0, count: w * img.height * 4)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for y in 0..<img.height {
                for i in 0..<(w * 4) { out[y * w * 4 + i] = raw[y * rb + i] }
            }
        }
        return out
    }

    private static func source() -> VideoFrame {
        GPUTest.frame(GPUTest.pixelBuffer(64, 36) { x, y in Px(r: x * 4, g: y * 7, b: 99, a: 255) })
    }

    @Test func matchesImageAt() async throws {
        let src = Self.source()
        let renderer = OfflineRenderer(scene: try scene(), pool: MediaPool()) { _ in src }
        for (w, h) in [(1920, 1080), (640, 360), (300, 300)] {
            let img = try await renderer.image(at: s / 3, size: CGSize(width: w, height: h))
            // The buffer is not touched while the render is in flight.
            nonisolated(unsafe) let pb = try Self.outputBuffer(w, h)
            try await renderer.render(at: s / 3, into: pb)
            #expect(Self.bytes(pb) == Self.bytes(img), "\(w)×\(h)")
        }
    }

    @Test func overlappingCallsAreIndependent() async throws {
        let src = Self.source()
        let renderer = OfflineRenderer(scene: try scene(), pool: MediaPool()) { _ in src }
        let times: [Int64] = [0, s / 4, s / 2, 3 * s / 4, 2 * s]
        var expected: [[UInt8]] = []
        for t in times {
            expected.append(Self.bytes(try await renderer.image(at: t, size: CGSize(width: 320, height: 180))))
        }
        let got = try await withThrowingTaskGroup(of: (Int, [UInt8]).self) { g in
            for (i, t) in times.enumerated() {
                g.addTask {
                    nonisolated(unsafe) let pb = try Self.outputBuffer(320, 180)
                    try await renderer.render(at: t, into: pb)
                    return (i, Self.bytes(pb))
                }
            }
            var out = [[UInt8]](repeating: [], count: times.count)
            for try await (i, b) in g { out[i] = b }
            return out
        }
        #expect(got == expected)
    }

    @Test func rejectsUnsupportedBuffers() async throws {
        let src = Self.source()
        let renderer = OfflineRenderer(scene: try scene(), pool: MediaPool()) { _ in src }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
        nonisolated(unsafe) let noSurface = try #require(pb)  // 4:2:0 is supported, but not without IOSurface
        await #expect(throws: RenderError.self) { try await renderer.render(at: 0, into: noSurface) }
        nonisolated(unsafe) let half = try Buffers.make(16, 16, format: kCVPixelFormatType_64RGBAHalf)
        await #expect(throws: RenderError.self) { try await renderer.render(at: 0, into: half) }
    }
}
