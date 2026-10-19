import CoreGraphics
import Foundation
import Metal
import Testing
@testable import RenderEngine

// Shaders here are original test programs written for WizRec, not Camtasia content.

private func compiles(_ glsl: String) throws -> GLSLTranslator.Output {
    let out = try GLSLTranslator.translate(glsl)
    let device = try #require(gpu)
    do { _ = try device.makeLibrary(source: out.source, options: nil) } catch {
        Issue.record("MSL did not compile: \(error)\n\(out.source)")
    }
    return out
}

@Suite struct GLSLTranslatorTests {
    @Test func collectsUniformsAndDropsImplicitOnes() throws {
        let out = try GLSLTranslator.translate("""
        precision mediump float;
        uniform vec4 _Tint;
        uniform float _Amount, _Other;
        uniform float _Time;
        void main() { _FragColor = _Tint * _Amount; }
        """)
        #expect(out.uniforms == [.init(name: "_Tint", type: "vec4"), .init(name: "_Amount", type: "float"),
                                 .init(name: "_Other", type: "float")])
    }

    @Test func rejectsSamplersAndMissingMain() {
        #expect(throws: GLSLTranslator.Failure.unsupportedUniformType("sampler2D")) {
            try GLSLTranslator.translate("uniform sampler2D tex; void main() {}")
        }
        #expect(throws: GLSLTranslator.Failure.missingMain) {
            try GLSLTranslator.translate("float f() { return 1.0; }")
        }
    }

    @Test(.enabled(if: hasGPU)) func translatesCommonGLSLFeatures() throws {
        _ = try compiles("""
        #ifdef GL_ES
        precision highp float;
        #endif
        #define TAU 6.2831853
        uniform float _Speed;
        uniform vec2 _Centre;
        const float K = 0.5;
        float wave;                       // plain global
        struct Ring { float r; vec3 c; };
        float shape(vec2 p);              // prototype: dropped
        void split(in float x, out float a, inout float b) { a = fract(x); b += floor(x); }
        mat2 rot(float a) { float c = cos(a), s = sin(a); return mat2(c, -s, s, c); }
        float shape(vec2 p) { return length(p) - K; }
        void main(void) {
            vec2 uv = _TexCoord * 2.0 - 1.0;
            uv.x *= _ImageSize.x / _ImageSize.y;
            uv = rot(_Time * _Speed) * uv;
            float a, b = 0.0;
            split(_Time, a, b);
            wave = sin(atan(uv.y, uv.x) * 3.0 + a) * 0.5 + 0.5;
            float half = mod(uv.x, 0.25) + inversesqrt(4.0) + radians(90.0) / TAU;
            Ring r; r.r = shape(uv - _Centre); r.c = vec3(wave);
            vec3 col = mix(vec3(0.1, 0.2, 0.3), r.c, smoothstep(0.0, fwidth(r.r) + 0.01, -r.r));
            col = clamp(col + half * 0.0, 0.0, 1.0);
            for (int i = 0; i < 3; i++) { col.r += 0.01 * float(i); }
            gl_FragColor = vec4(col, 1.0);
        }
        """)
    }
}

/// Writes an original `.tscshadervid`-shaped file into a temp dir.
private func shaderFile(_ code: String, effectDef: [[String: Any]] = [], latin1: Bool = false) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-shader-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let obj: [String: Any] = ["name": "Test", "version": 1.1, "width": 1920, "height": 1080,
                              "effectDef": effectDef, "code": code, "copyright": "COPYRIGHT_MARK test"]
    var data = try JSONSerialization.data(withJSONObject: obj)
    if latin1 {
        // Replace the marker with a raw Latin-1 © byte, as some real files carry [spec §1].
        let marker = Data("COPYRIGHT_MARK".utf8)
        if let r = data.range(of: marker) { data.replaceSubrange(r, with: Data([0xA9])) }
    }
    let url = dir.appendingPathComponent("test.tscshadervid")
    try data.write(to: url)
    return url
}

private let canvas = CGSize(width: 192, height: 108)

private func shaderPlan(_ url: URL, _ params: [String: Double] = [:], time: Double = 0) -> RenderPlan {
    RenderPlan(time: 0, canvasSize: canvas, background: RGBA(0, 0, 0),
               layers: [Layer(clipID: 1, content: .shader(url, parameters: params, time: time), size: canvas)])
}

@Suite(.enabled(if: hasGPU)) struct ShaderBackgroundRenderTests {
    @Test func texCoordIsTopLeftYDown() throws {
        let url = try shaderFile("void main() { _FragColor = vec4(_TexCoord.x, _TexCoord.y, 0.0, 1.0); }")
        let img = try GPUTest.render(shaderPlan(url))
        let tl = img.at(0, 0), br = img.at(191, 107), tr = img.at(191, 0)
        #expect(tl.r <= 2 && tl.g <= 2)
        #expect(br.r >= 253 && br.g >= 253)
        #expect(tr.r >= 253 && tr.g <= 2)
    }

    @Test func uniformsComeFromParametersThenFileDefaults() throws {
        let url = try shaderFile("""
        uniform vec4 _Color0;
        uniform vec4 _Color1;
        uniform float _Mix;
        uniform float _Unset;
        void main() { _FragColor = mix(_Color0, _Color1, _Mix) + vec4(_Unset); }
        """, effectDef: [
            ["name": "Color0", "type": "Color", "value": "FF0000"],
            ["name": "Color1", "type": "Color", "value": "0000FF"],
            ["name": "Mix", "type": "double", "defaultValue": 0.0, "minValue": 0, "maxValue": 1],
        ])
        #expect(try GPUTest.render(shaderPlan(url)).at(96, 54).near(.red, 1))
        #expect(try GPUTest.render(shaderPlan(url, ["Mix": 1])).at(96, 54).near(.blue, 1))
        let green = ["Color1-red": 0.0, "Color1-green": 1, "Color1-blue": 0, "Color1-alpha": 1, "Mix": 1]
        #expect(try GPUTest.render(shaderPlan(url, green)).at(96, 54).near(.green, 1))
    }

    @Test func timeAndImageSizeAreProvided() throws {
        let url = try shaderFile("""
        void main() { _FragColor = vec4(_Time / 10.0, _ImageSize.x / 400.0, _ImageSize.y / 400.0, 1.0); }
        """)
        let p = try GPUTest.render(shaderPlan(url, time: 5)).at(96, 54)
        #expect(abs(p.r - 128) <= 1)
        // Drawn at 192×108 target px.
        #expect(abs(p.g - Int((192.0 / 400 * 255).rounded())) <= 1)
        #expect(abs(p.b - Int((108.0 / 400 * 255).rounded())) <= 1)
    }

    @Test func latin1FilesLoad() throws {
        let url = try shaderFile("void main() { _FragColor = vec4(0.0, 1.0, 0.0, 1.0); }", latin1: true)
        #expect(try GPUTest.render(shaderPlan(url)).at(96, 54) == .green)
    }

    @Test func brokenShaderFallsBackToGradient() throws {
        let url = try shaderFile("void main() { this is not glsl }")
        let params = ["Color0-red": 1.0, "Color0-green": 0, "Color0-blue": 0, "Color0-alpha": 1]
        let img = try GPUTest.render(shaderPlan(url, params))
        #expect(img.at(0, 0).near(.red, 6))
    }
}
