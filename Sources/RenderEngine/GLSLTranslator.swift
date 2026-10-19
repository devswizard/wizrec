import Foundation

/// Translates the GLSL fragment-shader subset used by `.tscshadervid` backgrounds into
/// Metal Shading Language, at runtime, from the user's own file.
///
/// Approach: the GLSL program becomes the body of one MSL `struct GLProgram`. Globals and
/// uniforms are members, functions are member functions (so declaration order and
/// prototypes stop mattering), and a fragment function fills the members and calls
/// `glsl_main()`. GLSL type names are `typedef`s of the MSL ones, and the few GLSL built-ins
/// MSL lacks (`mod`, two-argument `atan`, `inversesqrt`, `radians`, …) are defined in a prelude.
///
/// Supported: scalar/vector/matrix types, `const` and plain globals, structs, user
/// functions with `in`/`out`/`inout` parameters, preprocessor `#define`/`#if`, precision
/// qualifiers (dropped). Not supported (translation or compilation fails, and the caller
/// falls back): samplers/textures, arrays as constructors, `vec3(vec4)`-style truncation.
///
/// Implicit inputs (no declaration needed): `_Time` (float, seconds), `_TexCoord` (vec2,
/// 0…1 across the layer), `_FragColor` / `gl_FragColor` (vec4 output, straight alpha),
/// `gl_FragCoord` (vec4, px, +y up), `_ImageSize` (vec2, px of the drawn layer on the target)
/// [shader-backgrounds.md §2].
struct GLSLTranslator {
    /// A `uniform` the program declares, in declaration order.
    struct Uniform: Equatable, Sendable {
        var name: String
        var type: String
    }

    struct Output: Sendable {
        /// Complete MSL source; the fragment function is `fragmentName`.
        var source: String
        var uniforms: [Uniform]
        static let fragmentName = "glsl_background_fs"
        /// Entry point of a `.transition` translation.
        static let transitionFragmentName = "glsl_transition_fs"
    }

    /// What the program is. A `.transition` program also gets the implicit `_Progress` (0 → 1)
    /// and `textureA(uv)` / `textureB(uv)` (outgoing / incoming premultiplied colour, transparent
    /// outside 0…1) [transitions.md §5]; its output is premultiplied, as the inputs are.
    enum Mode: Sendable { case background, transition }

    enum Failure: Error, Equatable {
        case unsupportedUniformType(String)
        case missingMain
        case malformed(String)
    }

    /// Names the runtime provides; a `uniform` declaring one of them is dropped.
    static let implicitNames: Set<String> = ["_Time", "_TexCoord", "_FragColor", "_ImageSize",
                                              "gl_FragColor", "gl_FragCoord"]

    static let uniformTypes: Set<String> = ["float", "vec2", "vec3", "vec4", "int", "ivec2", "ivec3",
                                            "ivec4", "bool"]

    /// Identifiers that are reserved in MSL/C++ but legal in GLSL; renamed with a `_g` suffix.
    static let reserved: Set<String> = [
        "half", "kernel", "vertex", "fragment", "device", "constant", "thread", "threadgroup", "sampler",
        "texture", "class", "template", "this", "new", "delete", "auto", "namespace", "operator",
        "private", "public", "protected", "using", "typename", "union", "signed", "unsigned", "char",
        "short", "long", "static", "register", "goto", "friend", "virtual", "explicit", "mutable",
        "inline", "enum", "typedef", "sizeof", "size_t", "metal", "simd", "uchar", "ushort", "ulong",
        "and", "or", "not", "xor", "bitand", "bitor", "compl", "catch", "try", "throw", "double", "extern", "volatile", "alignas", "decltype", "nullptr", "constexpr",
        "static_assert", "noexcept", "thread_local", "export", "dynamic_cast", "reinterpret_cast",
        "const_cast", "static_cast", "typeid", "asm", "wchar_t", "char16_t", "char32_t",
    ]

    static func translate(_ glsl: String, mode: Mode = .background) throws -> Output {
        let implicit = mode == .transition ? implicitNames.union(["_Progress"]) : implicitNames
        var toks = Lexer(glsl).tokens()
        // Drop precision qualifiers and rename reserved identifiers.
        toks = toks.compactMap { t in
            guard t.kind == .ident else { return t }
            if ["lowp", "mediump", "highp"].contains(t.text) { return Token(kind: .ws, text: " ") }
            if reserved.contains(t.text) { return Token(kind: .ident, text: t.text + "_g") }
            if t.text == "main" { return Token(kind: .ident, text: "glsl_main") }
            if t.text == "dFdx" { return Token(kind: .ident, text: "dfdx") }
            if t.text == "dFdy" { return Token(kind: .ident, text: "dfdy") }
            return t
        }

        var uniforms: [Uniform] = []
        var body = ""
        var hasMain = false
        var i = 0
        while i < toks.count {
            let t = toks[i]
            switch t.kind {
            case .ws:
                body += t.text; i += 1; continue
            case .directive:
                let d = t.text.trimmingCharacters(in: .whitespaces)
                let keep = !(d.hasPrefix("#version") || d.hasPrefix("#extension") || d.hasPrefix("#pragma"))
                body += keep ? "\n" + t.text + "\n" : "\n"
                i += 1; continue
            default: break
            }
            // One top-level declaration: up to `;` at depth 0, or a function body's closing `}`.
            var j = i, depth = 0, parenAt: Int?, isFunction = false
            var end = toks.count
            while j < toks.count {
                let x = toks[j]
                if x.kind == .punct {
                    switch x.text {
                    case "(":
                        if depth == 0 && parenAt == nil { parenAt = j }
                        depth += 1
                    case ")": depth -= 1
                    case "{":
                        if depth == 0, parenAt != nil, !declStartsWith(toks, i, "struct") { isFunction = true }
                        depth += 1
                    case "}":
                        depth -= 1
                        if depth == 0 && isFunction { end = j + 1 }
                    case ";":
                        if depth == 0 { end = j + 1 }
                    default: break
                    }
                }
                if end != toks.count { break }
                j += 1
            }
            guard end <= toks.count, end > i else { throw Failure.malformed("unterminated declaration") }
            let decl = Array(toks[i..<end])
            i = end
            let words = decl.filter { $0.kind != .ws && $0.kind != .directive }
            guard let first = words.first else { continue }

            if first.text == "uniform" {
                let names = words.dropFirst().filter { $0.kind == .ident }.map(\.text)
                guard let type = names.first else { throw Failure.malformed("uniform") }
                for n in names.dropFirst() where !implicit.contains(n) {
                    guard uniformTypes.contains(type) else { throw Failure.unsupportedUniformType(type) }
                    uniforms.append(Uniform(name: n, type: type))
                }
                continue
            }
            if first.text == "varying" || first.text == "attribute" || (first.text == "in" && !isFunction)
                || (first.text == "out" && !isFunction) {
                // Interface variables: `out vec4 x;` is the output, `in`/`varying vec2 x;` the coordinate.
                let names = words.dropFirst().filter { $0.kind == .ident }.map(\.text)
                if names.count >= 2 {
                    let type = names[0]
                    for n in names.dropFirst() {
                        if first.text == "out" { body += "\n#define \(n) _FragColor\n" }
                        else if type == "vec2" { body += "\n#define \(n) _TexCoord\n" }
                    }
                }
                continue
            }
            if isFunction {
                if decl.contains(where: { $0.text == "glsl_main" }) { hasMain = true }
                body += rewriteParameters(decl)
            } else if parenAt != nil, words.last?.text == ";", isPrototype(words) {
                continue  // function prototype: members need none
            } else {
                body += decl.map(\.text).joined()
            }
        }
        guard hasMain else { throw Failure.missingMain }
        let source = mode == .transition ? assembleTransition(body: body, uniforms: uniforms)
            : assemble(body: body, uniforms: uniforms)
        return Output(source: source, uniforms: uniforms)
    }

    private static func declStartsWith(_ toks: [Token], _ i: Int, _ word: String) -> Bool {
        var j = i
        while j < toks.count, toks[j].kind == .ws || toks[j].kind == .directive { j += 1 }
        return j < toks.count && toks[j].text == word
    }

    /// `type name ( … ) ;` with only types/identifiers inside: a prototype, not a global with a constructor call.
    private static func isPrototype(_ words: [Token]) -> Bool {
        guard words.count >= 4, words[0].kind == .ident, words[1].kind == .ident, words[2].text == "(" else {
            return false
        }
        // `vec2 p = vec2(…);` has `=` before `(`.
        return !words.contains { $0.text == "=" }
    }

    /// Parameter qualifiers: `in` dropped, `out`/`inout` become `thread T&`.
    private static func rewriteParameters(_ decl: [Token]) -> String {
        guard let open = decl.firstIndex(where: { $0.text == "(" }) else { return decl.map(\.text).joined() }
        var depth = 0, close = open
        for k in open..<decl.count {
            if decl[k].text == "(" { depth += 1 }
            if decl[k].text == ")" { depth -= 1; if depth == 0 { close = k; break } }
        }
        var out = decl[..<open].map(\.text).joined() + "("
        // Split parameters on top-level commas.
        var params: [[Token]] = [[]]
        depth = 0
        for k in (open + 1)..<close {
            let t = decl[k]
            if t.text == "(" { depth += 1 }
            if t.text == ")" { depth -= 1 }
            if t.text == "," && depth == 0 { params.append([]) } else { params[params.count - 1].append(t) }
        }
        out += params.map { p -> String in
            let words = p.filter { $0.kind != .ws }
            let byRef = words.contains { $0.text == "out" || $0.text == "inout" }
            let kept = words.filter { !["in", "out", "inout"].contains($0.text) }
            guard byRef, kept.count >= 2 else { return kept.map(\.text).joined(separator: " ") }
            let typeWords = kept.dropLast().map(\.text).filter { $0 != "const" }
            return "thread " + typeWords.joined(separator: " ") + "& " + (kept.last?.text ?? "")
        }.joined(separator: ", ")
        out += ")" + decl[(close + 1)...].map(\.text).joined()
        return out
    }

    // MARK: Output

    /// Uniform members and the statements filling them from `wz_u.v[k]`.
    private static func uniformCode(_ uniforms: [Uniform]) -> (members: String, fill: String) {
        var members = ""
        for u in uniforms { members += "    \(u.type) \(u.name);\n" }
        var fill = ""
        for (k, u) in uniforms.enumerated() {
            let v = "wz_u.v[\(k)]"
            let expr: String = switch u.type {
            case "float": "\(v).x"
            case "vec2": "\(v).xy"
            case "vec3": "\(v).xyz"
            case "vec4": v
            case "int": "int(\(v).x)"
            case "ivec2": "int2(\(v).xy)"
            case "ivec3": "int3(\(v).xyz)"
            case "ivec4": "int4(\(v))"
            default: "(\(v).x != 0.0)"
            }
            fill += "    wz_p.\(u.name) = \(expr);\n"
        }
        return (members, fill)
    }

    /// GLSL type names, missing built-ins and the uniform block shared by both modes.
    private static let prelude = """
        typedef float2 vec2; typedef float3 vec3; typedef float4 vec4;
        typedef int2 ivec2; typedef int3 ivec3; typedef int4 ivec4;
        typedef bool2 bvec2; typedef bool3 bvec3; typedef bool4 bvec4;
        typedef uint2 uvec2; typedef uint3 uvec3; typedef uint4 uvec4;
        typedef float2x2 mat2; typedef float3x3 mat3; typedef float4x4 mat4;
        typedef float2x2 mat2x2; typedef float3x3 mat3x3; typedef float4x4 mat4x4;
        template<typename T, typename U> inline T mod(T x, U y) { return x - y * floor(x / y); }
        inline float atan(float y, float x) { return atan2(y, x); }
        inline float2 atan(float2 y, float2 x) { return atan2(y, x); }
        inline float3 atan(float3 y, float3 x) { return atan2(y, x); }
        inline float4 atan(float4 y, float4 x) { return atan2(y, x); }
        template<typename T> inline T inversesqrt(T x) { return rsqrt(x); }
        template<typename T> inline T radians(T d) { return d * (M_PI_F / 180.0); }
        template<typename T> inline T degrees(T r) { return r * (180.0 / M_PI_F); }
        #define gl_FragColor _FragColor
        #define texture2D texture2D_is_not_supported
        """

    /// A transition: `glsl_transition_fs` draws a full-texture pass (`fullscreen_vs`) with the
    /// outgoing frame in texture 0, the incoming one in texture 1 and `GLUniforms` in buffer 1
    /// (`sys` = progress, width px, height px, 0).
    private static func assembleTransition(body: String, uniforms: [Uniform]) -> String {
        let (members, fill) = uniformCode(uniforms)
        return """
        \(Shaders.common)
        \(prelude)
        #define getFromColor textureA
        #define getToColor textureB

        struct GLUniforms {
            float4 sys;   // progress, resolution w, h, 0
            float4 v[\(max(uniforms.count, 1))];
        };

        struct GLProgram {
            texture2d<float> wz_a;
            texture2d<float> wz_b;
            sampler wz_s;
            float _Progress;
            float _Time;
            float2 _TexCoord;
            float2 _ImageSize;
            float4 _FragColor;
            float4 gl_FragCoord;
            float4 textureA(float2 uv) { return fx_sample(wz_a, wz_s, uv); }
            float4 textureB(float2 uv) { return fx_sample(wz_b, wz_s, uv); }
        \(members)
        \(body)
        };

        fragment float4 \(Output.transitionFragmentName)(FSOut wz_in [[stage_in]], constant GLUniforms& wz_u [[buffer(1)]],
                                                 texture2d<float> wz_ta [[texture(0)]],
                                                 texture2d<float> wz_tb [[texture(1)]],
                                                 sampler wz_smp [[sampler(0)]]) {
            GLProgram wz_p = { wz_ta, wz_tb, wz_smp };
            wz_p._Progress = wz_u.sys.x;
            wz_p._Time = 0.0;
            wz_p._ImageSize = wz_u.sys.yz;
            wz_p._TexCoord = wz_in.uv;
            wz_p.gl_FragCoord = float4(wz_in.uv.x * wz_u.sys.y, (1.0 - wz_in.uv.y) * wz_u.sys.z, 0.5, 1.0);
            wz_p._FragColor = float4(0.0);
        \(fill)
            wz_p.glsl_main();
            return clamp(wz_p._FragColor, 0.0, 1.0);
        }
        """
    }

    private static func assemble(body: String, uniforms: [Uniform]) -> String {
        let (members, fill) = uniformCode(uniforms)
        return """
        \(Shaders.common)
        typedef float2 vec2; typedef float3 vec3; typedef float4 vec4;
        typedef int2 ivec2; typedef int3 ivec3; typedef int4 ivec4;
        typedef bool2 bvec2; typedef bool3 bvec3; typedef bool4 bvec4;
        typedef uint2 uvec2; typedef uint3 uvec3; typedef uint4 uvec4;
        typedef float2x2 mat2; typedef float3x3 mat3; typedef float4x4 mat4;
        typedef float2x2 mat2x2; typedef float3x3 mat3x3; typedef float4x4 mat4x4;
        template<typename T, typename U> inline T mod(T x, U y) { return x - y * floor(x / y); }
        inline float atan(float y, float x) { return atan2(y, x); }
        inline float2 atan(float2 y, float2 x) { return atan2(y, x); }
        inline float3 atan(float3 y, float3 x) { return atan2(y, x); }
        inline float4 atan(float4 y, float4 x) { return atan2(y, x); }
        template<typename T> inline T inversesqrt(T x) { return rsqrt(x); }
        template<typename T> inline T radians(T d) { return d * (M_PI_F / 180.0); }
        template<typename T> inline T degrees(T r) { return r * (180.0 / M_PI_F); }
        #define gl_FragColor _FragColor
        #define texture2D texture2D_is_not_supported

        struct GLUniforms {
            float4 sys;   // time s, resolution w, h, 0
            float4 v[\(max(uniforms.count, 1))];
        };

        struct GLProgram {
            float _Time;
            float2 _TexCoord;
            float2 _ImageSize;
            float4 _FragColor;
            float4 gl_FragCoord;
        \(members)
        \(body)
        };

        fragment float4 \(Output.fragmentName)(VOut wz_in [[stage_in]], constant Quad& wz_q [[buffer(0)]],
                                               constant GLUniforms& wz_u [[buffer(1)]]) {
            GLProgram wz_p;
            float2 wz_g = clamp(wz_in.g, 0.0, 1.0);
            wz_p._Time = wz_u.sys.x;
            wz_p._ImageSize = wz_u.sys.yz;
            wz_p._TexCoord = float2(wz_g.x, \(Conventions.shaderTexCoordY ? "1.0 - wz_g.y" : "wz_g.y"));
            wz_p.gl_FragCoord = float4(wz_g.x * wz_u.sys.y, wz_g.y * wz_u.sys.z, 0.5, 1.0);
            wz_p._FragColor = float4(0.0, 0.0, 0.0, 1.0);
        \(fill)
            wz_p.glsl_main();
            float4 wz_c = clamp(wz_p._FragColor, 0.0, 1.0);
            return float4(wz_c.rgb * wz_c.a, wz_c.a) * wz_q.opacity;
        }
        """
    }

    // MARK: Lexer

    struct Token: Equatable {
        enum Kind { case ident, number, punct, ws, directive }
        var kind: Kind
        var text: String
    }

    /// Splits GLSL into identifiers, numbers, single-char punctuation, whitespace and
    /// preprocessor lines. Comments become whitespace. Concatenating the texts gives the
    /// program back (minus comments), so multi-char operators survive unchanged.
    struct Lexer {
        let s: [Character]
        init(_ src: String) { s = Array(src) }

        func tokens() -> [Token] {
            var out: [Token] = []
            var i = 0, lineStart = true
            while i < s.count {
                let c = s[i]
                if c == "/" && i + 1 < s.count && s[i + 1] == "/" {
                    while i < s.count && s[i] != "\n" { i += 1 }
                    continue
                }
                if c == "/" && i + 1 < s.count && s[i + 1] == "*" {
                    i += 2
                    while i + 1 < s.count && !(s[i] == "*" && s[i + 1] == "/") { i += 1 }
                    i += 2
                    out.append(Token(kind: .ws, text: " "))
                    continue
                }
                if c == "#" && lineStart {
                    var line = ""
                    while i < s.count {
                        if s[i] == "\\" && i + 1 < s.count && s[i + 1] == "\n" { line += " "; i += 2; continue }
                        if s[i] == "\n" { break }
                        line.append(s[i]); i += 1
                    }
                    out.append(Token(kind: .directive, text: line))
                    continue
                }
                if c.isWhitespace {
                    var w = ""
                    while i < s.count && s[i].isWhitespace { w.append(s[i]); if s[i] == "\n" { lineStart = true }; i += 1 }
                    out.append(Token(kind: .ws, text: w))
                    continue
                }
                lineStart = false
                if c.isLetter || c == "_" {
                    var w = ""
                    while i < s.count && (s[i].isLetter || s[i].isNumber || s[i] == "_") { w.append(s[i]); i += 1 }
                    out.append(Token(kind: .ident, text: w))
                    continue
                }
                if c.isNumber || (c == "." && i + 1 < s.count && s[i + 1].isNumber) {
                    var w = ""
                    while i < s.count {
                        let d = s[i]
                        if d.isNumber || d.isLetter || d == "." { w.append(d); i += 1; continue }
                        if (d == "+" || d == "-"), let last = w.last, last == "e" || last == "E", !w.hasPrefix("0x") {
                            w.append(d); i += 1; continue
                        }
                        break
                    }
                    out.append(Token(kind: .number, text: w))
                    continue
                }
                out.append(Token(kind: .punct, text: String(c)))
                i += 1
            }
            return out
        }
    }
}
