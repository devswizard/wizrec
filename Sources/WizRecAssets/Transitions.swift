import Foundation

// WizRec's own transition shaders, written from scratch for this project (GPL-3.0-or-later).
// The project `name` of each is the classic transition identifier of the project format
// (`docs/specs/transitions.md` §3.1), so a project made in WizRec names a transition other
// editors know; the look is ours.
//
// Host inputs (see `TransitionAsset`): `_Progress`, `_TexCoord` (top-left, y down),
// `_ImageSize`, `_FragColor`, `textureA(uv)` (outgoing), `textureB(uv)` (incoming). Colours
// from `textureA`/`textureB` are premultiplied and the output is premultiplied too.
// Every shader shows exactly A at progress 0 and exactly B at progress 1 (tested).
// GLSL subset: what RenderEngine's GLSL→MSL translator accepts (no samplers, no arrays).

enum BuiltInTransitions {
    static let all: [TransitionAsset] = [
        // Fades
        TransitionAsset(name: "Fade", displayName: "Fade", category: .fades, glsl: """
        void main() {
            _FragColor = mix(textureA(_TexCoord), textureB(_TexCoord), _Progress);
        }
        """),
        TransitionAsset(name: "Dissolve", displayName: "Dissolve", category: .fades, glsl: """
        void main() {
            float p = smoothstep(0.0, 1.0, _Progress);
            _FragColor = mix(textureA(_TexCoord), textureB(_TexCoord), p);
        }
        """),
        TransitionAsset(name: "FadeThroughBlack", displayName: "Fade Through Black", category: .fades, glsl: """
        void main() {
            float p = _Progress;
            vec4 c = p < 0.5 ? textureA(_TexCoord) : textureB(_TexCoord);
            float k = p < 0.5 ? 1.0 - p * 2.0 : p * 2.0 - 1.0;
            _FragColor = vec4(c.rgb * k, c.a);
        }
        """),
        TransitionAsset(name: "RandomDissolve", displayName: "Pixel Dissolve", category: .fades, glsl: """
        float wz_hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
        void main() {
            vec2 cell = floor(_TexCoord * _ImageSize / 6.0);
            float m = wz_hash(cell) < _Progress ? 1.0 : 0.0;
            _FragColor = mix(textureA(_TexCoord), textureB(_TexCoord), m);
        }
        """),

        // Wipes
        TransitionAsset(name: "GradientWipe", displayName: "Soft Wipe", category: .wipes, glsl: """
        void main() {
            float w = 0.2;
            float e = mix(-w, 1.0, _Progress);
            float m = 1.0 - smoothstep(e, e + w, _TexCoord.x);
            _FragColor = mix(textureA(_TexCoord), textureB(_TexCoord), m);
        }
        """),
        TransitionAsset(name: "RadialWipe", displayName: "Clock Wipe", category: .wipes, glsl: """
        void main() {
            vec2 d = _TexCoord - 0.5;
            float f = atan(d.x, -d.y) / 6.28318530718;
            if (f < 0.0) { f += 1.0; }
            float m = f < _Progress ? 1.0 : 0.0;
            _FragColor = mix(textureA(_TexCoord), textureB(_TexCoord), m);
        }
        """),
        TransitionAsset(name: "Wheel", displayName: "Wheel", category: .wipes, glsl: """
        void main() {
            vec2 d = _TexCoord - 0.5;
            float f = atan(d.x, -d.y) / 6.28318530718;
            if (f < 0.0) { f += 1.0; }
            float m = fract(f * 4.0) < _Progress ? 1.0 : 0.0;
            _FragColor = mix(textureA(_TexCoord), textureB(_TexCoord), m);
        }
        """),
        TransitionAsset(name: "BarnDoor", displayName: "Barn Door", category: .wipes, glsl: """
        void main() {
            float m = abs(_TexCoord.x - 0.5) * 2.0 < _Progress ? 1.0 : 0.0;
            _FragColor = mix(textureA(_TexCoord), textureB(_TexCoord), m);
        }
        """),
        TransitionAsset(name: "Blinds", displayName: "Blinds", category: .wipes, glsl: """
        void main() {
            float m = fract(_TexCoord.y * 10.0) < _Progress ? 1.0 : 0.0;
            _FragColor = mix(textureA(_TexCoord), textureB(_TexCoord), m);
        }
        """),
        TransitionAsset(name: "CheckerBoard", displayName: "Checkerboard", category: .wipes, glsl: """
        void main() {
            vec2 grid = vec2(10.0, 6.0);
            vec2 cell = floor(_TexCoord * grid);
            float odd = mod(cell.x + cell.y, 2.0);
            float q = clamp(_Progress * 2.0 - odd, 0.0, 1.0);
            float m = fract(_TexCoord.x * grid.x) < q ? 1.0 : 0.0;
            _FragColor = mix(textureA(_TexCoord), textureB(_TexCoord), m);
        }
        """),

        // Shapes
        TransitionAsset(name: "Iris", displayName: "Iris", category: .shapes, glsl: """
        void main() {
            float aspect = _ImageSize.x / max(_ImageSize.y, 1.0);
            vec2 d = (_TexCoord - 0.5) * vec2(aspect, 1.0);
            float maxR = length(vec2(aspect, 1.0) * 0.5) + 0.001;
            float m = length(d) < _Progress * maxR ? 1.0 : 0.0;
            _FragColor = mix(textureA(_TexCoord), textureB(_TexCoord), m);
        }
        """),
        TransitionAsset(name: "CircleReveal", displayName: "Circle Reveal", category: .shapes, glsl: """
        void main() {
            float aspect = _ImageSize.x / max(_ImageSize.y, 1.0);
            vec2 d = (_TexCoord - 0.5) * vec2(aspect, 1.0);
            float maxR = length(vec2(aspect, 1.0) * 0.5) + 0.001;
            float w = 0.15;
            float r = mix(-w, maxR, _Progress);
            float m = 1.0 - smoothstep(r, r + w, length(d));
            _FragColor = mix(textureA(_TexCoord), textureB(_TexCoord), m);
        }
        """),
        TransitionAsset(name: "Inset", displayName: "Inset", category: .shapes, glsl: """
        void main() {
            float s = max(smoothstep(0.0, 1.0, _Progress), 0.0001);
            vec2 o = vec2(1.0 - s);
            if (_TexCoord.x >= o.x && _TexCoord.y >= o.y) {
                _FragColor = textureB((_TexCoord - o) / s);
            } else {
                _FragColor = textureA(_TexCoord);
            }
        }
        """),

        // Slides
        TransitionAsset(name: "SlideLeft", displayName: "Slide Left", category: .slides, glsl: """
        void main() {
            float e = smoothstep(0.0, 1.0, _Progress);
            if (_TexCoord.x < 1.0 - e) {
                _FragColor = textureA(_TexCoord + vec2(e, 0.0));
            } else {
                _FragColor = textureB(_TexCoord + vec2(e - 1.0, 0.0));
            }
        }
        """),
        TransitionAsset(name: "SlideRight", displayName: "Slide Right", category: .slides, glsl: """
        void main() {
            float e = smoothstep(0.0, 1.0, _Progress);
            if (_TexCoord.x >= e) {
                _FragColor = textureA(_TexCoord - vec2(e, 0.0));
            } else {
                _FragColor = textureB(_TexCoord + vec2(1.0 - e, 0.0));
            }
        }
        """),
        TransitionAsset(name: "Stretch", displayName: "Stretch", category: .slides, glsl: """
        void main() {
            float s = smoothstep(0.0, 1.0, _Progress);
            float dx = _TexCoord.x - 0.5;
            if (abs(dx) < s * 0.5) {
                _FragColor = textureB(vec2(dx / max(s, 0.0001) + 0.5, _TexCoord.y));
            } else {
                _FragColor = textureA(_TexCoord);
            }
        }
        """),

        // 3D
        TransitionAsset(name: "CubeRotate", displayName: "Cube", category: .threeD, defaultDuration: 1.5, glsl: """
        // A unit cube turns left about the vertical axis: A on its front face, B on its right face.
        // Pushed back while turning so its near edge stays in the frame. Ray-cast per pixel.
        void main() {
            float e = smoothstep(0.0, 1.0, _Progress);
            float th = e * 1.57079632679;
            float c = cos(th), s = sin(th);
            float camD = 4.0;
            float dz = 0.41421356 * sin(2.0 * th);
            vec2 sp = _TexCoord * 2.0 - 1.0;
            vec3 o = vec3(0.0, 0.0, -camD - dz);
            vec3 dir = vec3(sp, camD - 1.0);
            // World → cube-local (inverse rotation about y).
            vec3 ol = vec3(o.x * c - o.z * s, o.y, o.x * s + o.z * c);
            vec3 dl = vec3(dir.x * c - dir.z * s, dir.y, dir.x * s + dir.z * c);
            float best = 1.0e9;
            vec4 col = vec4(0.0);
            if (abs(dl.z) > 1.0e-6) {
                float t = (-1.0 - ol.z) / dl.z;
                vec3 h = ol + t * dl;
                if (t > 0.0 && abs(h.x) <= 1.0 && abs(h.y) <= 1.0) {
                    best = t;
                    col = textureA(h.xy * 0.5 + 0.5) * vec4(vec3(mix(1.0, 0.55, s)), 1.0);
                }
            }
            if (abs(dl.x) > 1.0e-6) {
                float t = (1.0 - ol.x) / dl.x;
                vec3 h = ol + t * dl;
                if (t > 0.0 && t < best && abs(h.z) <= 1.0 && abs(h.y) <= 1.0) {
                    col = textureB(vec2(h.z, h.y) * 0.5 + 0.5) * vec4(vec3(mix(0.55, 1.0, s)), 1.0);
                }
            }
            _FragColor = col;
        }
        """),
        TransitionAsset(name: "Flip", displayName: "Flip", category: .threeD, glsl: """
        void main() {
            float e = smoothstep(0.0, 1.0, _Progress);
            float w = max(abs(cos(e * 3.14159265359)), 0.0001);
            float dx = _TexCoord.x - 0.5;
            if (abs(dx) < w * 0.5) {
                vec2 uv = vec2(dx / w + 0.5, _TexCoord.y);
                _FragColor = e < 0.5 ? textureA(uv) : textureB(uv);
            } else {
                _FragColor = vec4(0.0);
            }
        }
        """),
    ]
}
