import CoreVideo
import Foundation
import MediaEngine
import Testing
import TSCProjKit
import VideoToolbox
@testable import RenderEngine

/// GPU BT.709 4:2:0 output (`420v`/`420f`) for export.
@Suite(.enabled(if: hasGPU)) struct YUVOutputTests {
    private let s = P.rate
    static let v420 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    static let f420 = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

    /// Gradients, a rotated half-transparent layer and saturated colours.
    private func renderer() throws -> OfflineRenderer {
        let p = try P.project(tracks: [
            P.track(0, [P.clip("VMFile", id: 10, src: 1, start: 0, duration: s)]),
            P.track(1, [P.clip("VMFile", id: 11, src: 1, start: 0, duration: s, parameters: [
                "scale0": 0.4, "scale1": 0.4, "rotation2": 0.5, "opacity": 0.7, "translation0": 200.0,
            ])]),
        ], background: [250, 10, 30, 255])
        let src = GPUTest.frame(GPUTest.pixelBuffer(64, 36) { x, y in
            Px(r: x * 4, g: y * 7, b: (x * y) % 256, a: 255)
        })
        return OfflineRenderer(scene: P.scene(p), pool: MediaPool()) { _ in src }
    }

    /// BGRA bytes → reference 4:2:0 planes per the rules documented on `YUVOutput`.
    static func reference(bgra: [UInt8], w: Int, h: Int, fullRange: Bool) -> (y: [UInt8], c: [UInt8]) {
        func rgb(_ x: Int, _ y: Int) -> SIMD3<Double> {
            let i = (max(0, min(h - 1, y)) * w + max(0, min(w - 1, x))) * 4
            return SIMD3(Double(bgra[i + 2]), Double(bgra[i + 1]), Double(bgra[i])) / 255
        }
        func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
        func code(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        let (ys, yo, cs, co) = fullRange ? (1.0, 0.0, 1.0, 128.0 / 255) : (219.0 / 255, 16.0 / 255, 224.0 / 255, 128.0 / 255)
        var Y: [UInt8] = [], C: [UInt8] = []
        for y in 0..<h { for x in 0..<w { Y.append(code(yo + ys * luma(rgb(x, y)))) } }
        for cy in 0..<((h + 1) / 2) {
            for cx in 0..<((w + 1) / 2) {
                let x = 2 * cx, y = 2 * cy
                let m = (rgb(x - 1, y) + 2 * rgb(x, y) + rgb(x + 1, y)
                         + rgb(x - 1, y + 1) + 2 * rgb(x, y + 1) + rgb(x + 1, y + 1)) / 8
                let l = luma(m)
                C.append(code(co + cs * (m.z - l) / 1.8556))
                C.append(code(co + cs * (m.x - l) / 1.5748))
            }
        }
        return (Y, C)
    }

    static func maxDiff(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>) -> Int {
        zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    @Test(arguments: [(320, 180, false), (321, 181, false), (320, 180, true)])
    func matchesReferenceConversion(_ w: Int, _ h: Int, _ fullRange: Bool) async throws {
        let r = try renderer()
        nonisolated(unsafe) let bgra = try Buffers.make(w, h)
        nonisolated(unsafe) let yuv = try Buffers.make(w, h, format: fullRange ? Self.f420 : Self.v420)
        try await r.render(at: s / 2, into: bgra)
        try await r.render(at: s / 2, into: yuv)
        let ref = Self.reference(bgra: Buffers.bytes(bgra), w: w, h: h, fullRange: fullRange)
        let got = Buffers.bytes(yuv)
        #expect(got.count == ref.y.count + ref.c.count)
        #expect(Self.maxDiff(got.prefix(ref.y.count), ref.y[...]) <= 1, "luma")
        #expect(Self.maxDiff(got.dropFirst(ref.y.count), ref.c[...]) <= 1, "chroma")
    }

    /// Colours match what the encoder made of BT.709-tagged BGRA before (VideoToolbox's conversion).
    @Test func closeToVideoToolboxConversion() async throws {
        let (w, h) = (320, 180)
        let r = try renderer()
        nonisolated(unsafe) let bgra = try Buffers.make(w, h)
        nonisolated(unsafe) let ours = try Buffers.make(w, h, format: Self.v420)
        try await r.render(at: s / 2, into: bgra)
        try await r.render(at: s / 2, into: ours)
        for (k, v) in [(kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
                       (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
                       (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2)] {
            CVBufferSetAttachment(bgra, k, v, .shouldPropagate)
        }
        let vt = try Buffers.make(w, h, format: Self.v420)
        CVBufferSetAttachment(vt, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        let ts = try #require(session)
        defer { VTPixelTransferSessionInvalidate(ts) }
        #expect(VTPixelTransferSessionTransferImage(ts, from: bgra, to: vt) == noErr)
        let a = Buffers.bytes(ours), b = Buffers.bytes(vt)
        let n = w * h
        let lumaDiff = Self.maxDiff(a.prefix(n), b.prefix(n))
        let chromaDiff = Self.maxDiff(a.dropFirst(n), b.dropFirst(n))
        let ca = a.dropFirst(n), cb = b.dropFirst(n)
        let meanChroma = Double(zip(ca, cb).map { abs(Int($0) - Int($1)) }.reduce(0, +)) / Double(ca.count)
        print("YUV vs VideoToolbox: max luma diff \(lumaDiff), chroma max \(chromaDiff) mean \(meanChroma)")
        // Luma is per pixel and must agree; chroma filters differ only at hard edges.
        #expect(lumaDiff <= 1 && meanChroma < 1.5)
    }

    @Test func pipelineYUVMatchesSequential() async throws {
        let r = try renderer()
        let ticks = (0..<8).map { Int64($0) * s / 8 }
        var expected: [[UInt8]] = []
        for t in ticks {
            nonisolated(unsafe) let pb = try Buffers.make(256, 144, format: Self.v420)
            try await r.render(at: t, into: pb)
            expected.append(Buffers.bytes(pb))
        }
        let pipe = r.pipeline(ticks: ticks, maxInFlight: 4) { _ in try Buffers.make(256, 144, format: Self.v420) }
        var got: [[UInt8]] = []
        while let f = try await pipe.next() { got.append(Buffers.bytes(f.pixelBuffer)) }
        #expect(got == expected)
    }
}
