import Foundation
import Metal
import WizRecAssets

/// A parsed `.tscshadervid` file (`docs/specs/shader-backgrounds.md`). Read from the user's
/// own copy at render time; never vendored.
struct ShaderVidFile: Sendable {
    /// One `effectDef` entry's default.
    enum Default: Sendable, Equatable {
        case color(SIMD4<Float>)
        case scalar(Double)
        case position(SIMD2<Float>)
    }

    var name: String
    /// Fragment shader body (GLSL).
    var code: String
    /// Vertex stage of a particle background (GLSL), nil for a full-frame fragment shader [§5].
    var vertexCode: String?
    var hasVertexCode: Bool { vertexCode != nil }
    /// Vertices drawn as a triangle list for `vertexCode`; a trailing partial triangle is
    /// dropped. Missing → 6, one quad [WizRec]. Capped at `maxVertices`.
    var vertexCount: Int
    static let maxVertices = 4_000_000
    /// `blend: "add"`: fragments add onto the background's own canvas; otherwise source-over [§5, inf].
    var additive: Bool
    var width: Double
    var height: Double
    var defaults: [String: Default]

    enum LoadError: Error { case unreadable, notAnObject, noCode }

    /// Parses the file. UTF-8 first, then Latin-1 (38 of 59 files carry a Latin-1 `©`) [obs, §1].
    init(data: Data) throws {
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        guard let text, let utf8 = text.data(using: .utf8) else { throw LoadError.unreadable }
        guard let obj = try JSONSerialization.jsonObject(with: utf8, options: [.fragmentsAllowed]) as? [String: Any]
        else { throw LoadError.notAnObject }
        guard let code = obj["code"] as? String else { throw LoadError.noCode }
        self.code = code
        name = obj["name"] as? String ?? ""
        func num(_ v: Any?) -> Double? {
            if let n = v as? NSNumber { return n.doubleValue }
            if let s = v as? String { return Double(s) }
            return nil
        }
        vertexCode = (obj["vertexCode"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let n = num(obj["numVertices"]).map { $0.isFinite ? Int(max(0, min($0, Double(Self.maxVertices)))) : 0 } ?? 6
        vertexCount = n - n % 3
        additive = (obj["blend"] as? String)?.lowercased() == "add"
        width = num(obj["width"]) ?? 1920
        height = num(obj["height"]) ?? 1080
        var defaults: [String: Default] = [:]
        for case let e as [String: Any] in obj["effectDef"] as? [Any] ?? [] {
            guard let n = e["name"] as? String else { continue }
            switch e["type"] as? String {
            case "Color":
                if let hex = e["value"] as? String, let c = Self.hex(hex) { defaults[n] = .color(c) }
            case "Position":
                if let v = e["value"] as? [Any], v.count >= 2, let x = num(v[0]), let y = num(v[1]) {
                    defaults[n] = .position(SIMD2(Float(x), Float(y)))
                }
            default:
                let bounds = e["valueBounds"] as? [String: Any]
                if let d = num(e["defaultValue"]) ?? num(bounds?["defaultValue"]) { defaults[n] = .scalar(d) }
            }
        }
        self.defaults = defaults
    }

    /// A colour `value` string [shader-backgrounds.md §6]:
    /// - exactly six hex digits (`"5E0CBB"`, optional `#`) → (0x5E, 0x0C, 0xBB)/255 with alpha 1 [obs];
    /// - anything else made of hex digits (spaces dropped, at most 8 digits) is one hexadecimal number
    ///   laid out as RRGGBBAA, so `" 130939"` → bytes 00 13 09 39 = (0, 0.0745, 0.0353, 0.2235)
    ///   [obs value, inf rule: Camtasia stores that file's colour this way].
    static func hex(_ s: String) -> SIMD4<Float>? {
        guard let c = AssetColor(shaderText: s) else { return nil }
        return SIMD4(Float(c.red), Float(c.green), Float(c.blue), Float(c.alpha))
    }

    /// Uniform value for `uniform` from the clip's evaluated `SourceEffect` parameters, falling back to
    /// the file default, then 0 (GLSL's unset uniform) [shader-backgrounds.md §3, §6].
    func value(for u: GLSLTranslator.Uniform, parameters p: [String: Double], time: Double) -> SIMD4<Float> {
        let key = u.name.hasPrefix("_") ? String(u.name.dropFirst()) : u.name
        if key == "Time" { return SIMD4(Float(time), 0, 0, 0) }
        let def = defaults[key]
        switch u.type {
        case "vec3", "vec4":
            var c: SIMD4<Float> = if case .color(let d)? = def { d } else { SIMD4(0, 0, 0, u.type == "vec3" ? 1 : 0) }
            for (i, ch) in ["red", "green", "blue", "alpha"].enumerated() {
                if let v = p["\(key)-\(ch)"] { c[i] = Float(v) }
            }
            return c
        case "vec2", "ivec2":
            // Position parameters are `<name>.x` / `<name>.y` on the clip [obs, SH2]; the older
            // guesses `-x/-y` and `0/1` are still read (earlier WizRec projects).
            var v: SIMD2<Float> = if case .position(let d)? = def { d } else { .zero }
            if let x = p["\(key).x"] ?? p["\(key)-x"] ?? p["\(key)0"] { v.x = Float(x) }
            if let y = p["\(key).y"] ?? p["\(key)-y"] ?? p["\(key)1"] { v.y = Float(y) }
            return SIMD4(v.x, v.y, 0, 0)
        default:
            let d: Double = if case .scalar(let s)? = def { s } else { 0 }
            return SIMD4(Float(p[key] ?? d), 0, 0, 0)
        }
    }
}

/// Loads, translates and compiles `.tscshadervid` backgrounds; one pipeline per file and
/// pixel format. Failures are remembered so the compositor draws its fallback gradient
/// without retrying every frame. Not thread-safe (owned by `CompositorCore`).
final class ShaderBackgrounds {
    struct Program {
        let file: ShaderVidFile
        let uniforms: [GLSLTranslator.Uniform]
        /// Full-frame fragment function, or the particle fragment function when `vertex` is set.
        let function: any MTLFunction
        /// Particle vertex function (`vertexCode` files).
        var vertex: (any MTLFunction)?
    }

    private let device: any MTLDevice
    private var programs: [URL: Program] = [:]
    private var particlePipelines: [String: any MTLRenderPipelineState] = [:]
    private(set) var failures: [URL: String] = [:]

    init(device: any MTLDevice) { self.device = device }

    /// The compiled program for `url`, or nil (fallback) when it cannot be read, translated or compiled.
    func program(_ url: URL) -> Program? {
        if let p = programs[url] { return p }
        if failures[url] != nil { return nil }
        do {
            let file = try ShaderVidFile(data: Data(contentsOf: url))
            if let vertexCode = file.vertexCode {
                let out = try GLSLTranslator.translateParticles(vertex: vertexCode, fragment: file.code)
                let lib = try device.makeLibrary(source: out.source, options: nil)
                guard let v = lib.makeFunction(name: GLSLTranslator.ParticleOutput.vertexName),
                      let f = lib.makeFunction(name: GLSLTranslator.ParticleOutput.fragmentName) else {
                    throw RenderError.shaderCompile("no particle entry points")
                }
                let p = Program(file: file, uniforms: out.uniforms, function: f, vertex: v)
                programs[url] = p
                return p
            }
            let out = try GLSLTranslator.translate(file.code)
            let lib = try device.makeLibrary(source: out.source, options: nil)
            guard let f = lib.makeFunction(name: GLSLTranslator.Output.fragmentName) else {
                throw RenderError.shaderCompile("no entry point")
            }
            let p = Program(file: file, uniforms: out.uniforms, function: f)
            programs[url] = p
            return p
        } catch {
            failures[url] = String(describing: error)
            return nil
        }
    }

    /// Draws a particle program into `target` (cleared to transparent first [WizRec]; SH2 is [?])
    /// as `file.vertexCount` vertices, additive or source-over, premultiplied.
    func encodeParticles(_ p: Program, parameters: [String: Double], time: Double, into target: any MTLTexture,
                         commandBuffer: any MTLCommandBuffer) throws {
        guard let vertex = p.vertex else { return }
        let key = "\(ObjectIdentifier(p.function as AnyObject))|\(target.pixelFormat.rawValue)"
        let pipeline: any MTLRenderPipelineState
        if let cached = particlePipelines[key] { pipeline = cached } else {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vertex
            d.fragmentFunction = p.function
            let a = d.colorAttachments[0]!
            a.pixelFormat = target.pixelFormat
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = p.file.additive ? .one : .oneMinusSourceAlpha
            a.destinationAlphaBlendFactor = p.file.additive ? .one : .oneMinusSourceAlpha
            do { pipeline = try device.makeRenderPipelineState(descriptor: d) } catch {
                throw RenderError.shaderCompile(String(describing: error))
            }
            particlePipelines[key] = pipeline
        }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { throw RenderError.noMetalDevice }
        defer { enc.endEncoding() }
        guard p.file.vertexCount > 0 else { return }
        let bytes = Self.particleUniformBytes(p, parameters: parameters, time: time,
                                              target: SIMD2(Float(target.width), Float(target.height)))
        let length = bytes.count * MemoryLayout<SIMD4<Float>>.stride
        enc.setRenderPipelineState(pipeline)
        if length <= 4096 {
            var b = bytes
            enc.setVertexBytes(&b, length: length, index: 1)
            enc.setFragmentBytes(&b, length: length, index: 1)
        } else {
            guard let buf = bytes.withUnsafeBytes({ raw in raw.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: length) } }) else {
                throw RenderError.noMetalDevice
            }
            enc.setVertexBuffer(buf, offset: 0, index: 1)
            enc.setFragmentBuffer(buf, offset: 0, index: 1)
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: p.file.vertexCount)
    }

    /// Particle `GLUniforms`: `sys` (time s, natural w, h), `dst` (target w, h), `toTarget`, then
    /// one `float4` per uniform. `toTarget` maps natural px (origin top-left, +y down) to clip space
    /// when applied row-vector style, `vec4(p, 0, 1) * _ToRenderTarget` [WizRec: the installed
    /// particle files only fill the frame with this layout; with the column-vector layout they
    /// draw almost nothing].
    static func particleUniformBytes(_ p: Program, parameters: [String: Double], time: Double,
                                     target: SIMD2<Float>) -> [SIMD4<Float>] {
        let w = Float(max(p.file.width, 1)), h = Float(max(p.file.height, 1))
        var out: [SIMD4<Float>] = [
            SIMD4(Float(time), w, h, 0),
            SIMD4(target.x, target.y, 0, 0),
            // Columns of the matrix as GLSL sees it: clip = vec4(px, py, z, 1) * M (row-vector use).
            SIMD4(2 / w, 0, 0, -1), SIMD4(0, -2 / h, 0, 1), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1),
        ]
        out += p.uniforms.map { p.file.value(for: $0, parameters: parameters, time: time) }
        if p.uniforms.isEmpty { out.append(.zero) }
        return out
    }

    /// `GLUniforms` bytes: `sys` = (time s, image w, h, 0) then one `float4` per uniform.
    static func uniformBytes(_ p: Program, parameters: [String: Double], time: Double,
                             imageSize: SIMD2<Float>) -> [SIMD4<Float>] {
        var out: [SIMD4<Float>] = [SIMD4(Float(time), imageSize.x, imageSize.y, 0)]
        out += p.uniforms.map { p.file.value(for: $0, parameters: parameters, time: time) }
        if p.uniforms.isEmpty { out.append(.zero) }
        return out
    }
}
