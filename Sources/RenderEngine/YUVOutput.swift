import CoreVideo
import Metal

/// Converts a composited BGRA texture into the two planes of a BT.709 4:2:0 bi-planar buffer
/// (`420v` video range or `420f` full range) on the GPU, so video encoders get YCbCr directly
/// instead of converting RGB on their side.
///
/// Rules [WizRec]: input is premultiplied BGRA (an opaque frame for export; alpha is dropped, as
/// an encoder does with BGRA input). Luma Y′ = 0.2126 R + 0.7152 G + 0.0722 B per pixel;
/// Cb = (B − Y′) / 1.8556 and Cr = (R − Y′) / 1.5748 from RGB filtered for left chroma siting
/// (the H.264/HEVC default, chroma_loc 0): chroma sample (i, j) sits on column 2i, between rows
/// 2j and 2j+1, weights [1 2 1]/4 across columns 2i−1…2i+1 and [1 1]/2 across the two rows, edges
/// clamped. Matches VideoToolbox's own BGRA conversion on flat areas. Video range: 16 + 219 Y′, 128 + 224 C;
/// full range: 255 Y′, 128 + 255 C (clamped). Values are rounded to the nearest 8-bit code.
final class YUVOutput {
    static let formats: Set<OSType> = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                       kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]

    private let lumaPipeline: any MTLRenderPipelineState
    private let chromaPipeline: any MTLRenderPipelineState

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct YUVOut { float4 pos [[position]]; };
    struct YUVParams { float4 scale; float4 offset; };  // (luma, chroma) scale and offset in 0–1 units

    vertex YUVOut yuv_vs(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1u) & 2u), float(vid & 2u));
        YUVOut o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); return o;
    }

    static float lumaOf(float3 rgb) { return dot(rgb, float3(0.2126, 0.7152, 0.0722)); }

    fragment float yuv_luma_fs(YUVOut in [[stage_in]], texture2d<float, access::read> src [[texture(0)]],
                               constant YUVParams& k [[buffer(0)]]) {
        uint2 p = uint2(in.pos.xy);
        float3 rgb = src.read(p).rgb;
        return k.offset.x + k.scale.x * lumaOf(rgb);
    }

    fragment float2 yuv_chroma_fs(YUVOut in [[stage_in]], texture2d<float, access::read> src [[texture(0)]],
                                  constant YUVParams& k [[buffer(0)]]) {
        uint2 c = uint2(in.pos.xy) * 2u;
        uint2 last = uint2(src.get_width() - 1u, src.get_height() - 1u);
        uint xl = c.x == 0u ? 0u : c.x - 1u, xr = min(c.x + 1u, last.x), y1 = min(c.y + 1u, last.y);
        float3 rgb = (src.read(uint2(xl, c.y)).rgb + 2.0 * src.read(c).rgb + src.read(uint2(xr, c.y)).rgb
                    + src.read(uint2(xl, y1)).rgb + 2.0 * src.read(uint2(c.x, y1)).rgb + src.read(uint2(xr, y1)).rgb)
                    * 0.125;
        float y = lumaOf(rgb);
        float2 cbcr = float2((rgb.b - y) / 1.8556, (rgb.r - y) / 1.5748);
        return k.offset.y + k.scale.y * cbcr;
    }
    """

    init(device: any MTLDevice) throws {
        let library: any MTLLibrary
        do { library = try device.makeLibrary(source: Self.source, options: nil) } catch {
            throw RenderError.shaderCompile(String(describing: error))
        }
        func make(_ fragment: String, _ format: MTLPixelFormat) throws -> any MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "yuv_vs")
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = format
            do { return try device.makeRenderPipelineState(descriptor: d) } catch {
                throw RenderError.shaderCompile(String(describing: error))
            }
        }
        lumaPipeline = try make("yuv_luma_fs", .r8Unorm)
        chromaPipeline = try make("yuv_chroma_fs", .rg8Unorm)
    }

    /// Encodes the conversion of `rgb` (same size as the buffer) into `luma` (`.r8Unorm`, full
    /// size) and `chroma` (`.rg8Unorm`, half size rounded up).
    func encode(from rgb: any MTLTexture, luma: any MTLTexture, chroma: any MTLTexture, fullRange: Bool,
                commandBuffer: any MTLCommandBuffer) throws {
        // Scale/offset in 0–1 units: x = luma, y = chroma.
        let fullScale = SIMD4<Float>(1, 1, 0, 0), fullOffset = SIMD4<Float>(0, Float(128) / 255, 0, 0)
        let videoScale = SIMD4<Float>(Float(219) / 255, Float(224) / 255, 0, 0)
        let videoOffset = SIMD4<Float>(Float(16) / 255, Float(128) / 255, 0, 0)
        var params: (SIMD4<Float>, SIMD4<Float>) = fullRange ? (fullScale, fullOffset) : (videoScale, videoOffset)
        for (pipeline, target) in [(lumaPipeline, luma), (chromaPipeline, chroma)] {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = target
            rp.colorAttachments[0].loadAction = .dontCare
            rp.colorAttachments[0].storeAction = .store
            guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else {
                throw RenderError.noMetalDevice
            }
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(rgb, index: 0)
            enc.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
    }
}
