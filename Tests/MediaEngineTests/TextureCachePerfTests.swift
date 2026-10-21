// MED15-1: what making Metal textures straight from IOSurfaces each frame (`LockedTextureCache`)
// costs in 4K60 HDR playback. Opt-in, release build:
//
//   WIZREC_PERF=1 swift test -c release -Xswiftc -enable-testing --filter TextureCachePerf
//
// The loop mirrors playback of a 4K HDR10 clip on the GPU lane: a decoder surface (P010, from a
// small ring of surfaces as a decoder pool hands them out) is tone-mapped into a BGRA pool
// buffer (3 textures, `MetalToneMapper.convert` waits), then the compositor wraps that BGRA
// buffer (1 texture) and reads it on the GPU in its own command buffer. "fresh" makes the four
// textures every frame, as the code does; "reused" makes each once per IOSurface (what a reuse
// cache keyed by surface ID would do) and runs the same GPU work. Rounds alternate to cancel
// drift. Synthetic pictures only.

import CFFmpeg
import CoreVideo
import Foundation
import IOSurface
import Metal
import Testing
import WizRecTestSupport
@testable import MediaEngine

@Suite(.enabled(if: ProcessInfo.processInfo.environment["WIZREC_PERF"] == "1" && MetalToneMapper.shared != nil,
                "set WIZREC_PERF=1 (needs Metal)"),
       .serialized)
struct TextureCachePerfTests {
    static let width = 3840, height = 2160
    /// Surfaces a decoder pool cycles through, and output frames kept alive (frame cache, display).
    static let sourceRing = 6, keptOutputs = 3
    static let frames = 240, rounds = 4

    /// Timing of one loop variant, per frame.
    struct Sample {
        var wallMs: [Double] = []
        var gpuMs: [Double] = []
        var cpuEncodeMs: [Double] = []
    }

    /// The textures one frame needs: Y, CbCr, tone-map output (Uint view) and compositor input.
    final class Frame {
        let y: any MTLTexture, c: any MTLTexture, out: any MTLTexture, composite: any MTLTexture
        let keep: [CacheTexture]
        init(y: any MTLTexture, c: any MTLTexture, out: any MTLTexture, composite: any MTLTexture,
             keep: [CacheTexture]) {
            (self.y, self.c, self.out, self.composite, self.keep) = (y, c, out, composite, keep)
        }
    }

    final class Rig {
        let mapper: MetalToneMapper
        let gpu: MetalToneMapper.GPU
        let factory: LockedTextureCache
        let sources: [CVPixelBuffer]
        let pool: BGRAPool
        let target: any MTLTexture
        let layout: (depth: Int, cw: Int, ch: Int)
        /// "reused" variant: textures per IOSurface ID, plane and format (bounded by the pools).
        var memo: [String: any MTLTexture] = [:]

        init() throws {
            let tm = ToneMapper(transfer: .pq, colorSpace: AVCOL_SPC_BT2020_NCL, primaries: AVCOL_PRI_BT2020,
                                fullRange: false)
            mapper = try #require(MetalToneMapper(tm))
            gpu = try #require(MetalToneMapper.shared)
            factory = try #require(LockedTextureCache(device: gpu.device))
            let fmt = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            layout = try #require(ToneMapper.layout(fmt))
            sources = try (0..<TextureCachePerfTests.sourceRing).map { (i: Int) throws -> CVPixelBuffer in
                try HDRPicture.make(fmt, TextureCachePerfTests.width, TextureCachePerfTests.height,
                                    seed: UInt64(i + 1))
            }
            pool = try BGRAPool(width: TextureCachePerfTests.width, height: TextureCachePerfTests.height)
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                             width: TextureCachePerfTests.width,
                                                             height: TextureCachePerfTests.height, mipmapped: false)
            d.storageMode = .private
            d.usage = [.shaderRead, .renderTarget]
            target = try #require(gpu.device.makeTexture(descriptor: d))
        }

        func wrap(_ b: CVPixelBuffer, _ plane: Int, _ f: MTLPixelFormat) throws -> CacheTexture {
            let w = CVPixelBufferGetWidthOfPlane(b, plane), h = CVPixelBufferGetHeightOfPlane(b, plane)
            return try #require(factory.texture(b, format: f, width: w, height: h, plane: plane))
        }

        func fresh(_ src: CVPixelBuffer, _ dst: CVPixelBuffer) throws -> Frame {
            let y = try wrap(src, 0, .r16Uint), c = try wrap(src, 1, .rg16Uint)
            let o = try wrap(dst, 0, .rgba8Uint), k = try wrap(dst, 0, .bgra8Unorm)
            return Frame(y: y.texture, c: c.texture, out: o.texture, composite: k.texture, keep: [y, c, o, k])
        }

        func reused(_ src: CVPixelBuffer, _ dst: CVPixelBuffer) throws -> Frame {
            func get(_ b: CVPixelBuffer, _ plane: Int, _ f: MTLPixelFormat) throws -> any MTLTexture {
                let s = try #require(CVPixelBufferGetIOSurface(b)?.takeUnretainedValue())
                let key = "\(IOSurfaceGetID(s))/\(plane)/\(f.rawValue)"
                if let t = memo[key] { return t }
                let t = try wrap(b, plane, f).texture
                memo[key] = t
                return t
            }
            return Frame(y: try get(src, 0, .r16Uint), c: try get(src, 1, .rg16Uint),
                         out: try get(dst, 0, .rgba8Uint), composite: try get(dst, 0, .bgra8Unorm), keep: [])
        }

        /// One playback-like run of `frames` frames; per-frame times appended to `sample`.
        func run(reuse: Bool, frames: Int, into sample: inout Sample) throws {
            var outputs: [CVPixelBuffer] = []
            let w = TextureCachePerfTests.width, h = TextureCachePerfTests.height
            let cw = CVPixelBufferGetWidthOfPlane(sources[0], 1), ch = CVPixelBufferGetHeightOfPlane(sources[0], 1)
            for i in 0..<frames {
                let t0 = DispatchTime.now().uptimeNanoseconds
                let src = sources[i % sources.count]
                let dst = try pool.make()
                let f = try reuse ? reused(src, dst) : fresh(src, dst)
                let tone = try #require(gpu.queue.makeCommandBuffer())
                try mapper.encodeKernel(y: f.y, chroma: f.c, out: f.out, width: w, height: h, chromaWidth: cw,
                                        chromaHeight: ch, layout: layout, commandBuffer: tone)
                let comp = try #require(gpu.queue.makeCommandBuffer())
                let blit = try #require(comp.makeBlitCommandEncoder())
                blit.copy(from: f.composite, to: target)
                blit.endEncoding()
                let t1 = DispatchTime.now().uptimeNanoseconds
                tone.commit()
                tone.waitUntilCompleted() // as `MetalToneMapper.convert`
                comp.commit()
                comp.waitUntilCompleted()
                let t2 = DispatchTime.now().uptimeNanoseconds
                withExtendedLifetime(f) {}
                outputs.append(dst)
                if outputs.count > TextureCachePerfTests.keptOutputs { outputs.removeFirst() }
                sample.wallMs.append(Double(t2 - t0) / 1e6)
                sample.cpuEncodeMs.append(Double(t1 - t0) / 1e6)
                let g = (tone.gpuEndTime - tone.gpuStartTime) + (comp.gpuEndTime - comp.gpuStartTime)
                sample.gpuMs.append(g * 1000)
            }
        }
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }

    static func p95(_ v: [Double]) -> Double {
        let s = v.sorted()
        return s.isEmpty ? 0 : s[min(s.count - 1, s.count * 95 / 100)]
    }

    static func fmt(_ v: Double, _ digits: Int = 3) -> String { String(format: "%.\(digits)f", v) }

    /// 4K60 HDR playback-like loop: per-frame cost of fresh vs reused IOSurface textures.
    @Test func playbackLoop4KHDR() throws {
        let rig = try Rig()
        var warm = Sample()
        try rig.run(reuse: false, frames: 20, into: &warm)
        try rig.run(reuse: true, frames: 20, into: &warm)
        var fresh = Sample(), reused = Sample()
        for _ in 0..<Self.rounds {
            try rig.run(reuse: false, frames: Self.frames / Self.rounds, into: &fresh)
            try rig.run(reuse: true, frames: Self.frames / Self.rounds, into: &reused)
        }
        let dWall = Self.median(fresh.wallMs) - Self.median(reused.wallMs)
        let dCPU = Self.median(fresh.cpuEncodeMs) - Self.median(reused.cpuEncodeMs)
        let dGPU = Self.median(fresh.gpuMs) - Self.median(reused.gpuMs)
        for (name, s) in [("fresh", fresh), ("reused", reused)] {
            print("PERF 4K HDR loop \(name): wall \(Self.fmt(Self.median(s.wallMs))) ms/frame median "
                  + "(p95 \(Self.fmt(Self.p95(s.wallMs)))), CPU encode \(Self.fmt(Self.median(s.cpuEncodeMs))) ms, "
                  + "GPU \(Self.fmt(Self.median(s.gpuMs))) ms, load avg \(ProResPerfTests.loadAverage)")
        }
        print("PERF 4K HDR loop fresh − reused: wall \(Self.fmt(dWall)) ms/frame, CPU encode \(Self.fmt(dCPU)) ms, "
              + "GPU \(Self.fmt(dGPU)) ms (4 textures/frame; \(rig.memo.count) reused textures)")
        // Budget: 16.6 ms per 4K60 frame for decode, tone map and composite together.
        LoadGate.expect(Self.median(fresh.wallMs) < 16.6,
                        "4K HDR tone map + composite with fresh textures: \(Self.fmt(Self.median(fresh.wallMs))) ms/frame")
    }

    /// Creation alone (no GPU use) of the four textures of one frame, CPU time.
    @Test func creationOnly() throws {
        let rig = try Rig()
        var outputs: [CVPixelBuffer] = []
        for _ in 0..<20 { _ = try rig.fresh(rig.sources[0], try rig.pool.make()) }
        let n = 2000
        var ns: UInt64 = 0
        for i in 0..<n {
            let src = rig.sources[i % rig.sources.count]
            let dst = try rig.pool.make()
            let t0 = DispatchTime.now().uptimeNanoseconds
            let f = try rig.fresh(src, dst)
            withExtendedLifetime(f) {}
            ns += DispatchTime.now().uptimeNanoseconds - t0
            outputs.append(dst)
            if outputs.count > Self.keptOutputs { outputs.removeFirst() }
        }
        let perFrame = Double(ns) / 1e3 / Double(n)
        print("PERF 4K texture creation (Y + CbCr + BGRA×2, no GPU use): \(Self.fmt(perFrame, 1)) µs/frame, "
              + "\(Self.fmt(perFrame / 4, 1)) µs/texture, load avg \(ProResPerfTests.loadAverage)")
    }
}
