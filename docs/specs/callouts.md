# Spec: callouts (annotations)

Behavioural spec for `Callout` clips: the `def` object, the shape catalog,
fills, strokes, tails, text and rich-text runs.

This spec records keys, identifiers and value ranges only. No TechSmith
artwork (shape outlines, SVGs, preset colours) is copied. Every shape must be
drawn with WizRec's own vector geometry (`CLAUDE.md`, M5).

Tags: **[obs]** observed in files, **[inf]** inferred, **[?]** unknown.

## Evidence base

- **C1: 21 callouts in projects**, read in place:
  - ThemeEditorDemo (format 2.0): speech bubble, rectangles, text;
  - BlendModePreview: 6 ellipses;
  - GenericBehaviorPreview: 1 text callout;
  - the 7 DynamicCaption samples: 1 caption callout each.
- **C2: the bundle's annotation presets** (`AnnotationsBin/*/*.json`, 114
  files), read in place for key names, enum values and numeric ranges only.
  These are the gallery entries that Camtasia turns into a `def` when one is
  dragged onto the timeline [inf]. `AnnotationsBin/SketchMotion/` holds 20
  SVG files (names only).
- **C3: `calloutindices.plist`**, which maps each `kind` value to a gallery
  tab [obs].
- **No Camtasia render of any callout is available** (no thumbnails; see
  `effects/README.md`).

## 1. The clip

```
Callout {
  id, _type: "Callout", start, duration, mediaStart, mediaDuration, scalar,
  def: { … §2 … },
  attributes: { ident?, autoRotateText: true },
  parameters: { translation0/1, scale0/1, rotation2?, opacity?, geometryCrop0..3, sourceCrop0..3 },
  effects: [], metadata: { default-text?: <RTF>, default-*: …, effectApplied }, animationTracks
}
```

| Claim | Tag |
|---|---|
| The layer's natural size is `def.width × def.height`, in callout px; `scale0/1` and translation apply as for any clip (`transform.md`) | [inf, as stated in `transform.md` §2] |
| A callout has no source media. `mediaStart` is non-zero on several callouts (22–38 frames) and is meaningful only as the time origin of keyframes, including `textAttributes` keyframes | [obs values; inf meaning] |
| `attributes.autoRotateText` is `true` on all 21 callouts. Its meaning is [?]. It is probably whether text stays upright when the shape rotates | [obs/?] |
| `metadata.default-text` holds the text as RTF (Cocoa RTF, with the font table and `\fsN` in half-points). It is UI state; the render uses `def.text` plus `textAttributes` | [obs; inf] |

## 2. `def`: common keys

| Key | Type | Values / range | Meaning |
|---|---|---|---|
| `kind` | string | see §3 | Callout family |
| `shape` | string | see §3 | Geometry id |
| `style` | string | `basic`, `urban`, `abstract`, `bold`; `caption` for captions; `""` for non-remix kinds | Preset family. Whether style changes the geometry (beyond colours and stroke in the preset) is [?]; experiment CO1 |
| `width`, `height` | double | presets 180–420; projects 19–1804 | Box size in callout px |
| `fill-color-red/-green/-blue` | double | 0–1 | Fill colour [obs] |
| `fill-color-opacity` | double | 0–1 | Fill alpha [obs] |
| `fill-style` | string | `solid` (all 60 seen) | Other values (gradient?) [?] |
| `stroke-color-red/-green/-blue/-opacity` | double | 0–1 | Outline colour |
| `stroke-width` | double | 0, 2, 6 (shapes); 8 (arrows) | Outline width in callout px [inf] |
| `stroke-style` | string | `solid`, `dash`, `dot`, `dashdot`, `dashdotdot` | Dash pattern [obs values]. Dash lengths [?] |
| `corner-radius` | double | 6.0 (captions) | Box corner radius, px [inf] |
| `tail-x`, `tail-y` | double, or animatable `{defaultValue, interp: "eioe"}` on arrows | see §4 | Tail or arrow vector |
| `text` | string | UTF-8 | Plain text content; `""` for shape-only callouts |
| `font` | object | §5 | Base font |
| `textAttributes` | object | §5 | Rich-text runs |
| `horizontal-alignment` | string | `left`, `center` | Also `right` [inf] |
| `vertical-alignment` | string | `center` | Also `top`/`bottom` [inf] |
| `word-wrap` | double | 1.0 | Wrap text to the box width [inf] |
| `line-spacing` | double | 0.0 | Extra line spacing [inf] |
| `tracking` | double | 0.0 | Letter spacing [inf] |
| `resize-behavior` | string | `resizeText` | The text size adapts to the box (§5) [inf] |
| `enable-ligatures` | double | 1.0 | |
| `text-stroke-width` | double | 3–10 | Outline around glyphs, px [inf] |
| `text-stroke-color-red/-green/-blue/-alpha` | double | 0–1 | Glyph outline colour |
| `text-stroke-alignment` | double | 2.0 | Enum: inside, centre or outside [?] |
| `modifier` | string | `dynamicCaption` | Marks a dynamic caption (`captions.md`) |

### Colours in presets versus projects

- **Presets** write colours compactly:
  - `fill-color: "RRGGBB"` or `"RRGGBBAA"`; `"00000000"` means a
    transparent fill;
  - `stroke-color: "RRGGBB"`;
  - some keys are camelCase, e.g. `fillColorRed` in highlighter presets
    [obs].
- **Projects** always write the split 0–1 doubles, `fill-color-red`… [obs,
  C1].
- WizRec writes the project form. A reader should accept both [inf].

## 3. Catalog: `kind` and `shape`

### `kind` values

[obs, C2/C3]:

| `kind` | Gallery tab | Notes |
|---|---|---|
| `remix` | Callout, Shape, Arrow | Vector shapes with optional text: the main family |
| `TypeWinBlur` | Blur | Region blur: `intensity` (0.8125 in the preset), `blur-invert` (0/1), `width`, `height` |
| `TypeWinPixelate` | Pixelate | Region pixelate: `intensity` (0.33), `width`, `height` |
| `TypeWinHighlighter` | Highlighter | Translucent highlight: fill colour, `fill-color-opacity` (0.25–0.75), `fill-invert` |
| `TypeWinSpotlight` | Spotlight | Darkens everything except a region: `intensity` (0.5), with `width`/`height` animatable |
| `MacKey` | Keystroke | Keystroke callout: `keys`, `name`, `keyStyle` (0–4), `showKeyBackg`, `showKeyHint` |
| `MacSVG`, `TypeWinSVG` | SketchMotion | Animated hand-drawn strokes. Their project form is [?] |

- **Region kinds.** `TypeWin*` kinds work on the pixels **below** the
  callout inside its box, like an adjustment layer [inf]: blur, pixelate,
  highlight, or spotlight (inverted).
- **Shared keys.** Non-remix kinds still carry `shape: ""` and `style: ""`
  [obs].

### `shape` values (kind `remix`)

| Group | `shape` ids | Geometry (WizRec draws its own) |
|---|---|---|
| Plain shapes | `shape-rectangle`, `shape-ellipse`, `shape-star`, `shape-octagon`, `shape-triangle` | Fill the `width×height` box. Star point count [?] (5 assumed); triangle apex up [inf] |
| Text | `text` | No shape, only text in the box |
| Text in shapes | `text-rectangle` | A rectangle sized to the box, with text [inf] |
| Bubbles | `speech-bubble`, `speech-bubble2`, `thought-bubble`, `thought-bubble2` | A rounded or cloud body filling the box, plus a tail to (tail-x, tail-y) (§4). The "2" variants differ in body shape [?] |
| Text arrows | `text-arrow`, `text-arrow2` | A box with an arrow-shaped extension toward the tail point [inf] |
| Arrow / line | `arrow` | A stroke from the anchor to the tail point, with end caps `shape-anchor` / `shape-tail` |

Arrow end caps [obs, C2]:

- `shape-anchor` ∈ {`none`, `arrow`, `diamond`, `circle`, `square`,
  `fletching`, `rounded`, `base`};
- `shape-tail` ∈ {`arrow`, `none`}.

Cap sizes in relation to `stroke-width` are [?].

## 4. Tails and arrow geometry

| Claim | Tag |
|---|---|
| `tail-x`, `tail-y` give the tail tip **relative to the callout centre, in callout px, +y up** | [inf] Every speech-bubble preset has `tail-y` between −240 and −20 (tails point down, below the box, as is usual for bubbles). The project bubble (332.8×182.3) has its tip at (−168.5, −185.5): below-left, outside the box |
| On `arrow`, the line runs from the callout origin, the anchor at (0, 0), to (tail-x, tail-y). Presets use (100, 0), a 100-px rightward arrow. Both coordinates are **animatable parameters** (`{defaultValue, interp: "eioe"}`) inside `def` | [obs values; inf geometry] Experiment CO2 |
| An arrow callout has no `width`/`height` in its presets; its extent comes from the tail vector and the stroke | [obs, C2] |
| Tails move with the callout's transform | [inf] |

## 5. Text

### `font` (the base style)

| Key | Values | Meaning |
|---|---|---|
| `name` | "Montserrat", "Bebas Neue", … | Family name [obs] |
| `weight` | "Regular" | Weight name [obs] |
| `size` | 64–140 | Base size [obs]. **Overridden by `textAttributes.fontSize`** where present (below) |
| `color-red/-green/-blue` | 0–1 | Text colour |
| `color-opacity` | 0–1 | Text alpha (newer files) |
| `tracking`, `leading` | 0.0 | Letter and line spacing |

### `textAttributes` (rich-text runs)

```
textAttributes: {
  type: "textAttributeList",
  keyframes: [ { time, endTime?, duration, value: [ run, … ] | null } ]
}
run = { name, rangeStart, rangeEnd, value, valueType }
```

| Claim | Tag |
|---|---|
| Each run applies one attribute to the characters `[rangeStart, rangeEnd)` of `def.text` | [obs] the ranges equal the text length (3, 4, 5 and 8 characters) |
| Whether the indices count UTF-16 units or grapheme clusters is [?]. Assume UTF-16, because the writer is Cocoa | [inf] |
| Attribute names and value types: `fontName` (string), `fontSize` (double), `fontWeight` (int: 100, 400, 700), `fontItalic` (int 0/1), `underline` (int 0/1), `strikethrough` (int 0/1), `fgColor` (color string `"(r,g,b,a)"`, 0–255), `kerning` (double) | [obs] |
| `value: null` is used when the text is empty (shape-only callouts) | [obs] |
| The `keyframes` list allows text styling to change over time. Every observed list has one keyframe at `time` 0 | [obs] |
| **Rendered size = the run's `fontSize`, not `font.size`.** With `resize-behavior: "resizeText"`, Camtasia stores the size that fits the text to the box. For example, "Camtasia" in a 240×128 box gets `fontSize` 39 while `font.size` and the RTF say 96; a 3-character caption in a 1804×387 box gets 261 | [obs values; inf meaning] |
| Font-size units: points equal to callout px at scale 1 | [inf] Experiment CO1 |

### Layout

1. Lay text out in the box (`width × height`), with padding [?].
2. Wrap at the box width when `word-wrap` is 1.
3. Align with `horizontal-alignment` and `vertical-alignment`.
4. Use the box's centre as the layer origin.

### Fonts

- The fonts used by samples and presets (Montserrat, Bebas Neue, Lato,
  Barlow Condensed, Caveat, Dosis, Cormorant Infant, …) are open-licence
  families that Camtasia ships in `Resources/fonts`.
- WizRec must bundle **its own upstream copies** (from the original OFL
  sources), never files from Camtasia's bundle. Otherwise it falls back to
  the system font with the same family name [inf].

## 6. Rendering order inside a callout

1. Shape fill.
2. Shape stroke.
3. Tail, joined with the body so the outline is continuous [inf].
4. Text fill, with the text stroke behind or around the glyphs as set by
   `text-stroke-alignment`.
5. Clip effects (shadow and so on) on the result.

[inf]

## 7. Experiments

Save into `~/WorkDir/vibe_coding/camtasia_rea_refs/research/callouts/`.

- **CO1: shape sheet** (qa generates it from §2–§3; the user opens it,
  saves it and exports a PNG frame).
  - Canvas 1920×1080, white.
  - A 4×5 grid with one `remix` callout per cell: each shape id in §3 at
    240×160, at stroke width 6 and fill `#3366CC`.
  - The `text` and `text-rectangle` cells hold "Ag Wy 123" in Montserrat
    at `fontSize` 48 with no resize.
  - Repeat `shape-rectangle` and `speech-bubble` with each style (`basic`,
    `urban`, `abstract`, `bold`) to see whether style changes geometry.
- **CO2: tails and arrows.**
  - Three `speech-bubble` callouts with tails at (0, −200), (200, 0) and
    (−150, 150).
  - Three `arrow` callouts with tail (300, 0) and the anchors `arrow`,
    `circle` and `diamond`.
  - Stroke styles `dash`, `dot`, `dashdot` and `dashdotdot` on four
    rectangles.
- **CO3: region callouts (UI).** In Camtasia, drag a Blur, a Pixelate, a
  Highlighter, a Spotlight, a Keystroke and one SketchMotion item over the
  M-card test card. Save as `co3-regions.cmproj` with the playhead over
  them. This gives their project form, which is [?] for SketchMotion.
