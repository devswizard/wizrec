# Spec: shader backgrounds (`.tscshadervid`, `SourceEffect`)

Behavioural spec for animated backgrounds: what a `.tscshadervid` file holds,
which inputs its shader expects from the host, how the clip's `SourceEffect`
parameters feed it, and its time base.

Black-box only. Sources: the user's demo project and its copy of one shader
file, plus the 58 `.tscshadervid` files inside the Camtasia 2026.2.3 bundle,
read in place. Shader files are TechSmith content. This spec describes their
**interface** (key names, identifier names, types, counts) in our own words.
It contains no shader code. WizRec must never ship these files; it renders
one only when a user's project references it (see `CLAUDE.md` rule 3).

Tags: **[obs]** observed in files, **[inf]** inferred, **[?]** unknown.

## Evidence base

- **S1: the demo project.** Group 4 holds `VMFile` 5 on track 0. It plays
  source 1, `./media/<ts>/cooltonesshifting.tscshadervid` (`rect` 1920×1080).
  The clip starts at 0 with `mediaStart` 0 and has no transform keys.
- **S2: the demo `ProjectThumbnail`.** A 640×360 PNG rendered by Camtasia.
  `docPrefs` → `DocPrefPlayheadTime` = 8537760000 ticks = **12.1 s**. The
  background is visible in the strips left (x < 43) and right (x > 597) of
  the screen recording.
- **S3: the 58 bundled files and the user's copy** (59 files in all).
  Counted with a script that parses each JSON, strips comments from the
  shader text, and lists declared and used identifiers. Shader text is never
  printed or stored.

## 1. File format

A `.tscshadervid` file is a JSON object [obs, S3]:

| Key | Present | Meaning |
|---|---|---|
| `name` | 46 / 59 | Display name, e.g. "Cool Tones Shifting" [obs] |
| `version` | 59 | `1.0`, `1.1`, `1.2` or `1.3`. Some files write it as a string and some as a number [obs] |
| `width`, `height` | 59 | Always 1920 × 1080 [obs]. This is the source's natural size (`rect`) |
| `effectDef` | 59 | The list of user parameters (§3) |
| `code` | 59 | GLSL fragment shader body, with no `#version` line [obs] |
| `vertexCode` | 13 / 59 | An optional vertex shader (§5) |
| `numVertices` | 12 / 59 | The vertex count for a `vertexCode` draw (3006 … 600000) |
| `blend` | 8 / 59 | Only the value `"add"` was seen (§5) |
| `signature` | 59 | `{type: "ES512", value: <base64>}`, a signature over the file [obs]. WizRec ignores it [inf] |
| `copyright` | 53 / 59 | A text line |

- **Encoding.** Files are not always UTF-8: 38 of 59 contain a Latin-1 `©`
  byte (0xA9) inside `copyright` [obs]. Readers must fall back to Latin-1
  when UTF-8 decoding fails.
- **Project bundles.** When a shader background is added, the file is copied
  into the bundle under `media/<ts>/`, and `sourceBin[].src` points at that
  copy [obs, S1]. `clip.metadata.ShaderVidSource` records the absolute path it
  came from [obs]. The parent group's `metadata.RevBackground` names it
  relative to the bundle's resources, e.g. `backgrounds/<file>` [obs].

## 2. Host-provided inputs (implicit names)

These identifiers are used by shader code without being declared in it, or
are declared as uniforms with no matching `effectDef` entry. The host must
supply them [obs, S3: counts are files out of 59].

| Name | Kind | Files | Meaning |
|---|---|---|---|
| `_FragColor` | `vec4` output | 59 | The fragment's output colour [obs] |
| `_TexCoord` | `vec2` input | 59 | Normalised position on the frame: **(0, 0) at the top-left, +y down**, 1 at the right/bottom edge, sampled at pixel centres [obs, S2 below]. Files with their own `vertexCode` declare it as an output there |
| `_Time` | `float` | 59 (50 implicit, 9 declared as uniforms in `vertexCode`) | Time in **seconds** (§4) |
| `_ImageSize` | `vec2` | 37 (35 implicit, 2 declared) | The output frame size in pixels [inf: used only for aspect ratio and pixel-size maths] |
| `_OutputSize` | `vec2` uniform | 9 | Declared in particle `vertexCode`; the output size in pixels [inf] |
| `_ToRenderTarget` | `mat4` uniform | 9 | Declared in particle `vertexCode`; maps the shader's pixel space to clip space [inf] (§5) |

The fragment shaders use no other built-ins: no `gl_FragCoord`, no texture
sampling and no samplers. One file family uses `fwidth` [obs]. A background
therefore depends only on `_TexCoord`, `_Time`, `_ImageSize` and its
parameters.

### Evidence that `_TexCoord` is top-left, y-down

We re-evaluated the user's copy of the demo shader ourselves at the four
canvas corners and at 1,020 points in the visible strips. We used the
project's parameter values and compared the result against S2 [obs]:

| Hypothesis | RMS error (0–255) |
|---|---|
| top-left origin, y down, colours mixed as stored (sRGB-encoded), `_Time` = 12.10 s | **0.24** |
| same, y up (v flipped) | 35.7 |
| top-left origin, mixing in linear light | 12.95 |
| `_Time` = 0 | 32.6 |
| `_Time` = 363 (frames) | 55.5 |
| `_Time` = 12100 (ms) | 42.8 |

Corner check at 12.1 s, as predicted / measured RGB:

- top-left: (94, 12, 187) / (94, 12, 187)
- bottom-left: (38.2, 88.2, 127.5) / (38, 88, 127)
- top-right: (46.2, 51.1, 190.1) / (46, 51, 190)
- bottom-right: (17.7, 112.7, 157.9) / (18, 113, 158)

Using the pixel centre (`(x + 0.5) / W`) fits slightly better than the pixel
edge (0.239 against 0.252) [obs, weak]. A blind search over 0–60 s in steps
of 0.02 s found its best fit at exactly 12.10 s [obs].

## 3. Parameters: `effectDef` in the file

Each entry in the file's `effectDef` has a `name`, a `type`, and either a
`value` or a set of bounds [obs, S3: 472 entries]:

| `type` | Count | Value form in the file | Uniform in code |
|---|---|---|---|
| `Color` | 172 | `value`: a 6-hex-digit RGB string such as `"5E0CBB"` (2 files write 7 characters) | `vec4 _<name>` |
| `double` | 287 | `defaultValue`, `minValue`, `maxValue`, either directly or inside `valueBounds: {…}` | `float _<name>` |
| `Position` | 13 | `value`: `[x, y]` in pixels of the 1920×1080 frame, e.g. `[960, 540]` = centre. Values can lie far outside the frame (±5000) | `vec2 _<name>` |

- **Naming.** The uniform is the parameter name prefixed with `_`, e.g.
  `Color0` → `_Color0` and `Speed` → `_Speed`. Every `effectDef` name is used
  in the code under that form [obs: 0 exceptions].
- **Optional hints.** These appear on `double` entries:
  - `unitType`: `"percentage"` or `"radians"`;
  - `userInterfaceType`: `"directional"`, an angle dial;
  - `UIUnitType`: `"percentage"`, a variant spelling.
- **Undefined uniforms.** A few uniforms have no `effectDef` entry: `_Scale`
  in 7 files, and `_Height` and `_Random` in 1 each [obs]. Under GLSL rules an
  unset uniform reads 0. Whether Camtasia sets them is [?]; WizRec should use
  0 [inf].
- **Common names.** `Speed` appears in 58 files, `Color0`/`Color1` in 40,
  `Color2` in 21, `Color3` in 17, `MidPointX`/`MidPointY` in 16, `Angle` in
  15 and `MidPoint` in 14 [obs].

## 4. Time base (`_Time`)

| Claim | Tag |
|---|---|
| `_Time` is in **seconds** | [obs] S2: best fit 12.10 s, playhead 12.1 s |
| In the demo, `_Time` equals the timeline time, the clip-local time and the media time, because the clip starts at 0 with `mediaStart` 0. Which of the three Camtasia uses is not yet known | [?] Experiment SH1 |
| Working rule: `_Time` = the clip's **media time** in seconds, i.e. `mediaStart + (t − start) / scalar`, converted from ticks with `editRate`. This keeps a background continuous across a split | [inf] |
| `_Time` is continuous, not quantised to frames | [?] 12.1 s is itself a whole frame at 30 fps |
| The source is effectively endless: `sourceTracks[0].range` = `[0, 9223372036854775807]` with `editRate` 30 | [obs] S1 |
| `Speed` is an ordinary shader parameter that multiplies `_Time` inside the code. The host does not scale time | [obs] S3: `Speed` is a declared uniform in 58 files |

## 5. Vertex-shader backgrounds (particles)

13 files have a `vertexCode` [obs, S3]:

- **9 particle files** declare `_Time`, `_OutputSize` and `_ToRenderTarget`
  as uniforms, and build 6 vertices per quad from `gl_VertexID`. The quad
  index (`gl_VertexID / 6`) goes to the fragment stage as a flat `int`.
- **They draw `numVertices` vertices as a triangle list, with no vertex
  buffer** [inf from the 6-per-quad indexing]. Some counts are not multiples
  of 6, for example 100000; the remainder makes an incomplete primitive and
  is dropped [inf].
- **Blending.** With `blend: "add"`, fragments are added onto the target
  (additive, for glows) [inf]. With no `blend` key the blend is normal
  source-over [inf]. What the target holds before the draw is [?]:
  transparent or black. Experiment SH2.
- **4 files** use their `vertexCode` only to cover the whole frame. They
  derive a full-screen quad from the low bits of `gl_VertexID` [obs]. Three
  of them still declare `numVertices` 600000 with no `blend`; extra
  vertices only redraw the same quad [inf]. For these files `_TexCoord`
  comes from the vertex stage.
- **Files with no `vertexCode`** (46 of 59): the host draws one full-frame
  quad and supplies `_TexCoord` as in §2 [inf].

### How WizRec draws particle files (S3-REN-2, 2026-10-19)

These are WizRec's own choices, made without Camtasia reference renders.
SH2 should confirm them. The code is in `GLSLParticles.swift` and
`ShaderBackgrounds.encodeParticles`.

- **Pixel space** [WizRec]:
  - `_OutputSize` (and `_ImageSize`) is the file's natural size (1920×1080),
    not the output size, so particles keep their size relative to the frame
    at any export resolution.
  - The pass renders at the layer's on-target size.
- **`_ToRenderTarget`** [WizRec, from observation]: the matrix maps
  natural pixels to clip space, with the origin at the top-left and +y down,
  like `_TexCoord`. It is applied as `vec4(p, 0, 1) * M`.
  - Evidence: the 9 installed `_ToRenderTarget` files were rendered in
    place. With this layout their stars and dots fill the frame.
  - With the column-vector layout (`M * p`) the same files light 0–9 of
    129,600 sampled pixels.
- **Vertices** [WizRec]:
  - `numVertices` are drawn as a triangle list, with a trailing partial
    triangle dropped.
  - A missing `numVertices` means 6 vertices, one quad.
  - Integer varyings are flat.
- **Target and blending** [WizRec]: the canvas starts transparent (SH2 is
  still [?]).
  - `blend: "add"` adds premultiplied colour (ONE, ONE).
  - Otherwise the blend is premultiplied source-over.
  - The result is composited like any layer.
- **Status**: all 13 installed `vertexCode` files translate, compile and
  draw [obs, 2026-10-19]. Each costs 0.4–1.9 ms of GPU time per 1080p frame.

## 6. The clip in the project

```
VMFile {
  src: <sourceBin id of the .tscshadervid>,
  trackNumber: 0,
  parameters: { geometryCrop0..3, … usual transform keys … },
  sourceEffect: {                      ← lower-case key, a single object
    effectName: "SourceEffect", bypassed: false, category: "",
    parameters: {
      "<Color>-red|-green|-blue|-alpha": animatable double 0–1,  (one per channel)
      "<double name>":                  animatable double,
      "sourceFileType": "tscshadervid"  (bare string)
    }
  },
  effects: [], metadata: { ShaderVidSource: <path> … }
}
```

[obs, S1]. Details:

- **Colours become four scalar parameters.** For `ColorN`, the parameters are
  `ColorN-red`, `ColorN-green`, `ColorN-blue` and `ColorN-alpha`, each a
  double from 0 to 1, so each channel can be keyframed separately [obs].
  - Each channel value is the hex byte divided by 255: `5E0CBB` gives
    0.368627450980392, 0.0470588235294118 and 0.733333333333333, with alpha
    1.0 [obs].
  - Build `vec4 _ColorN = (red, green, blue, alpha)` [inf].
- **Doubles keep their name**, e.g. `MidPointX`, `Speed`. They carry
  `uiHints {userInterfaceType, unitType}`, where `unitType` 1 means
  percentage [obs].
- **Position parameters** become **two** scalar parameters, `<name>.x` and
  `<name>.y` (with a dot), each `{type: "double", defaultValue, interp:
  "linr"}` and no `uiHints` [obs, SH2 2026-10-20: `dustmotes` `Pos` →
  `Pos.x` −5000, `Pos.y` 5000]. The file's 2-element `value` is the default.
  No z parameter is written.
- **Every parameter is animatable** with `interp: "linr"` [obs]. Evaluate it
  at the clip's time like any other parameter (`time-mapping.md` §6).
- **Missing parameter.** Use the file's `effectDef` default [inf]. For a
  colour, use the hex value with alpha 1.
- **`sourceBin` copy of the definitions.** The source entry keeps its own
  `effectDef` array, rewritten in the project's numeric form [obs, S1]:
  - `Color` entries carry `defaultValue: [r, g, b, a]` as doubles and
    `scalingType: 3`, `unitType: 0`, `userInterfaceType: 6`;
  - doubles carry `scalingType: 0` and `unitType: 1` for percentage;
  - the array ends with a synthetic entry, `{name: "sourceFileType", type:
    "string", defaultValue: "tscshadervid", …}`.

  Full code table [obs, SH2 2026-10-20: Camtasia imported three of its own
  backgrounds and saved]:

  | File hint | `type` in sourceBin | `scalingType` | `unitType` | `userInterfaceType` | Other |
  |---|---|---|---|---|---|
  | `Color` | "Color" | 3 | 0 | 6 | `defaultValue` [r, g, b, a] |
  | double, no hints | "double" | 0 | 0 | 0 | `minValue`/`maxValue` copied |
  | `unitType: "percentage"` | "double" | 0 | **1** | 0 | |
  | `unitType: "radians"` | "double" | 0 | **3** | (see next row) | |
  | `userInterfaceType: "directional"` | "double" | 0 | (as above) | **2** | A missing range is written as `minValue` 0.0, `maxValue` 0.0 |
  | `type: "Position"` | "Position" | **1** | 0 | **5** | `defaultValue` [x, y, **0.0**] (a z of 0 is appended) |
  | (synthetic last entry) | "string" | 0 | 0 | 0 | `name` "sourceFileType", `defaultValue` "tscshadervid", `minValue`/`maxValue` "" |

  On the clip, `uiHints` repeats `userInterfaceType` and `unitType` for
  doubles only (for example `{userInterfaceType: 2, unitType: 0}` on a
  directional double); colours and positions have no `uiHints` [obs].

  **Malformed colour strings.** One bundled file writes a colour as
  `" 130939"` (7 characters, with a leading space). Camtasia stored it as
  [0, 0.0745, 0.0353, 0.2235], that is, bytes 00 13 09 39. The text is read
  as one hexadecimal number laid out as RRGGBBAA, so the short value lands
  in green, blue and alpha [obs value; inf rule]. A well-formed 6-digit value
  gives RGB with alpha 1. WizRec should reproduce this so that such files
  look the same [inf].

  When WizRec writes a new shader source, it should copy this layout [inf].

## 7. Colour handling

| Claim | Tag |
|---|---|
| Colour uniforms are **straight (unpremultiplied) RGBA**, taken channel by channel from the parameters | [inf] All observed alphas are 1, so premultiplication is untestable here |
| Shaders mix colours **as stored, in sRGB-encoded space**, and the output is written straight to the sRGB frame with no linearisation | [obs] S2: RMS 0.24 against 12.95 for linear-light mixing |
| The output alpha is whatever the shader writes. With alpha-1 colours the background is opaque | [inf] |

## 8. Implementation notes for WizRec (GLSL → MSL)

- Wrap each fragment `code` in a generated entry point that declares
  `_TexCoord` (top-left, y-down, pixel centres), `_Time`, `_ImageSize`,
  `_FragColor` and one uniform per `effectDef` entry, and maps `fwidth`.
- `_ImageSize` should be the size of the actual render target, so the
  pattern scales with the output. When drawing at canvas resolution it is
  1920×1080 for every observed file [inf].
- The source frame is 1920×1080. The clip's transform places it like any
  video of that size (`transform.md` §2).

## 9. Experiments

These need Camtasia, and each takes a few minutes. For every experiment,
park the playhead where stated and use **File ▸ Save As**. The thumbnail
saved in the project is the reference render.

- **SH1: time origin.**
  1. New 1920×1080 project. Add the "Cool Tones Shifting" background at 0 s.
  2. Split it at 10 s and delete the left part, so `mediaStart` = 10 s.
  3. Drag the remaining clip so it starts at 20 s on the timeline.
  4. Park the playhead at 25 s.
  5. Save as `sh1-origin.cmproj`.

  The fitted `_Time` will then be 15 (media time), 5 (clip-local time) or 25
  (timeline time).
- **SH2: particle base.** Add "Star Field" (or any particle background) alone
  on a track, with the playhead at 3 s. Save as `sh2-particles.cmproj`.
- **SH3: position parameter.** Answered at file level by SH2 (§6). Its
  on-canvas mapping (which pixel `Pos` refers to) still needs a render [?].
- **Note (2026-10-20).** SH1 and the render half of SH2 relied on the saved
  `ProjectThumbnail` as a reference render. That is not allowed under the
  trial export gate (DECISIONS 2026-10-20), so they stay open: the `_Time`
  origin and the particle target's initial contents remain [?].
- **SH2 import facts** [obs]. A background dragged from the media bin onto
  the timeline becomes a 60 s clip. Its `metadata` gains `lockAspectRatio`
  true and `default-scale` "1". `sourceEffect.parameters` lists every
  `effectDef` entry with its default, in file order, and ends with
  `sourceFileType`.

## 10. Camtasia does not accept WizRec background files (acceptance check, 2026-10-20)

The files come from `wizrec-testgen shadervids`, which writes every
WizRecAssets background as a `.tscshadervid`. Camtasia 2026.2.3 was driven
by UI automation, with saves only.

| Test | Result | Tag |
|---|---|---|
| *File ▸ Import ▸ Media* of `wizrec-aurora.tscshadervid` | Alert "Import Error: The following files are not supported or damaged". Nothing is added | [obs] |
| Control: the same import of one of Camtasia's own bundled backgrounds | Accepted silently. Camtasia copies the file into the project's `media/<ts>/` folder and writes a full `effectDef` on the source (§6 layout) | [obs] |
| Opening a project whose `sourceBin` points to a WizRec background inside the bundle (otherwise identical to the control project) | The project opens with the alert "Files not supported: The following files are not supported by Camtasia Editor: wizrec-aurora.tscshadervid". The control project opens with no alert | [obs] |
| The same with `version` written as a number (1.0) instead of the string "1.0" | Still rejected | [obs] |
| Saving the project after the alert | The source entry is **kept**. Its `src` is rewritten to a relative path that points back into the *original* bundle, and the file is not copied into the new bundle. The rest of the project saves normally | [obs] |
| Cause | Every accepted file carries a vendor `signature` (ES512). A WizRec file has none, and the only other difference (the version's type) is ruled out. Camtasia evidently accepts only signed background files | [inf, strong] |

Consequences for WizRec:

- WizRec backgrounds **cannot** be made to play in Camtasia. Forging or
  copying a vendor signature is out of scope and is not attempted.
- A project that uses a WizRec background still opens in Camtasia. The user
  gets one "not supported" alert and the background clip shows as
  unavailable; all other content is intact [obs].
- When saving a project that uses a WizRec background, WizRec should warn
  that Camtasia will not show those backgrounds [inf].
- When WizRec opens a project that Camtasia re-saved, the background's `src`
  may point outside the bundle, at the earlier bundle's `media/` folder. The
  existing missing-media relink (`ProjectBundle.missingMedia()`) covers this
  [obs].
- WizRec must accept unsigned files itself and must ignore `signature`
  (§1).
