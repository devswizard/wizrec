import CoreGraphics
import Foundation
import Metal
import Testing
@testable import RenderEngine

/// Writes an original particle `.tscshadervid`-shaped file (our own GLSL) into a temp dir.
private func particleFile(vertex: String, fragment: String, numVertices: Any? = 12, blend: String? = nil,
                          effectDef: [[String: Any]] = []) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-particles-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var obj: [String: Any] = ["name": "Particles test", "version": 1.3, "width": 1920, "height": 1080,
                              "effectDef": effectDef, "code": fragment, "vertexCode": vertex]
    if let numVertices { obj["numVertices"] = numVertices }
    if let blend { obj["blend"] = blend }
    let url = dir.appendingPathComponent("particles.tscshadervid")
    try JSONSerialization.data(withJSONObject: obj).write(to: url)
    return url
}

/// Quad `q` (6 vertices each) is a `_Size` px square at (100 + 400 q + 100 _Time, 100) in the
/// file's 1920×1080 pixel space, origin top-left.
private let quadsVertex = """
#version 300 es
uniform float _Time;
uniform vec2 _OutputSize;
uniform mat4 _ToRenderTarget;
uniform float _Size;
out vec2 _TexCoord;
flat out int vQuad;
void main() {
    int q = gl_VertexID / 6;
    int c = gl_VertexID - q * 6;
    vec2 corner = vec2((c == 1 || c == 2 || c == 4) ? 1.0 : 0.0, (c == 2 || c == 4 || c == 5) ? 1.0 : 0.0);
    vec2 p = vec2(100.0 + float(q) * 400.0 + _Time * 100.0, 100.0) + corner * _Size;
    _TexCoord = p / _OutputSize;
    vQuad = q;
    gl_Position = vec4(p, 0.0, 1.0) * _ToRenderTarget;
}
"""

private var sizeDef: [[String: Any]] { [
    ["name": "Size", "type": "double", "defaultValue": 200.0, "minValue": 0, "maxValue": 1000],
    ["name": "Color0", "type": "Color", "value": "FF0000"],
] }

private let canvas = CGSize(width: 192, height: 108)

private func plan(_ url: URL, _ params: [String: Double] = [:], time: Double = 0) -> RenderPlan {
    RenderPlan(time: 0, canvasSize: canvas, background: RGBA(0, 0, 0),
               layers: [Layer(clipID: 1, content: .shader(url, parameters: params, time: time), size: canvas)])
}

struct ParticleTranslationTests {
    @Test func collectsVaryingsAndUniformsOfBothStages() throws {
        let out = try GLSLTranslator.translateParticles(vertex: quadsVertex, fragment: """
        uniform vec4 _Color0;
        uniform float _Size;
        in vec2 _TexCoord;
        flat in int vQuad;
        out vec4 fragColor;
        void main() { fragColor = _Color0; }
        """)
        #expect(out.uniforms.map(\.name) == ["_Size", "_Color0"])
        #expect(out.source.contains("int vQuad [[flat]]"))
        #expect(out.source.contains("float2 _TexCoord;") || out.source.contains("vec2 _TexCoord;"))
    }

    @Test func vertexInputsAreRejected() {
        #expect(throws: GLSLTranslator.Failure.self) {
            try GLSLTranslator.translateParticles(vertex: "in vec2 pos; void main() { gl_Position = vec4(pos, 0.0, 1.0); }",
                                                  fragment: "void main() { _FragColor = vec4(1.0); }")
        }
    }

    @Test func fileFields() throws {
        let f = try ShaderVidFile(data: Data(contentsOf: try particleFile(vertex: quadsVertex, fragment: "void main() {}",
                                                                         numVertices: 100_000, blend: "add")))
        #expect(f.hasVertexCode && f.additive)
        #expect(f.vertexCount == 99_999)  // the trailing partial triangle is dropped
        let d = try ShaderVidFile(data: Data(contentsOf: try particleFile(vertex: quadsVertex, fragment: "void main() {}",
                                                                         numVertices: nil)))
        #expect(d.vertexCount == 6 && !d.additive)
    }
}

@Suite(.enabled(if: hasGPU)) struct ParticleRenderTests {
    private let twoColours = """
    uniform vec4 _Color0;
    in vec2 _TexCoord;
    flat in int vQuad;
    out vec4 fragColor;
    void main() { fragColor = vQuad == 0 ? _Color0 : vec4(0.0, 1.0, 0.0, 1.0); }
    """

    @Test func quadsLandInTopLeftPixelSpaceScaledToTheLayer() throws {
        let url = try particleFile(vertex: quadsVertex, fragment: twoColours, effectDef: sizeDef)
        let img = try GPUTest.render(plan(url))
        // Natural 1920×1080 → 192×108: quad 0 covers (10…30, 10…30), quad 1 (50…70, 10…30), y down.
        #expect(img.at(20, 20).near(.red, 1))
        #expect(img.at(60, 20).near(.green, 1))
        #expect(img.at(40, 20).near(Px(r: 0, g: 0, b: 0, a: 255), 1))
        #expect(img.at(20, 88).near(Px(r: 0, g: 0, b: 0, a: 255), 1))
    }

    @Test func timeAndParametersReachBothStages() throws {
        let url = try particleFile(vertex: quadsVertex, fragment: twoColours, effectDef: sizeDef)
        let blue = ["Color0-red": 0.0, "Color0-green": 0, "Color0-blue": 1, "Color0-alpha": 1]
        // _Time 1 moves quads 100 natural px (10 target px) right.
        let img = try GPUTest.render(plan(url, blue, time: 1))
        #expect(img.at(35, 20).near(.blue, 1))
        #expect(img.at(15, 20).near(Px(r: 0, g: 0, b: 0, a: 255), 1))
        // _Size 400 doubles the quad.
        let big = try GPUTest.render(plan(url, ["Size": 400]))
        #expect(big.at(45, 45).near(.red, 1))
    }

    @Test func varyingsAndFragCoord() throws {
        let url = try particleFile(vertex: quadsVertex, fragment: """
        in vec2 _TexCoord;
        void main() { _FragColor = vec4(_TexCoord.x * 4.0, gl_FragCoord.y / 1080.0, 0.0, 1.0); }
        """, numVertices: 6, effectDef: sizeDef)
        let p = try GPUTest.render(plan(url)).at(20, 20)
        // Centre of quad 0: natural (200, 200) → _TexCoord.x 0.104; GL gl_FragCoord.y = 1080 − 200 = 880.
        let expectedR: Int = Int((200.0 / 1920.0 * 4.0 * 255.0).rounded())
        #expect(abs(p.r - expectedR) <= 6)
        let expectedG: Int = Int((880.0 / 1080.0 * 255.0).rounded())
        #expect(abs(p.g - expectedG) <= 6)
    }

    /// Two overlapping quads at 25 % red: added with `blend: add`, the top one wins otherwise.
    @Test(arguments: [("add", 128), (nil, 64)] as [(String?, Int)])
    func blending(_ blend: String?, _ expected: Int) throws {
        let vertex = quadsVertex.replacingOccurrences(of: "float(q) * 400.0", with: "0.0")
        let url = try particleFile(vertex: vertex, fragment: "void main() { _FragColor = vec4(0.25, 0.0, 0.0, 1.0); }",
                                   numVertices: 12, blend: blend, effectDef: sizeDef)
        let p = try GPUTest.render(plan(url)).at(20, 20)
        #expect(abs(p.r - expected) <= 2, "blend \(blend ?? "none"): \(p)")
    }

    /// GLSL copies `out`/`inout` arguments in and back, so vector components may be passed.
    @Test func outAndInoutVectorComponents() throws {
        let url = try particleFile(vertex: quadsVertex, fragment: """
        void bump(inout float x) { x += 0.5; }
        float store(out float y, float z) { y = z; return 0.25; }
        void main() {
            vec4 c = vec4(0.0, 0.0, 0.0, 1.0);
            bump(c.r);
            c.b = store(c.g, 1.0);
            bump(c.r);
            vec4 w = vec4(1.0, 0.0, 0.0, 0.0);
            w.xy *= mat2(0.0, 1.0, 1.0, 0.0);   // swaps: (0, 1)
            c.g *= w.y;
            _FragColor = c;
        }
        """, numVertices: 6, effectDef: sizeDef)
        #expect(try GPUTest.render(plan(url)).at(20, 20).near(Px(r: 255, g: 255, b: 64, a: 255), 1))
    }

    @Test func partialTriangleIsDropped() throws {
        let url = try particleFile(vertex: quadsVertex, fragment: twoColours, numVertices: 11, effectDef: sizeDef)
        let img = try GPUTest.render(plan(url))
        // 11 → 9 vertices: quad 0 plus one triangle of quad 1 (corners 0, 1, 2: its upper-right half).
        #expect(img.at(20, 20).near(.red, 1))
        #expect(img.at(52, 28).near(Px(r: 0, g: 0, b: 0, a: 255), 1))
        #expect(img.at(68, 14).near(.green, 1))
    }
}

/// Every particle background installed with Camtasia translates, compiles and draws something
/// (read in place; shader text is never printed, only counts, file names and error kinds).
/// Skips when the app is absent.
@Suite(.enabled(if: hasGPU && FileManager.default.fileExists(atPath: "/Applications/Camtasia.app")))
struct InstalledParticleShaderTests {
    @Test func installedVertexShadersCompileAndDraw() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let e = FileManager.default.enumerator(atPath: "/Applications/Camtasia.app") else { return }
        let urls = e.compactMap { $0 as? String }.filter { $0.hasSuffix(".tscshadervid") }
            .map { URL(fileURLWithPath: "/Applications/Camtasia.app").appendingPathComponent($0) }
        let shaders = ShaderBackgrounds(device: device)
        var particle = 0, failed: [String] = [], blank: [String] = []
        for url in urls {
            guard let f = try? ShaderVidFile(data: Data(contentsOf: url)), f.hasVertexCode else { continue }
            particle += 1
            guard shaders.program(url) != nil else {
                // Error kinds only: the compiler's source-line echo is skipped.
                let kinds = Set((shaders.failures[url] ?? "").components(separatedBy: "\n").compactMap { line -> String? in
                    line.range(of: "error: ").map { String(line[$0.upperBound...].prefix(90)) }
                })
                failed.append("\(url.lastPathComponent) (\(kinds.sorted().joined(separator: "; ")))")
                continue
            }
            // Over black at 3 s with the file's defaults, ≥ 0.1 % of a 960×540 frame must light up.
            let size = CGSize(width: 960, height: 540)
            let plan = RenderPlan(time: 0, canvasSize: size, background: RGBA(0, 0, 0),
                                  layers: [Layer(clipID: 1, content: .shader(url, parameters: [:], time: 3), size: size)])
            let img = try GPUTest.render(plan, 960, 540)
            var lit = 0, samples = 0
            for y in stride(from: 0, to: 540, by: 3) {
                for x in stride(from: 0, to: 960, by: 3) {
                    samples += 1
                    if !img.at(x, y).near(.black, 2) { lit += 1 }
                }
            }
            if lit * 1000 < samples { blank.append("\(url.lastPathComponent) \(lit)/\(samples)") }
        }
        print("installed particle shaders: \(particle), failed: \(failed), drew nothing: \(blank)")
        #expect(failed.isEmpty)
        #expect(blank.isEmpty)
    }
}

/// GPU time of each installed particle background at 1080p (`WIZREC_PERF=1`; reported, not enforced).
@Suite(.enabled(if: hasGPU && ProcessInfo.processInfo.environment["WIZREC_PERF"] == "1"
                && FileManager.default.fileExists(atPath: "/Applications/Camtasia.app")))
struct InstalledParticlePerfTests {
    @Test func gpuTimeAt1080p() throws {
        guard let e = FileManager.default.enumerator(atPath: "/Applications/Camtasia.app") else { return }
        let urls = e.compactMap { $0 as? String }.filter { $0.hasSuffix(".tscshadervid") }
            .map { URL(fileURLWithPath: "/Applications/Camtasia.app").appendingPathComponent($0) }
        let size = CGSize(width: 1920, height: 1080)
        for url in urls {
            guard let f = try? ShaderVidFile(data: Data(contentsOf: url)), f.hasVertexCode else { continue }
            let plan = RenderPlan(time: 0, canvasSize: size, background: RGBA(0, 0, 0),
                                  layers: [Layer(clipID: 1, content: .shader(url, parameters: [:], time: 3), size: size)])
            var best = Double.infinity
            for _ in 0..<4 {
                var t = 0.0
                _ = try GPUTest.render(plan, 1920, 1080, gpuTime: &t)
                best = min(best, t)
            }
            print(String(format: "particle perf %@: %d vertices, %.2f ms GPU at 1080p", url.lastPathComponent,
                         f.vertexCount, best * 1000))
        }
    }
}
