// HDR (PQ / HLG) to SDR BT.709 tone mapping on the GPU: a Metal compute port of `ToneMapper`.
//
// Same inputs, same LUTs and the same arithmetic order as the CPU reference
// (`ToneMapper.convert`), so results match it within a documented tolerance:
//
//   max |GPU − CPU| ≤ 1 code per 8-bit channel, and ≥ 99.9 % of channel values identical
//   (asserted in `ToneMapMetalTests`). Measured on Apple silicon (2026-10-20): byte-identical
//   on all 15 cases (8/10-bit, 4:2:0/4:2:2/4:4:4, video/full range, PQ/HLG, BT.2020/P3,
//   ~1.1 M pixels incl. a full 10-bit luma sweep): max |Δ| 0.
//
// Differences could only come from the few analytic float operations left outside the LUTs
// (the shoulder's `exp`, a division), whose last-ulp results Metal does not promise to match
// Darwin's libm on every GPU, so a value could move by one code at a LUT-index or 8-bit
// boundary. Because exactness is not guaranteed across GPUs, the GPU path is for playback only;
// export, thumbnails and golden tests stay on the CPU reference, which remains byte-identical
// across decoder lanes. 4K P010: ≈2 ms/frame (vs ≈13 ms CPU release, all cores).

import CoreVideo
import Foundation
import Metal

/// Tone-maps bi-planar HDR YCbCr buffers into BGRA with one Metal compute dispatch per frame.
///
/// Drop-in for `ToneMapper.convert(_:into:)`: the source must be an IOSurface-backed
/// bi-planar YCbCr buffer (8-bit, or 10-bit in the 16-bit MSBs) and the destination an
/// IOSurface-backed 32BGRA buffer of the same size in pixels. Not thread-safe: use one per
/// decoder (as `FrameConverter` does).
final class MetalToneMapper {
    /// The CPU reference this mapper reproduces (curves, matrix, range, LUTs).
    let reference: ToneMapper
    private let gpu: GPU
    private let cache: CVMetalTextureCache
    private let eotf: MTLBuffer, ootf: MTLBuffer, encode: MTLBuffer

    /// Process-wide Metal objects, built once (pipeline compilation costs milliseconds).
    struct GPU: @unchecked Sendable {
        // Sendable: MTLDevice, MTLCommandQueue and MTLComputePipelineState are thread-safe
        // per Metal's documentation; nothing here is mutated after creation.
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLComputePipelineState
    }

    /// Nil when the machine has no Metal device or the kernel fails to compile.
    static let shared: GPU? = {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let opts = MTLCompileOptions()
        // Fast maths off (also forced by the kernel's pragmas, which cover older systems).
        if #available(macOS 15.0, *) {
            opts.mathMode = .safe
            opts.mathFloatingPointFunctions = .precise
        }
        guard let lib = try? device.makeLibrary(source: kernelSource, options: opts),
              let fn = lib.makeFunction(name: "toneMapHDR"),
              let pipeline = try? device.makeComputePipelineState(function: fn) else { return nil }
        return GPU(device: device, queue: queue, pipeline: pipeline)
    }()

    /// GPU mapper reproducing `reference`, or nil when Metal is unavailable.
    init?(_ reference: ToneMapper) {
        guard let gpu = Self.shared else { return nil }
        var c: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, gpu.device, nil, &c) == kCVReturnSuccess, let cache = c else { return nil }
        let d = gpu.device
        func upload(_ raw: UnsafeRawBufferPointer) -> MTLBuffer? {
            raw.baseAddress.flatMap { d.makeBuffer(bytes: $0, length: raw.count) }
        }
        guard let e = reference.eotf.withUnsafeBytes(upload), let o = reference.ootf.withUnsafeBytes(upload),
              let n = reference.encode.withUnsafeBytes(upload) else { return nil }
        self.reference = reference
        self.gpu = gpu
        self.cache = cache
        (eotf, ootf, encode) = (e, o, n)
    }

    private func texture(_ buf: CVPixelBuffer, plane: Int, format: MTLPixelFormat) throws -> CVMetalTexture {
        let w = CVPixelBufferGetWidthOfPlane(buf, plane), h = CVPixelBufferGetHeightOfPlane(buf, plane)
        var t: CVMetalTexture?
        let rc = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buf, nil, format, w, h, plane, &t)
        guard rc == kCVReturnSuccess, let t else {
            throw MediaError.decodeFailed("GPU tone mapping: no Metal texture for plane \(plane) (\(rc))")
        }
        return t
    }

    /// Tone-maps `src` into `dst`, waiting for the GPU. Throws on unsupported or non-IOSurface
    /// buffers; callers fall back to the CPU reference.
    func convert(_ src: CVPixelBuffer, into dst: CVPixelBuffer) throws {
        guard let lay = ToneMapper.layout(CVPixelBufferGetPixelFormatType(src)) else {
            throw MediaError.decodeFailed("GPU tone mapping: unsupported pixel format")
        }
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        guard CVPixelBufferGetWidth(dst) == w, CVPixelBufferGetHeight(dst) == h,
              CVPixelBufferGetPixelFormatType(dst) == kCVPixelFormatType_32BGRA else {
            throw MediaError.decodeFailed("GPU tone mapping: destination mismatch")
        }
        guard CVPixelBufferGetIOSurface(src) != nil, CVPixelBufferGetIOSurface(dst) != nil else {
            throw MediaError.decodeFailed("GPU tone mapping: buffers must be IOSurface-backed")
        }
        let cwid = CVPixelBufferGetWidthOfPlane(src, 1), chgt = CVPixelBufferGetHeightOfPlane(src, 1)
        guard cwid > 0, chgt > 0 else { throw MediaError.decodeFailed("GPU tone mapping: empty chroma plane") }
        let ten = lay.depth > 8
        let yTex = try texture(src, plane: 0, format: ten ? .r16Uint : .r8Uint)
        let cTex = try texture(src, plane: 1, format: ten ? .rg16Uint : .rg8Uint)
        // BGRA bytes written as integers through an RGBA8 view: no float → unorm rounding.
        let oTex = try texture(dst, plane: 0, format: .rgba8Uint)
        guard let yt = CVMetalTextureGetTexture(yTex), let ct = CVMetalTextureGetTexture(cTex),
              let ot = CVMetalTextureGetTexture(oTex) else {
            throw MediaError.decodeFailed("GPU tone mapping: texture unavailable")
        }

        let r = reference, fr = r.fullRange
        let maxCode: Float = ten ? 1023 : 255, unit: Float = ten ? 4 : 1
        let (m0, m1, m2) = r.gamut
        // Same normalisation constants as `ToneMapper.convert`.
        var floats: [Float] = [
            r.kr, r.kb, m0.x, m0.y, m0.z, m1.x, m1.y, m1.z, m2.x, m2.y, m2.z,
            fr ? 0 : 16 * unit, fr ? 1 / maxCode : 1 / (219 * unit),
            128 * unit, fr ? 1 / maxCode : 1 / (224 * unit), ToneMapper.knee,
        ]
        var uints: [UInt32] = [UInt32(w), UInt32(h), UInt32(cwid), UInt32(chgt), ten ? 1 : 0,
                               UInt32(lay.cw), UInt32(lay.ch), r.transfer == .hlg ? 1 : 0]

        guard let cmd = gpu.queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else {
            throw MediaError.decodeFailed("GPU tone mapping: no command buffer")
        }
        enc.setComputePipelineState(gpu.pipeline)
        enc.setTexture(yt, index: 0)
        enc.setTexture(ct, index: 1)
        enc.setTexture(ot, index: 2)
        enc.setBytes(&floats, length: floats.count * 4, index: 0)
        enc.setBytes(&uints, length: uints.count * 4, index: 1)
        enc.setBuffer(eotf, offset: 0, index: 2)
        enc.setBuffer(ootf, offset: 0, index: 3)
        enc.setBuffer(encode, offset: 0, index: 4)
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        if let err = cmd.error { throw MediaError.decodeFailed("GPU tone mapping: \(err.localizedDescription)") }
        withExtendedLifetime((yTex, cTex, oTex)) {}
    }

    /// Kernel: a line-by-line port of `ToneMapper.map` and the sampling in `ToneMapper.convert`
    /// (same expression order; contraction into FMA off, precise maths).
    static let kernelSource = """
    #include <metal_stdlib>
    using namespace metal;
    #pragma METAL fp math_mode(safe)
    #pragma METAL fp contract(off)

    // F: kr kb g00 g01 g02 g10 g11 g12 g20 g21 g22 yOff yScale cOff cScale knee
    // U: width height cwid chgt ten cw ch hlg
    static inline float chromaCode(texture2d<uint, access::read> c, uint row, uint x, uint k, bool ten) {
        uint v = c.read(uint2(x, row))[k];
        return float(ten ? (v >> 6) : v);
    }

    // Normalised chroma k of chroma column x (vertical interpolation as on the CPU).
    static inline float chromaAt(texture2d<uint, access::read> c, uint cy, uint cy2, float wv, uint x, uint k,
                                 bool ten, float cOff, float cScale) {
        float u = chromaCode(c, cy, x, k, ten) * (1 - wv) + chromaCode(c, cy2, x, k, ten) * wv;
        return (u - cOff) * cScale;
    }

    kernel void toneMapHDR(texture2d<uint, access::read> yTex [[texture(0)]],
                           texture2d<uint, access::read> cTex [[texture(1)]],
                           texture2d<uint, access::write> out [[texture(2)]],
                           constant float* F [[buffer(0)]],
                           constant uint* U [[buffer(1)]],
                           constant float* eotf [[buffer(2)]],
                           constant float* ootf [[buffer(3)]],
                           constant uchar* enc [[buffer(4)]],
                           uint2 gid [[thread_position_in_grid]]) {
        uint w = U[0], h = U[1], cwid = U[2], chgt = U[3];
        if (gid.x >= w || gid.y >= h) return;
        bool ten = U[4] != 0, hlg = U[7] != 0;
        uint x = gid.x, y = gid.y;
        float kr = F[0], kb = F[1];
        float yOff = F[11], yScale = F[12], cOff = F[13], cScale = F[14], knee = F[15];

        uint cy, cy2; float wv;
        if (U[6] == 1) {
            cy = min(y >> 1, chgt - 1);
            cy2 = (y & 1) == 0 ? (cy > 0 ? cy - 1 : 0) : min(cy + 1, chgt - 1);
            wv = 0.25f;
        } else {
            cy = min(y, chgt - 1); cy2 = cy; wv = 0;
        }
        float u, v;
        if (U[5] == 1) {
            uint i = min(x >> 1, cwid - 1);
            if ((x & 1) == 0) {
                u = chromaAt(cTex, cy, cy2, wv, i, 0, ten, cOff, cScale);
                v = chromaAt(cTex, cy, cy2, wv, i, 1, ten, cOff, cScale);
            } else {
                uint j = min(i + 1, cwid - 1);
                u = (chromaAt(cTex, cy, cy2, wv, i, 0, ten, cOff, cScale) + chromaAt(cTex, cy, cy2, wv, j, 0, ten, cOff, cScale)) * 0.5f;
                v = (chromaAt(cTex, cy, cy2, wv, i, 1, ten, cOff, cScale) + chromaAt(cTex, cy, cy2, wv, j, 1, ten, cOff, cScale)) * 0.5f;
            }
        } else {
            uint i = min(x, cwid - 1);
            u = chromaAt(cTex, cy, cy2, wv, i, 0, ten, cOff, cScale);
            v = chromaAt(cTex, cy, cy2, wv, i, 1, ten, cOff, cScale);
        }
        uint lc = yTex.read(gid).r;
        float yn = (float(ten ? (lc >> 6) : lc) - yOff) * yScale;

        // ToneMapper.map
        float kg = 1 - kr - kb;
        float r1 = yn + 2 * (1 - kr) * v;
        float b1 = yn + 2 * (1 - kb) * u;
        float g1 = precise::divide(yn - kr * r1 - kb * b1, kg);
        float r = eotf[int(min(max(r1, 0.0f), 1.0f) * 65536.0f + 0.5f)];
        float g = eotf[int(min(max(g1, 0.0f), 1.0f) * 65536.0f + 0.5f)];
        float b = eotf[int(min(max(b1, 0.0f), 1.0f) * 65536.0f + 0.5f)];
        if (hlg) {
            float ys = 0.2627f * r + 0.6780f * g + 0.0593f * b;
            float xs = min(max(ys, 0.0f), 1.0f) * 4096.0f;
            int i = min(int(xs), 4095);
            float s = ootf[i] + (ootf[i + 1] - ootf[i]) * (xs - float(i));
            r *= s; g *= s; b *= s;
        }
        float R = max(F[2] * r + F[3] * g + F[4] * b, 0.0f);
        float G = max(F[5] * r + F[6] * g + F[7] * b, 0.0f);
        float B = max(F[8] * r + F[9] * g + F[10] * b, 0.0f);
        float peak = max(R, max(G, B));
        if (peak > knee) {
            float f = knee + (1 - knee) * (1 - precise::exp(precise::divide(-(peak - knee), 1 - knee)));
            float s = precise::divide(f, peak);
            R *= s; G *= s; B *= s;
        }
        uint oR = enc[min(int(R * 65535.0f + 0.5f), 65535)];
        uint oG = enc[min(int(G * 65535.0f + 0.5f), 65535)];
        uint oB = enc[min(int(B * 65535.0f + 0.5f), 65535)];
        out.write(uint4(oB, oG, oR, 255), gid); // memory order B, G, R, A
    }
    """
}
