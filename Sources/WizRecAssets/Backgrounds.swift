import Foundation

/// A built-in animated background: our own GLSL fragment shader plus its parameters.
///
/// The shader follows the host convention of `docs/specs/shader-backgrounds.md` §2: implicit
/// `_TexCoord` (0…1, top-left origin, y down), `_Time` (seconds), `_ImageSize` (px) and
/// `_FragColor` (straight-alpha output); each parameter is a uniform `_<name>` (`vec4` for
/// colours, `float` for numbers). To place one in a project, write `shaderVidData()` into the
/// bundle as `fileName` (it is a regular source file, like any user media) and give the clip a
/// `SourceEffect` with `sourceEffectParameters`.
public struct BackgroundAsset: Sendable, Hashable, Identifiable {
    /// Library grouping.
    public enum Category: String, Sendable, CaseIterable {
        case gradients, patterns, abstract
    }

    /// Stable identifier, also the file's base name, e.g. `wizrec-aurora`.
    public var id: String
    public var displayName: String
    public var category: Category
    /// User-adjustable uniforms, in inspector order.
    public var parameters: [AssetParameter]
    /// Fragment shader (GLSL, no `#version`).
    public var glsl: String
    /// Natural size of the source, px (every background renders resolution-independently).
    public var width: Int = 1920
    public var height: Int = 1080

    public init(id: String, displayName: String, category: Category, parameters: [AssetParameter], glsl: String) {
        self.id = id; self.displayName = displayName; self.category = category
        self.parameters = parameters; self.glsl = glsl
    }

    /// File name to write `shaderVidData()` under, e.g. `wizrec-aurora.tscshadervid`.
    public var fileName: String { id + ".tscshadervid" }

    /// The `SourceEffect` parameter defaults for a clip playing this background, with colours
    /// split into `-red/-green/-blue/-alpha` (0–1) [shader-backgrounds.md §6].
    public var sourceEffectParameters: [PresetValue] { parameters.flatMap(\.projectDefaults) }

    /// The background as a shader-video file: `{name, version, width, height, effectDef, code,
    /// copyright}` [shader-backgrounds.md §1]. Our own content, so it carries no signature.
    /// Keys are sorted, so the bytes are deterministic.
    public func shaderVidData() throws -> Data {
        let defs: [[String: Any]] = parameters.map { p in
            var d: [String: Any] = ["name": p.name]
            switch p.defaultValue {
            case .color(let c):
                d["type"] = "Color"; d["value"] = String(c.hex.prefix(6))
            case .double(let v):
                d["type"] = "double"; d["defaultValue"] = v
                d["minValue"] = p.range?.lowerBound ?? v; d["maxValue"] = p.range?.upperBound ?? v
                if p.unit == .percentage || p.unit == .radians { d["unitType"] = p.unit.rawValue }
            case .bool(let b):
                d["type"] = "double"; d["defaultValue"] = b ? 1.0 : 0.0; d["minValue"] = 0.0; d["maxValue"] = 1.0
            case .position(let x, let y):
                d["type"] = "Position"; d["value"] = [x, y]
            }
            return d
        }
        let obj: [String: Any] = [
            "name": displayName, "version": "1.0", "width": width, "height": height,
            "effectDef": defs, "code": glsl,
            "copyright": "© 2026 Devs Wizard. WizRec, GPL-3.0-or-later.",
        ]
        return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    }
}

// Original backgrounds, written from scratch for WizRec.
enum BuiltInBackgrounds {
    private static func color(_ name: String, _ display: String, _ hex: String) -> AssetParameter {
        AssetParameter(name: name, displayName: display, kind: .color,
                       defaultValue: .color(AssetColor(hex: hex) ?? AssetColor(0, 0, 0)))
    }

    private static func number(_ name: String, _ display: String, _ value: Double, _ range: ClosedRange<Double>,
                               _ unit: AssetParameter.Unit = .none) -> AssetParameter {
        AssetParameter(name: name, displayName: display, kind: .double, defaultValue: .double(value),
                       range: range, unit: unit)
    }

    private static func speed(_ v: Double = 1) -> AssetParameter { number("Speed", "Speed", v, 0...5, .multiplier) }

    static let all: [BackgroundAsset] = [
        BackgroundAsset(id: "wizrec-gradient-drift", displayName: "Gradient Drift", category: .gradients, parameters: [
            color("Color0", "Color 1", "4F46E5"), color("Color1", "Color 2", "EC4899"),
            color("Color2", "Color 3", "06B6D4"), color("Color3", "Color 4", "1E1B4B"), speed(),
        ], glsl: """
        // Four colour points orbit slowly; each pixel blends them by inverse squared distance.
        uniform vec4 _Color0;
        uniform vec4 _Color1;
        uniform vec4 _Color2;
        uniform vec4 _Color3;
        uniform float _Speed;
        float wz_weight(vec2 uv, vec2 p, vec2 k) {
            vec2 d = (uv - p) * k;
            return 1.0 / (0.02 + dot(d, d));
        }
        void main() {
            float t = _Time * _Speed * 0.15;
            vec2 k = vec2(_ImageSize.x / max(_ImageSize.y, 1.0), 1.0);
            vec2 uv = _TexCoord;
            float wa = wz_weight(uv, vec2(0.5) + 0.35 * vec2(cos(t), sin(t * 1.3)), k);
            float wb = wz_weight(uv, vec2(0.5) + 0.35 * vec2(cos(t + 2.1), sin(t * 0.9 + 1.0)), k);
            float wc = wz_weight(uv, vec2(0.5) + 0.35 * vec2(cos(t + 4.2), sin(t * 1.1 + 2.0)), k);
            float wd = wz_weight(uv, vec2(0.5) + 0.35 * vec2(cos(t * 0.7 + 3.0), sin(t + 4.0)), k);
            _FragColor = (_Color0 * wa + _Color1 * wb + _Color2 * wc + _Color3 * wd) / (wa + wb + wc + wd);
        }
        """),
        BackgroundAsset(id: "wizrec-soft-waves", displayName: "Soft Waves", category: .gradients, parameters: [
            color("Color0", "Background", "0F172A"), color("Color1", "Near Wave", "38BDF8"),
            color("Color2", "Far Wave", "818CF8"), speed(), number("Waves", "Waves", 5, 1...6),
        ], glsl: """
        // Translucent wave layers stacked from the middle of the frame down.
        uniform vec4 _Color0;
        uniform vec4 _Color1;
        uniform vec4 _Color2;
        uniform float _Speed;
        uniform float _Waves;
        void main() {
            vec2 uv = _TexCoord;
            float t = _Time * _Speed;
            vec4 col = _Color0;
            for (int i = 0; i < 6; i++) {
                float fi = float(i);
                if (fi >= _Waves) { break; }
                float y = 0.35 + fi * 0.09 + 0.05 * sin(uv.x * (3.0 + fi) + t * (0.4 + 0.1 * fi) + fi * 1.7);
                float band = smoothstep(y, y + 0.004, uv.y);
                col = mix(col, mix(_Color1, _Color2, fi / 5.0), band * 0.35);
            }
            _FragColor = col;
        }
        """),
        BackgroundAsset(id: "wizrec-aurora", displayName: "Aurora", category: .abstract, parameters: [
            color("Color0", "Sky", "020617"), color("Color1", "Glow 1", "22C55E"),
            color("Color2", "Glow 2", "A855F7"), speed(), number("Intensity", "Intensity", 1, 0...2, .percentage),
        ], glsl: """
        // Three glowing curtains that sway and shimmer, with a soft tail upward.
        uniform vec4 _Color0;
        uniform vec4 _Color1;
        uniform vec4 _Color2;
        uniform float _Speed;
        uniform float _Intensity;
        void main() {
            vec2 uv = _TexCoord;
            float t = _Time * _Speed * 0.3;
            vec4 col = _Color0;
            for (int i = 0; i < 3; i++) {
                float fi = float(i);
                float centre = 0.3 + 0.12 * fi + 0.08 * sin(uv.x * 4.0 + t * (1.0 + 0.3 * fi) + fi * 2.0)
                             + 0.04 * sin(uv.x * 9.0 - t * 1.7 + fi);
                float d = uv.y - centre;
                float curtain = exp(-d * d * 120.0) * (0.6 + 0.4 * sin(uv.x * 30.0 + t * 3.0 + fi * 5.0));
                float tail = d < 0.0 ? exp(d * 6.0) * 0.35 : 0.0;
                vec4 c = mix(_Color1, _Color2, fi * 0.5);
                col.rgb += c.rgb * (curtain + tail) * _Intensity * 0.6;
            }
            col.rgb = clamp(col.rgb, 0.0, 1.0);
            _FragColor = col;
        }
        """),
        BackgroundAsset(id: "wizrec-bokeh", displayName: "Bokeh", category: .abstract, parameters: [
            color("Color0", "Background", "1C1917"), color("Color1", "Light 1", "F59E0B"),
            color("Color2", "Light 2", "FB7185"), speed(), number("Size", "Size", 1, 0.25...3, .multiplier),
        ], glsl: """
        // Soft discs of light drifting upward over a dark gradient.
        uniform vec4 _Color0;
        uniform vec4 _Color1;
        uniform vec4 _Color2;
        uniform float _Speed;
        uniform float _Size;
        float wz_hash(float n) { return fract(sin(n * 127.1) * 43758.5453); }
        void main() {
            float aspect = _ImageSize.x / max(_ImageSize.y, 1.0);
            vec2 uv = _TexCoord * vec2(aspect, 1.0);
            vec4 col = vec4(_Color0.rgb * mix(1.0, 0.7, _TexCoord.y), _Color0.a);
            float t = _Time * _Speed;
            for (int i = 0; i < 28; i++) {
                float fi = float(i);
                float r = (0.03 + 0.07 * wz_hash(fi + 3.0)) * _Size;
                float x = wz_hash(fi) * aspect + 0.03 * sin(t * 0.5 + fi);
                float rise = 0.02 + 0.05 * wz_hash(fi + 7.0);
                float y = 1.0 + r - fract(wz_hash(fi + 11.0) + t * rise) * (1.0 + 2.0 * r);
                float d = length(uv - vec2(x, y));
                float a = (1.0 - smoothstep(r * 0.85, r, d)) * (0.15 + 0.25 * wz_hash(fi + 5.0));
                vec4 c = mix(_Color1, _Color2, wz_hash(fi + 9.0));
                col.rgb = mix(col.rgb, c.rgb, a);
            }
            _FragColor = col;
        }
        """),
        BackgroundAsset(id: "wizrec-grid-horizon", displayName: "Grid Horizon", category: .patterns, parameters: [
            color("Color0", "Ground", "0B1026"), color("Color1", "Lines", "F472B6"),
            color("Color2", "Sky", "312E81"), speed(), number("Density", "Density", 1, 0.25...4, .multiplier),
        ], glsl: """
        // A perspective grid scrolling toward the viewer under a gradient sky.
        uniform vec4 _Color0;
        uniform vec4 _Color1;
        uniform vec4 _Color2;
        uniform float _Speed;
        uniform float _Density;
        void main() {
            vec2 uv = _TexCoord;
            float horizon = 0.45;
            vec4 col = mix(_Color2, _Color0, smoothstep(0.0, horizon, uv.y));
            float y = uv.y - horizon;
            if (y > 0.0) {
                float z = 0.08 / max(y, 0.001);
                float gx = uv.x - 0.5;
                gx = gx * z * 4.0 * _Density * 0.5;
                float gz = z * _Density + _Time * _Speed;
                float ex = 0.5 - abs(fract(gx) - 0.5);
                float ez = 0.5 - abs(fract(gz) - 0.5);
                float lx = 1.0 - smoothstep(0.0, fwidth(gx) * 1.5 + 0.0001, ex);
                float lz = 1.0 - smoothstep(0.0, fwidth(gz) * 1.5 + 0.0001, ez);
                float fade = smoothstep(0.0, 0.25, y);
                col = mix(col, _Color1, max(lx, lz) * fade);
            }
            col.rgb = clamp(col.rgb + _Color1.rgb * exp(-abs(y) * 40.0) * 0.5, 0.0, 1.0);
            _FragColor = col;
        }
        """),
        BackgroundAsset(id: "wizrec-stripes", displayName: "Moving Stripes", category: .patterns, parameters: [
            color("Color0", "Color 1", "FDE68A"), color("Color1", "Color 2", "FCD34D"), speed(),
            number("Width", "Stripe Width", 80, 10...400, .pixels),
            number("Angle", "Angle", Double.pi / 4, 0...(2 * Double.pi), .radians),
        ], glsl: """
        // Anti-aliased stripes sliding along their normal.
        uniform vec4 _Color0;
        uniform vec4 _Color1;
        uniform float _Speed;
        uniform float _Width;
        uniform float _Angle;
        void main() {
            vec2 p = _TexCoord * _ImageSize;
            vec2 dir = vec2(cos(_Angle), sin(_Angle));
            float s = dot(p, dir) / max(_Width * 2.0, 1.0) + _Time * _Speed * 0.5;
            float f = abs(fract(s) - 0.5) * 2.0;
            float aa = fwidth(s) * 2.0 + 0.0001;
            _FragColor = mix(_Color0, _Color1, smoothstep(0.5 - aa, 0.5 + aa, f));
        }
        """),
        BackgroundAsset(id: "wizrec-radial-pulse", displayName: "Radial Pulse", category: .patterns, parameters: [
            color("Color0", "Background", "111827"), color("Color1", "Rings", "10B981"), speed(),
            number("Rings", "Rings", 6, 1...20),
            number("MidPointX", "Centre X", 0.5, 0...1, .percentage),
            number("MidPointY", "Centre Y", 0.5, 0...1, .percentage),
        ], glsl: """
        // Rings travelling outward from a centre point, fading with distance.
        uniform vec4 _Color0;
        uniform vec4 _Color1;
        uniform float _Speed;
        uniform float _Rings;
        uniform float _MidPointX;
        uniform float _MidPointY;
        void main() {
            float aspect = _ImageSize.x / max(_ImageSize.y, 1.0);
            vec2 d = (_TexCoord - vec2(_MidPointX, _MidPointY)) * vec2(aspect, 1.0);
            float r = length(d);
            float w = sin(r * _Rings * 6.28318530718 - _Time * _Speed * 2.0) * 0.5 + 0.5;
            _FragColor = mix(_Color0, _Color1, w * exp(-r * 1.2));
        }
        """),
        BackgroundAsset(id: "wizrec-liquid", displayName: "Liquid", category: .abstract, parameters: [
            color("Color0", "Base", "0C4A6E"), color("Color1", "Flow", "2DD4BF"),
            color("Color2", "Highlight", "F0ABFC"), speed(), number("Scale", "Scale", 2.5, 0.5...8),
        ], glsl: """
        // Domain-warped value noise: slow liquid marbling.
        uniform vec4 _Color0;
        uniform vec4 _Color1;
        uniform vec4 _Color2;
        uniform float _Speed;
        uniform float _Scale;
        float wz_hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
        float wz_noise(vec2 p) {
            vec2 i = floor(p);
            vec2 f = fract(p);
            vec2 u = f * f * (3.0 - 2.0 * f);
            float a = mix(wz_hash(i), wz_hash(i + vec2(1.0, 0.0)), u.x);
            float b = mix(wz_hash(i + vec2(0.0, 1.0)), wz_hash(i + vec2(1.0, 1.0)), u.x);
            return mix(a, b, u.y);
        }
        float wz_fbm(vec2 p) {
            float v = 0.0;
            float a = 0.5;
            for (int i = 0; i < 5; i++) {
                v += a * wz_noise(p);
                p = p * 2.03 + vec2(1.7, 9.2);
                a *= 0.5;
            }
            return v;
        }
        void main() {
            float aspect = _ImageSize.x / max(_ImageSize.y, 1.0);
            vec2 p = _TexCoord * vec2(aspect, 1.0) * _Scale;
            float t = _Time * _Speed * 0.1;
            vec2 q = vec2(wz_fbm(p + vec2(0.0, t)), wz_fbm(p + vec2(5.2, 1.3) - t));
            float n = wz_fbm(p + 3.0 * q + vec2(t * 0.7, -t));
            vec4 col = mix(_Color0, _Color1, smoothstep(0.2, 0.8, n));
            _FragColor = mix(col, _Color2, smoothstep(0.55, 0.95, length(q) * 0.9) * 0.6);
        }
        """),
        BackgroundAsset(id: "wizrec-spotlight-glow", displayName: "Spotlight Glow", category: .gradients, parameters: [
            color("Color0", "Centre", "334155"), color("Color1", "Edge", "020617"), speed(0.5),
            number("Softness", "Softness", 0.8, 0.1...1.5),
        ], glsl: """
        // A soft radial glow that breathes slowly.
        uniform vec4 _Color0;
        uniform vec4 _Color1;
        uniform float _Speed;
        uniform float _Softness;
        void main() {
            float aspect = _ImageSize.x / max(_ImageSize.y, 1.0);
            float r = length((_TexCoord - 0.5) * vec2(aspect, 1.0));
            float inner = 0.1 + 0.04 * sin(_Time * _Speed);
            _FragColor = mix(_Color0, _Color1, smoothstep(inner, inner + _Softness, r));
        }
        """),
    ]
}
