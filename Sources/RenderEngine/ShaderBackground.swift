import Foundation
import Metal

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
    /// Particle shaders carry a vertex stage; WizRec does not draw those yet.
    var hasVertexCode: Bool
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
        hasVertexCode = (obj["vertexCode"] as? String).map { !$0.isEmpty } ?? false
        func num(_ v: Any?) -> Double? {
            if let n = v as? NSNumber { return n.doubleValue }
            if let s = v as? String { return Double(s) }
            return nil
        }
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

    /// `"5E0CBB"` → (0x5E, 0x0C, 0xBB)/255 with alpha 1. Extra characters after six digits are ignored.
    static func hex(_ s: String) -> SIMD4<Float>? {
        let digits = s.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).prefix(6)
        guard digits.count == 6, let v = UInt32(digits, radix: 16) else { return nil }
        return SIMD4(Float((v >> 16) & 0xFF) / 255, Float((v >> 8) & 0xFF) / 255, Float(v & 0xFF) / 255, 1)
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
            // Position parameters' project form is [?] (SH3): accept `-x/-y` and `0/1`.
            var v: SIMD2<Float> = if case .position(let d)? = def { d } else { .zero }
            if let x = p["\(key)-x"] ?? p["\(key)0"] { v.x = Float(x) }
            if let y = p["\(key)-y"] ?? p["\(key)1"] { v.y = Float(y) }
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
        let function: any MTLFunction
    }

    private let device: any MTLDevice
    private var programs: [URL: Program] = [:]
    private(set) var failures: [URL: String] = [:]

    init(device: any MTLDevice) { self.device = device }

    /// The compiled program for `url`, or nil (fallback) when it cannot be read, translated or compiled.
    func program(_ url: URL) -> Program? {
        if let p = programs[url] { return p }
        if failures[url] != nil { return nil }
        do {
            let file = try ShaderVidFile(data: Data(contentsOf: url))
            guard !file.hasVertexCode else { throw RenderError.shaderCompile("vertexCode shaders not supported yet") }
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

    /// `GLUniforms` bytes: `sys` = (time s, image w, h, 0) then one `float4` per uniform.
    static func uniformBytes(_ p: Program, parameters: [String: Double], time: Double,
                             imageSize: SIMD2<Float>) -> [SIMD4<Float>] {
        var out: [SIMD4<Float>] = [SIMD4(Float(time), imageSize.x, imageSize.y, 0)]
        out += p.uniforms.map { p.file.value(for: $0, parameters: parameters, time: time) }
        if p.uniforms.isEmpty { out.append(.zero) }
        return out
    }
}
