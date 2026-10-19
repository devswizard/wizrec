import CoreMedia
import CoreVideo
import Foundation
import MediaEngine
import Testing
import TSCProjKit
@testable import RenderEngine

/// Output buffers and byte dumps shared by the pipeline and perf tests.
enum Buffers {
    static func make(_ w: Int, _ h: Int, format: OSType = kCVPixelFormatType_32BGRA) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferCreate(nil, w, h, format, attrs as CFDictionary, &pb)
        guard let pb else { throw RenderError.noMetalDevice }
        return pb
    }

    /// Every plane's visible bytes, row padding dropped.
    static func bytes(_ pb: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        var out: [UInt8] = []
        func copy(_ base: UnsafeMutableRawPointer?, rowBytes: Int, visible: Int, rows: Int) {
            guard let base else { return }
            for y in 0..<rows {
                out.append(contentsOf: UnsafeRawBufferPointer(start: base + y * rowBytes, count: visible))
            }
        }
        if CVPixelBufferIsPlanar(pb) {
            for p in 0..<CVPixelBufferGetPlaneCount(pb) {
                let w = CVPixelBufferGetWidthOfPlane(pb, p), h = CVPixelBufferGetHeightOfPlane(pb, p)
                let bpp = p == 0 ? 1 : 2
                copy(CVPixelBufferGetBaseAddressOfPlane(pb, p), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pb, p),
                     visible: w * bpp, rows: h)
            }
        } else {
            copy(CVPixelBufferGetBaseAddress(pb), rowBytes: CVPixelBufferGetBytesPerRow(pb),
                 visible: CVPixelBufferGetWidth(pb) * 4, rows: CVPixelBufferGetHeight(pb))
        }
        return out
    }
}

/// Records the order in which an injected frame source is asked for frames.
actor RequestLog {
    private(set) var times: [Int64] = []
    func add(_ t: CMTime) { times.append(t.value) }
}

/// `RenderPipeline` (pipelined export path) must equal the sequential path frame for frame.
@Suite(.enabled(if: hasGPU)) struct RenderPipelineTests {
    private let s = P.rate

    /// Two animated layers over a coloured background; source pixels depend on the media time.
    private func scene() throws -> SceneModel {
        let p = try P.project(tracks: [
            P.track(0, [P.clip("VMFile", id: 10, src: 1, start: 0, duration: s, parameters: [
                "translation0": P.keyframed(0, [(0, s, 300)]),
                "opacity": P.keyframed(1, [(0, s, 0.2)]),
            ])]),
            P.track(1, [P.clip("VMFile", id: 11, src: 1, start: s / 4, duration: s / 2, mediaStart: s / 2, parameters: [
                "scale0": 0.3, "scale1": 0.3, "rotation2": P.keyframed(0, [(s / 2, s, 1.2)]),
            ])]),
        ], background: [10, 20, 200, 255])
        return P.scene(p)
    }

    /// A 64×36 source whose colours encode the requested media time.
    private static func source(_ r: FrameRequest) -> VideoFrame {
        let k = Int(r.time.seconds * 30) % 200
        return GPUTest.frame(GPUTest.pixelBuffer(64, 36) { x, y in Px(r: (x * 4 + k) % 256, g: y * 7, b: 255 - k, a: 255) })
    }

    private func frameTicks(_ n: Int) -> [Int64] { (0..<n).map { Int64($0) * s / Int64(n) } }

    /// Sequential reference: one `render(at:into:)` at a time.
    private static func sequential(_ r: OfflineRenderer, _ ticks: [Int64], _ w: Int, _ h: Int,
                                   format: OSType = kCVPixelFormatType_32BGRA) async throws -> [[UInt8]] {
        var out: [[UInt8]] = []
        for t in ticks {
            nonisolated(unsafe) let pb = try Buffers.make(w, h, format: format)
            try await r.render(at: t, into: pb)
            out.append(Buffers.bytes(pb))
        }
        return out
    }

    private static func pipelined(_ r: OfflineRenderer, _ ticks: [Int64], _ w: Int, _ h: Int, depth: Int,
                                  format: OSType = kCVPixelFormatType_32BGRA) async throws -> [[UInt8]] {
        let pipe = r.pipeline(ticks: ticks, maxInFlight: depth) { _ in try Buffers.make(w, h, format: format) }
        var out: [[UInt8]] = []
        while let f = try await pipe.next() {
            #expect(f.index == out.count && f.ticks == ticks[f.index])
            out.append(Buffers.bytes(f.pixelBuffer))
        }
        return out
    }

    @Test(arguments: [1, 3, 8]) func matchesSequential(_ depth: Int) async throws {
        let renderer = OfflineRenderer(scene: try scene(), pool: MediaPool()) { Self.source($0) }
        let ticks = frameTicks(24)
        let expected = try await Self.sequential(renderer, ticks, 320, 180)
        let got = try await Self.pipelined(renderer, ticks, 320, 180, depth: depth)
        #expect(got.count == expected.count)
        for i in 0..<min(got.count, expected.count) { #expect(got[i] == expected[i], "frame \(i)") }
        // Frames differ over time, so an out-of-order delivery would be caught.
        #expect(Set(expected).count > ticks.count / 2)
    }

    /// The checked-in demo project (media absent: shader fallback, callouts, cursor-free layers).
    @Test func demoFixtureMatchesSequential() async throws {
        let project = try Project(data: Data(contentsOf: try fixtureURL("demo.tscproj")))
        let scene = P.scene(project)
        let renderer = OfflineRenderer(scene: scene, pool: MediaPool())
        let ticks = (0..<20).map { Int64($0) * scene.duration / 20 }
        let expected = try await Self.sequential(renderer, ticks, 480, 270)
        let got = try await Self.pipelined(renderer, ticks, 480, 270, depth: 6)
        #expect(got == expected)
    }

    /// Fetches run in frame order even with many frames in flight (decoders never seek back).
    @Test func fetchesInFrameOrder() async throws {
        let p = try P.project(tracks: [P.track(0, [P.clip("VMFile", id: 10, src: 1, start: 0, duration: s)])])
        let log = RequestLog()
        let renderer = OfflineRenderer(scene: P.scene(p), pool: MediaPool()) { r in
            await log.add(r.time)
            try await Task.sleep(nanoseconds: UInt64.random(in: 0...2_000_000))
            return Self.source(r)
        }
        let ticks = frameTicks(30)
        let pipe = renderer.pipeline(ticks: ticks, maxInFlight: 8) { _ in try Buffers.make(64, 36) }
        var n = 0
        while try await pipe.next() != nil { n += 1 }
        #expect(n == 30)
        let times = await log.times
        #expect(times.count == 30 && times == times.sorted())
    }

    @Test func errorEndsPipelineAfterEarlierFrames() async throws {
        let p = try P.project(tracks: [P.track(0, [P.clip("VMFile", id: 10, src: 1, start: 0, duration: s)])])
        let bad = s * 5 / 10
        let renderer = OfflineRenderer(scene: P.scene(p), pool: MediaPool()) { r in
            if r.time.value == bad { throw MediaError.decodeFailed("boom") }
            return Self.source(r)
        }
        let pipe = renderer.pipeline(ticks: frameTicks(10), maxInFlight: 4) { _ in try Buffers.make(32, 18) }
        var delivered: [Int] = []
        await #expect(throws: MediaError.self) {
            while let f = try await pipe.next() { delivered.append(f.index) }
        }
        #expect(delivered == [0, 1, 2, 3, 4])
        #expect(try await pipe.next() == nil)
    }

    @Test func cancelStops() async throws {
        let renderer = OfflineRenderer(scene: try scene(), pool: MediaPool()) { Self.source($0) }
        let pipe = renderer.pipeline(ticks: frameTicks(10), maxInFlight: 3) { _ in try Buffers.make(32, 18) }
        #expect(try await pipe.next()?.index == 0)
        await pipe.cancel()
        #expect(try await pipe.next() == nil)
    }

    @Test func emptyTicks() async throws {
        let renderer = OfflineRenderer(scene: try scene(), pool: MediaPool()) { Self.source($0) }
        let pipe = renderer.pipeline(ticks: [], maxInFlight: 3) { _ in try Buffers.make(32, 18) }
        #expect(try await pipe.next() == nil)
    }
}
