# Effects: Properties-panel parameters (names, ranges, units, keys)

What Camtasia 2026.2.3 shows in its Properties panel for each visual
effect, and which project key each control writes. Written in our own
words from the accessibility tree of the panel (labels, slider minimum and
maximum, field formats, pop-up entries, tooltips) and from save-only
experiments: type a value, *File ▸ Save*, diff the saved project.
Research backlog item 6 (RES15-1).

Tags: **[obs]** observed (panel or saved file), **[inf]** inferred,
**[?]** unknown. Evidence: RT-030 (`docs/ledger/EVIDENCE.md`).

Defaults are those written when the effect is added (`catalog.md`); this
page adds the UI side. "UI = f(stored)" gives the number the field shows.

## 1. Rules shared by every effect section

| Claim | Tag |
|---|---|
| Each effect gets a collapsible section headed by its menu name, with a **disable** check box (unchecked → `bypassed: true` on save), an options menu (*Add Preset*, *Delete Effect*) and, after the first edit, a reset button | [obs] |
| **Typed values are clamped to the slider range** (Border thickness 80 → 50, Corner Rounding radius 1500 → 1000, Motion Blur 250 % → 200 %, CRT warp 150 % → 100 %, Glow radius −5 → 0, Drop Shadow blur 99 → 50). Exception: Reflection distance accepted 150 although its slider ends at 100 | [obs] |
| **Display precision rounds the stored value**: fields shown as whole numbers (`+N`, `N%`) store the rounded integer (45.6 % → 0.46, radius 55.5 → 56, offset 12.7 → 13); two-decimal fields keep two decimals (12.345 → 12.34, 23.45 % → 0.2345); angles keep 0.1° (12.34° → 12.3° stored in radians) | [obs] |
| Stored values written from the UI are **single-precision numbers printed as doubles** (37 % → `0.370000004768372`). Readers must not assume short decimals | [obs] |
| **Angles** are shown in degrees and stored in radians, not normalised (−30° → −0.5236; 315° default = 5.4978) | [obs] |
| After the first edit of a parameter, the clip's `metadata` gains `default-<effectName>-<key>` = the previous value as a string (and `default-easeIn`/`default-easeOut` = "0") | [obs] |
| A session with edits can rewrite long-form parameters (`{type, defaultValue, interp, uiHints}`) as bare numbers, also on untouched clips of the same effect (two `LutEffect` clips) | [obs] |
| Colour wells show `#RRGGBB` and store `color-red/-green/-blue/-alpha` (0–1). The colour panel itself was not driven | [obs display; inf mapping] |

### Ease In / Ease Out (all effects with these fields)

| Claim | Tag |
|---|---|
| Two fields in seconds (`0s`, two decimals: 0.123 → 0.12 s); stepper range 0–10000 in 0.1 s steps (value 10 = 1 s), except Colorize: 0–100 (10 s) | [obs] |
| A non-zero value writes `leftEdgeMods` / `rightEdgeMods` on the effect entry: `[{group: "Video", duration: <ticks>, parameters: [...]}]`, duration = seconds × `editRate` (0.5 s → 352800000) | [obs] |
| Each listed parameter fades with `FadeInFunc`/`FadeOutFunc` (from 0 to the value and back) or `FadeFromValueFunc`/`FadeToValueFunc` with a `value` (from that value). The `value` is the parameter's **no-effect value**, so the ease fades the effect in and out (table below) | [obs] lists; [inf] meaning |
| Ease In + Ease Out are limited to the effect's own window: on a Freeze Region of 70 frames, In 1 s then Out 2 s gave Out 1.33 s | [obs] |
| Effects without ease fields: CRT Monitor, Remove a Color, Corner Rounding, Device Frame, Motion Blur, Static Noise, Tiling, Torn Edge, Vignette, Cursor Path, Motion Path | [obs] |

Ease parameter lists [obs]:

| Effect | Faded parameters |
|---|---|
| Background Removal | `blurBackgroundSigma` (In/Out), `featherMaskSigma` (In/Out), `backgroundOpacity` (FromValue/ToValue 1.0) |
| Blend Mode | `intensity` |
| Blur Region | `color-alpha` (value 0), `sigma` (value 0), both FromValue/ToValue |
| Border | `width` |
| Color Adjustment | `brightness` (In/Out), `contrast` (value 1), `saturation` (value 1) |
| Color Tint | `desaturation`, `intensity` |
| Colorize | `amount` |
| Drop Shadow | `opacity` |
| Glow | `intensity`, `radius` |
| Mask | `mask-opacity` (value 1) |
| Freeze Region | `mask-opacity` (value 0) |
| Media Matte | `intensity` |
| Mosaic (`Pixelate`) | `intensity` |
| Outline Edges (`Sketch`) | `desaturation`, `intensity` |
| Reflection | `opacity` |
| Sepia | `intensity` |
| Spotlight | `opacity` (value 1) |
| Color LUT (`LutEffect`) | `lut_intensity` |

### Range block (Blend Mode, Color Adjustment, Color Tint, Colorize, Color LUT)

| Claim | Tag |
|---|---|
| A *Range* pop-up of presets, a *Channel* pop-up (Grey, Red, Green, Blue) and a toggle that shows the advanced controls (a two-handle shadow ramp and a two-handle highlight ramp, labelled in 0–255) | [obs] |
| `channel`: Grey 0, Red 1; Green 2 and Blue 3 by order | [obs] Red; [inf] Green/Blue |
| Ramp labels = stored value × 255, rounded down (0.25 → 63, 0.4 → 102, 0.75 → 191) | [obs] one save |
| Presets → (`channel`, `shadowRampStart`, `shadowRampEnd`, `highlightRampStart`, `highlightRampEnd`): *All* (0,0,1,1); *Shadows* (0,0,0.25,0.5); *Midtones* (0.25,0.4,0.6,0.75); *Highlights* (0.5,0.75,1,1); the colour prefix only sets `channel` | [obs] Red Midtones saved; others [obs] labels, [inf] exact values (label 127 = 0.5, 153 = 0.6) |
| The highlight label is written "start \ end" when it falls (63 \ 127), "start / end" otherwise; the ramps fall off between the two values [inf] | [obs] labels |

## 2. Per effect

Columns: control (UI label) → key; UI range (slider) and format; UI =
f(stored); notes. All [obs] unless tagged.

### Background Removal (`BackgroundRemoval`)

| Control | Key | Range, format | UI = f(stored) |
|---|---|---|---|
| Opacity | `backgroundOpacity` | 0–100, `N%` | ×100 |
| Blur | `blurBackgroundSigma` | 0–100, integer | same |
| Feather | `featherMaskSigma` | 0–40, integer | same |

`alphaMaskQualityLevel`, `aiModelSourceName`, `redBlueSwapped` have no control [obs].

### Blend Mode (`BlendModeEffect`) — see `BlendModeEffect.md`

| Control | Key | Range, format | UI = f(stored) |
|---|---|---|---|
| Mode | `mode` | 31-entry pop-up | enum (`BlendModeEffect.md`) |
| Invert | `invert` | check box | 0/1; tooltip: swaps source and destination |
| Intensity | `intensity` | 0–100, `+N` | ×100 |
| Range block | §1 | | |

### Blur Region (`BlurRegion`)

| Control | Key | Range, format | UI = f(stored) |
|---|---|---|---|
| Blur | `sigma` | slider 0–100 shows `sigma`; **the field shows `sigma` × 10** (`150.0`, one decimal); typing 42 stored 4.2 | field ×10 |
| Tint (colour) | `color-red/-green/-blue` | colour well | — |
| Opacity (of the tint) | `color-alpha` | 0–100, `N%` | ×100 |
| Shape | `mask-shape` | Oval 0, Rectangle 1 | enum |
| Angle (dial + field) | `mask-rotation` | `N.N°` | degrees ↔ radians |
| Invert | `mask-invert` | check box | 0/1 |
| Corner | `mask-cornerRadius` | 0–200, `+N` | same |
| Feather | `mask-blend` | −100–100, `+N` | ×100 (7 → 0.07) |

`mask-width/height/positionX/Y` have no field: set on the canvas [inf].

### Border (`Border`) — see `Border.md`

| Control | Key | Range, format | UI = f(stored) |
|---|---|---|---|
| Color | `color-*` | colour well | — |
| Thickness | `width` | 0–50, integer | same |
| Use Alpha | **`type`** | check box | 0/1 (on → 1) |

### CRT Monitor (`CRT Monitor`)

| Control | Key | Range | UI = f(stored) |
|---|---|---|---|
| Warp | `Warp` | 0–1, `N%` (two decimals of %) | ×100 |
| Scanline Brightness | `ScanlineBrightness` | 0–1, `N%` | ×100 |
| Scanline Spacing | `ScanlineSpacing` | 1–30, `N.NN` | same |
| Vignette Intensity | `VignetteIntensity` | 0–1, `N%` | ×100 |
| Vignette Shape | `VignetteShape` | 1–10, `N.NN` | same |
| Corner Radius | `CornerRadius` | 0–1000, `N.NN` | same |
| Brightness | `Brightness` | 0–3, `N.NN` | same |
| Chromatic Shift | `ChromaticShift` | 0–100, `N.NN` | same |

### Color Adjustment (`ColorAdjustment`) — see `ColorAdjustment.md`

| Control | Key | Range, format | UI = f(stored) |
|---|---|---|---|
| Brightness | `brightness` | −100–100, `+N` | ×100 (−20 → −0.2; default +64 = 0.64) |
| Contrast | `contrast` | −75–300, `+N` | (stored − 1) × 100 (50 → 1.5; default +298 = 3.98) |
| Saturation | `saturation` | −100–100, `+N` | (stored − 1) × 100 (30 → 1.3; default −100 = 0) |
| Range block | §1 | | |

No-effect values: brightness 0, contrast 1, saturation 1 [obs from the ease `value`s].

### Color Tint (`Tonal`)

| Control | Key | Range, format | UI = f(stored) |
|---|---|---|---|
| Light Tone | `color-*` | colour well (#FF2E54) | — |
| Dark Tone | `secondColor-*` | colour well (#5957D6) | — |
| (swap button) | swaps the two colours | button | [obs] tooltip; keys [inf] |
| Intensity | `intensity` | 0–100, `+N` | ×100 |
| Desaturate | `desaturation` | 0–100, `+N` | ×100 |
| Range block | §1 | | |

Typing into the two fields did not take on this effect; setting the sliders did [obs]. `colorLumaCutoff` / `secondColorLumaCutoff` have no control [obs].

### Colorize (`Colorize`)

| Control | Key | Range, format | UI = f(stored) |
|---|---|---|---|
| Color | `color-*` | colour well | — |
| Intensity | `amount` | 0–100, `N%` | ×100 |
| Range block | §1 | | |

`enabled`, `mode` have no control [obs].

### Corner Rounding (`RoundCorners`) — see `RoundCorners.md`

| Control | Key | Range, format | UI = f(stored) |
|---|---|---|---|
| Corners | `top-left`, `top-right`, `bottom-left`, `bottom-right` | a 2×2 group of toggles (top row TL, TR; bottom row BL, BR), not exposed to accessibility | each click flips 1.0 ↔ 0.0 |
| Radius | `radius` | 0–1000, integer | same |

### Device Frame (`DeviceFrameEffect`)

| Control | Key | Values |
|---|---|---|
| Type | `deviceFrameSource` | pop-up: Desktop, Google Pixel, iPhone, MacBook Pro, *Remove Device Frames…* (disabled), *Download More…*. The value is a TechSmith asset file name; WizRec draws its own frames |

### Drop Shadow (`DropShadow`) — see `DropShadow.md`

| Control | Key | Range, format | UI = f(stored) |
|---|---|---|---|
| Angle (dial + field) | `angle` | `N.N°` | degrees ↔ radians (default 315°) |
| Color | `color-*` | colour well (#1F1F1F) | — |
| Offset | `offset` | 0–250, `+N` | same |
| Blur | `blur` | 0–50, `+N` | same |
| Opacity | `opacity` | 0–100, `N%` | ×100 |

### Freeze Region (`FreezeRegion`, video only)

| Control | Key | Range, format | UI = f(stored) |
|---|---|---|---|
| Shape | `mask-shape` | pop-up (Rectangle default = 1) | enum as Mask |
| Freeze end frame | `freezeEndFrame` | check box | 0/1 |
| Invert | `mask-invert` | check box | 0/1 |
| Rotate | `mask-rotation` | `N.N°` | degrees ↔ radians |
| Opacity | `mask-opacity` | 0–100, `N%` | ×100 |
| Blend | `mask-blend` | −100–100, `+N` | ×100 |
| Corner | `mask-cornerRadius` | 0–200, `+N` | same |

### Glow (`Glow`)

| Control | Key | Range, format | UI = f(stored) |
|---|---|---|---|
| Radius | `radius` | 0–100, `+N` | same |
| Intensity | `intensity` | 0–100, `+N` | ×100 |

### Color LUT (`LutEffect`, *Modify ▸ Add Filter*)

| Control | Key | Range, format | UI = f(stored) |
|---|---|---|---|
| LUT | `lutSource` | pop-up of 37 entries (TechSmith LUT names; not listed here) | file name + `.cube` |
| Intensity | `lut_intensity` | 0–1, `N%` | ×100 |
| Range block | §1 | | |

### Mask (`Mask`) — see `Mask.md`

| Control | Key | Range, format | UI = f(stored) |
|---|---|---|---|
| Shape | `mask-shape` | **Oval 0**, Rectangle 1 | enum |
| Invert | `mask-invert` | check box | 0/1 |
| Rotate | `mask-rotation` | `N.N°` | degrees ↔ radians |
| Opacity (outside the mask) | `mask-opacity` | 0–100, `N%` | ×100 |
| Blend | `mask-blend` | −100–100, `+N` | ×100 |
| Corner | `mask-cornerRadius` | 0–200, `+N`; **enabled only for Rectangle** | same |

### Media Matte (`MediaMatte`) — see `MediaMatte.md`

| Control | Key | Range | UI = f(stored) |
|---|---|---|---|
| Mode | `matteMode` | pop-up | enum (`MediaMatte.md`) |
| Intensity | `intensity` | 0–100, `+N` | ×100 |

`trackDepth` has no control [obs].

### Mosaic (`Pixelate`)

| Control | Key | Range, format | UI = f(stored) |
|---|---|---|---|
| Intensity | `intensity` | slider 0–1, field `N.N%` (one decimal) | ×100 (40.5 → 0.405) |

### Motion Blur (`MotionBlur`) — see `MotionBlur.md`

| Control | Key | Range, format | UI = f(stored) |
|---|---|---|---|
| Intensity | `intensity` | 0–200, `N%` | ×100 (150 % → 1.5) |

### Motion Path (`MediaPath`)

| Control | Key | Notes |
|---|---|---|
| Edit Motion Path | — | button: starts on-canvas path editing |
| Line Type | — | four toggles, disabled until a path point is selected [obs]; keys [?] |
| Easing | — | pop-up, disabled likewise [obs]; keys [?] |
| Auto Orient | `mediaPathAutoOrient` | check box 0/1; switching it on also wrote the clip's `rotation2` = 0.0 [obs] |

### Outline Edges (`Sketch`)

| Control | Key | Range, format | UI = f(stored) |
|---|---|---|---|
| Intensity | `intensity` | 0–100, `+N` | ×100 |
| Desaturate | `desaturation` | 0–100, `+N` | ×100 |

### Reflection (`Reflection`) — see `Reflection.md`

| Control | Key | Range, format | UI = f(stored) |
|---|---|---|---|
| Distance | `distance` | slider −100–100, `+N`; typed 150 was kept | same |
| Opacity | `opacity` | 0–100, `N%` | ×100 |

### Remove a Color (`ChromaKey`)

| Control | Key | Range, format | UI = f(stored) |
|---|---|---|---|
| Color | `color-*` | colour well (#00FF00) | — |
| Tolerance | `tolerance` | 0–100, `N%` | ×100 |
| Softness | `softness` | 0–100, `N%` | ×100 |
| Hue | `clrCompensation` | 0–100, `N%` | ×100 |
| Defringe | `defringe` | −100–100, `N%` | ×100 |
| Invert | `invertEffect` | check box | 0.0/1.0 (a double) |

### Sepia (`Sepia`)

| Control | Key | Range, format | UI = f(stored) |
|---|---|---|---|
| Intensity | `intensity` | 0–100, `+N` | ×100 |

### Spotlight (`Spotlight`)

| Control | Key | Range, format | UI = f(stored) |
|---|---|---|---|
| Color | `color-*` | colour well | — |
| Opacity (outside the light) | `opacity` | 0–100, `N%` | ×100 |
| Brightness | `brightness` | 0–10, `+N.NN` | ×10 (2.5 → 0.25; default 5 = 0.5) |
| Focus | `concentration` | 0–100, `+N` | ×100 |

`positionX/Y`, `directionX/Y` have no field: set on the canvas [inf].

### Static Noise (`Static Noise`)

| Control | Key | Range | UI = f(stored) |
|---|---|---|---|
| Scale | `Scale` | −2–6, `N.NN` | same |
| Intensity | `Intensity` | 0–10, `N.NN` | same |
| Speed | `Speed` | 0–4, `N.NN` | same |

### Tiling (`Tiling`)

No panel controls; `positionU.*` / `positionV.*` are set on the canvas [obs no controls; inf canvas].

### Torn Edge (`Torn Edge`)

| Control | Key | Range | UI = f(stored) |
|---|---|---|---|
| Top, Right, Bottom, Left | `Top`, `Right`, `Bottom`, `Left` | check boxes | JSON `true`/`false` |
| Color 1 | `Color0-red/-green/-blue/-alpha` | colour well | — |
| Margin | `Margin` | −200–200, `N.NN` | same |
| Size | `Size` | 0–500, `N.NN` | same |
| Taper | `Taper` | 0.01–10, `N.NN` | same |
| Blend | `Blend` | 0–1, `N%` | ×100 |
| Amount | `Amount` | −1–1, `N%` | ×100 |
| Jaggedness | `Jaggedness` | 0–1, `N%` | ×100 |
| Randomize | `Random` | 0–8000, `N.NN` | same |

### Vignette (`Vignette`)

| Control | Key | Range | UI = f(stored) |
|---|---|---|---|
| Amount | `Amount` | −100–100, `N.NN` | same |
| Size | `Size` | 0–100, `N.NN` | same |
| Roundness | `Roundness` | −100–100, `N.NN` | same |
| Feather | `Feather` | 1–400, `N.NN` | same |

### Cursor Path (`CursorPath`)

No panel controls besides the section header [obs]; its keyframes are set on the canvas [inf].

### Not studied

Keystroke and Window Spotlight (need a screen recording), cursor, audio and
gesture effects, and the colour panel behind the colour wells.

## 3. For WizRec (checklist, [inf])

- Show the same UI scale as Camtasia when the user edits a Camtasia
  project (×100 percentages, contrast/saturation offset by 1, Blur Region
  field ×10, Spotlight brightness ×10, degrees for angles), and clamp to the
  same ranges.
- Ease In/Out writes the edge-mod lists above; the fade target is the
  no-effect value.
- Write `default-<effect>-<key>` metadata only if we want Camtasia's reset
  buttons to work; it never changes the render.
