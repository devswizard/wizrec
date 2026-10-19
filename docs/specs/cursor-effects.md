# Spec: cursor layer and cursor effects

How Camtasia draws a screen recording's cursor, and the parameters of every
cursor and click effect seen in projects or named in the bundle. For the
data the cursor layer is drawn from, see `trec.md`.

Tags: **[obs]** observed in files, **[inf]** inferred, **[?]** unknown.

## Evidence base

- **CE-demo: the user's demo project.** `ScreenVMFile` 6 (scale 0.5499) has
  `cursorScale` 2.25 and the effects `CursorColor`, `CursorMotionBlur`,
  `CursorShadow`, `CursorPhysics` and `LeftClickScaling`.
- **CE-thumb: the demo thumbnail at 12.1 s.** It shows the cursor as Camtasia
  drew it with those effects (`trec.md` R5).
- **CE-samples: CursorEffectPreview, LeftClickEffectPreview,
  RightClickEffectPreview and CursorPreview** (bundle, read in place).
  Clip-level cursor parameters are set, effects are `dummy` placeholders,
  and CursorPreview has a `CursorPath` effect on an image.
- **CE-bundle: resource names** (names only) and the parameter interfaces of
  `CursorEffects/*.tsceffect` and `ClickEffects/*.tsceffect` (names, types
  and ranges; no code).

## 1. The cursor layer

| Claim | Tag |
|---|---|
| The tscc2 pixels contain **no cursor**. At 12.1 s the frame around the logged hotspot is plain background | [obs] R1 frame crop |
| The cursor is drawn as an extra layer **on top of its own clip, inside the clip's transform**: it moves, scales and crops with the screen recording | [obs] CE-thumb: the tip lands where the clip transform puts the logged point (`trec.md` §2) |
| Position = the hotspot at the mapped point; image = the current cursor PNG (`trec.md` §3) | [obs] |
| Natural size: the PNG at video-pixel scale (its pixels match the capture's backing scale) × `cursorScale` × the clip's scale | [inf, rough] CE-thumb: arrow glyph 35 px tall in the image → ≈17 thumbnail px tall including the shadow; the prediction is 14.4 + ~2 px of shadow |
| Hotspot stays fixed under `cursorScale`; the image scales about the hotspot | [inf] CE-thumb tip position |

### Clip-level cursor parameters (on `ScreenVMFile`)

| Key | Values seen | Meaning |
|---|---|---|
| `cursorScale` | 2.25 (demo), 3.5 (3 samples), 5.0 (CursorPath) | Cursor size multiplier; 1 = recorded size [inf]. Animatable, `linr` |
| `cursorOpacity` | 1.0 | Cursor alpha, 0–1. Animatable [inf] |
| `cursorTrackLevel` | 0.0 (demo only) | [?] Possibly the cursor-smoothing level, i.e. how much the path is smoothed (0 = raw) |
| `smoothCursorAcrossEditDuration` | 0 (const) | Flag: when 1, the cursor glides smoothly across cuts between clips of the same recording, instead of jumping [inf from name] |

Missing keys default to 1, 1, 0 and 0 [inf].

## 2. Effects seen in projects

All use `category: "categoryCursorEffects"`. Parameters are animatable
doubles with `interp: "linr"` unless marked const [obs, CE-demo].

### `CursorShadow`

The same parameter set as `DropShadow` (`effects/DropShadow.md`), applied to
the cursor layer only:

| Key | Demo |
|---|---|
| `angle` | 3.92699081698724 (5π/4, down-left in the +y-up convention) |
| `offset` | 7.0 |
| `blur` | 10.0 |
| `opacity` | 0.5 |
| `color-red/-green/-blue/-alpha` | 0, 0, 0, 1 |
| `enabled` (const) | 1 |

In CE-thumb, dark pixels extend to the **left** of the yellow arrow and
below it, which fits a down-left shadow [obs, low resolution].

### `CursorColor`

| Key | Demo | Meaning [inf] |
|---|---|---|
| `color-red/-green/-blue/-alpha` | 0, 0, 0, 1 | First tint colour |
| `colorLumaCutoff` | 1.0 | Luma range assigned to the first colour |
| `secondColor-red/-green/-blue/-alpha` | 1, 0.898, 0.1216, 1 | Second tint colour (yellow) |
| `secondColorLumaCutoff` | 0.0 | Luma range assigned to the second colour |
| `intensity` | 1.0 | Mix with the original cursor |
| `desaturation` | 0.0 | Pre-tint desaturation |
| `channel`, `shadow/highlightRamp*` | 0; 0, 0, 1, 1 | Shared range block (`effects/ColorAdjustment.md`) |

- **Observed effect** [obs, CE-thumb]: the macOS arrow is a black fill with
  a white outline (verified in the recorded PNG). It renders with a
  **yellow fill and a dark outline**.
- So, in this configuration, **dark source pixels take `secondColor`** and
  light pixels take `color`.
- **Working model** [inf]: map luma to a two-stop gradient. The stop at
  `secondColorLumaCutoff` (0) gets `secondColor`, and the stop at
  `colorLumaCutoff` (1) gets `color`. Interpolate between them, keep the
  source alpha, then mix by `intensity`.

### `CursorMotionBlur`

| Key | Demo | Meaning |
|---|---|---|
| `intensity` | 1.0 (`uiHints` 1/1) | Blur along the cursor's motion between frames, in units of one frame of travel [inf] |

### `CursorPhysics`

| Key | Demo | Meaning [inf] |
|---|---|---|
| `intensity` | 1.5 | Strength of a lagging, spring-like follow of the logged path |
| `tilt` | 2.5 | How far the cursor image tilts (rotates) in proportion to its horizontal velocity |

The model is [?]. Experiment CE2.

### `LeftClickScaling`

| Key | Demo | Meaning [inf] |
|---|---|---|
| `scale` | 3.5 (`uiHints` 1/0) | Peak size multiplier at a left click |
| `speed` | 7.5 (`uiHints` 1/0) | Rate of the grow and shrink animation |

The cursor grows around each left-button-down (`trec.md` §4) and returns.
The curve is [?]; CE2.

### `CursorPath` (cursor on non-recording media)

On CursorPreview, an `IMFile` gets a synthetic cursor [obs]:

| Key | Value | Meaning |
|---|---|---|
| `cursorLocation` | `type: "point"`, keyframes with `value: [x, y, 0]` | Cursor position, interpolated between keyframes (`eioe` on the second keyframe) [obs]. Units: layer px with origin [?] |
| `cursorScale`, `cursorOpacity` | 5.0, 1.0 | As in §1 |
| `smoothCursorAcrossEditDuration` (const) | 0 | |
| `cursorImagePath` (const string) | `"Mac/pointer"` | Selects a built-in cursor image from Camtasia's resources (`Cursors/Native/<path>.png`) [inf]. WizRec maps such ids to its **own** cursor art |

`point` is a new parameter type: an array of 3 numbers per keyframe, with no
`defaultValue` [obs].

## 3. Effects known by name only (bundle resources)

Preview movies and icons exist for the following. Their project
`effectName` spelling and parameters are [?] until experiment CE1:

| Family | Names |
|---|---|
| Cursor | `CursorFXHighlight`, `CursorFXMagnify`, `CursorFXSpotlight`, `CursorFXReplace` (custom cursor image), `CursorSmoothing`, `CursorPath`, `CursorPhysics`, `CursorMotionBlur` |
| Clicks | `ClickScaling`, `ClickSound`, `LeftClickRings`, `LeftClickRipple`, `LeftClickScope`, `LeftClickTarget`, `LeftClickWarp`, and the same five as `RightClick…` |
| Gestures (mobile recordings) | `TapGesture`, `DoubleTapGesture`, `TapAndHoldGesture`, `SwipeGesture`, `PinchGesture` |

`ClickScaling` (resource) versus `LeftClickScaling` (project) shows that
project names can differ from resource names [obs].

### Shader cursor and click effects (`.tsceffect`, interface only)

These files use a different schema from transitions [obs]:

```
{ type: "cursor" | "click", version: 1.3, name | LEFT_name/RIGHT_name,
  textures: ["mediaTexture"], outputSize: {texture: "mediaTexture", padding: 0},
  parameters: [ {name, type, valueBounds{minValue,maxValue,defaultValue} | value | LEFT_value/RIGHT_value, unitType?, userInterfaceType?} ],
  code | fragmentCode }
```

- Click effects carry separate left and right names and colours
  (`LEFT_name` "LeftClickBurst1", `RIGHT_name` "RightClickBurst1";
  `LEFT_value` red, `RIGHT_value` blue) [obs]. These are probably the
  project `effectName`s [inf].
- **Host inputs** [obs: identifiers used but not declared, plus uniforms
  with no parameter entry]:
  - `mediaTexture(uv)`: samples the clip's frame;
  - `_TexCoord`;
  - `_FragColor`;
  - `_MediaTextureSize` (`vec2`, px);
  - `_Position` (`vec2`): the cursor or click position. Units are probably
    media-texture px [inf];
  - for clicks, `_Progress`: 0 → 1 over `clickDuration` seconds after the
    click [inf].
- Effects with **no `_Position` input** (`Cursor Isolation`) work on the
  whole frame.

| Effect | Parameters (name: type, min–max, default) |
|---|---|
| Cursor Isolation (`cursor`) | Opacity: % 0–1, 0.0 |
| Gradient (`cursor`) | Color0, Color1: Color; Opacity: % 0–1, 0.5; Radius: 0–500, 100; Feather: 0.5–20, 1; Angle: radians, directional, 0; CircularGradient: bool, false |
| Lens (`cursor`) | Radius: 0–500, 150; Power: −2–5, 2.5; Magnification: 0.1–8, 1.5 |
| Negative (`cursor`) | Radius: 0–500, 100; Feather: 0.5–20, 1; Red, Green, Blue: bool, true |
| Left/RightClickBurst1 | clickDuration: 0.1–3 s, 1.25; postClickPercent (hidden): 0–100, 100; Color; Scale: 0–10, 1; Count: 2–20, 6; Thickness: 0.1–10, 3 |
| …Burst2 | clickDuration 0.5; Scale 2; Length: 0–10, 5; Count 6; Thickness 3; Color |
| …Burst3 | clickDuration 0.6; Scale 2; Count 6; Thickness 3; Color |
| …Burst4 | clickDuration 0.6; InnerRadius: 0–200, 10; OuterRadius: 0–500, 120; Count: 2–20, 12; Thickness: 0–1, 0.5; Color |
| Left/RightClickZoom | clickDuration 0.6; Scale: −3–3, 1; Radius: 0–3000, 200; Color (black); Thickness: 0–10, 2 |

The ranges and defaults above are UI interface data. The looks are WizRec's
own designs, drawn from these parameters.

## 4. Order of operations (provisional)

1. Path: positions, then `CursorSmoothing` / `cursorTrackLevel`, then
   `CursorPhysics`.
2. Image: the current cursor PNG, or the replacement image.
3. Size: `cursorScale` × click scaling.
4. Colour: `CursorColor`.
5. Shadow and motion blur.
6. Composite onto the clip, inside the clip transform.
7. Frame-space effects (highlight, magnify, spotlight, lens, click bursts)
   apply to the clip's frame around `_Position` **before** the cursor is
   drawn on top.

[inf]

## 5. Experiments

Save into `~/WorkDir/vibe_coding/camtasia_rea_refs/research/cursor/`.

- **CE1: names and defaults (UI, about 5 minutes).**
  1. Make a new 10-s screen recording with a few clicks.
  2. Duplicate the clip onto 8 tracks.
  3. Apply one effect per copy, with default settings: Highlight, Magnify,
     Spotlight, Cursor Smoothing, Click Rings (left), Click Ripple (left),
     Click Burst 1 (left) and Lens.
  4. Save as `ce1-cursor.cmproj`.
- **CE2: motion (export).** Use one copy of the same recording.
  1. Apply Cursor Physics with its defaults and Left Click Scaling with its
     defaults.
  2. Export a 10-s MP4, `ce2-motion.mp4`.
  3. Repeat with Cursor Smoothing only: `ce2-smooth.mp4`.
- **CE3: CursorColor / shadow sheet** (qa generates it from the user's
  recording; the user opens it, saves it and exports one PNG frame).
  - The user's recording placed six times at scale 0.33.
  - Each copy has `cursorScale` 4 plus one of:
    - CursorColor with the demo values;
    - CursorColor with the two colours swapped;
    - CursorColor with `intensity` 0.5;
    - CursorShadow at angle 0, offset 20, blur 0;
    - `cursorScale` 1 with no effect (size reference);
    - `cursorScale` 4 with no effect.
