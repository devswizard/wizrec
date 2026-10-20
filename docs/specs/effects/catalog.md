# Visual effect catalog: menu names, project names and defaults

This page lists every visual effect in Camtasia 2026.2.3's *Modify ▸ Add Effects ▸
Visual Effects* menu, with the `effectName` and default parameters Camtasia
writes when the effect is added.

Source: automated runtime observation, experiment EF0 (DECISIONS
2026-10-20). Each effect was added from the menu to its own 400×400 grey
still. Videos were used for the effects that need one. The project was then
saved, and the saved JSON was read. There were no exports and no binary
analysis.

Every value here is **[obs]** unless it is marked otherwise. Meanings and
units are [?] unless an effect spec in this folder settles them.

## Menu name → `effectName`

| Menu item | `effectName` | Notes |
|---|---|---|
| Background Removal | `BackgroundRemoval` | |
| Blend Mode | `BlendModeEffect` | |
| Blur Region | `BlurRegion` | |
| Border | `Border` | |
| CRT Monitor | `CRT Monitor` | The name contains a space [obs] |
| Color Adjustment | `ColorAdjustment` | |
| Color Tint | `Tonal` | |
| Colorize | `Colorize` | |
| Corner Rounding | `RoundCorners` | |
| Cursor Path Creator | `CursorPath` | Adds two keyframes, at 1 s and 2 s of the clip |
| Device Frame | `DeviceFrameEffect` | References a TechSmith frame by file name; WizRec must draw its own frames |
| Drop Shadow | `DropShadow` | |
| Freeze Region | `FreezeRegion` | Video only. The entry has its own `start`/`duration` window, in clip ticks: start 5 frames (117600000), duration 70 frames (1646400000), for a playhead 0.5 s into a 10 s clip [obs]. The rule that places this window is [?] |
| Glow | `Glow` | |
| Interactive Hotspot | (no effect entry) | Writes `attributes.hotspot` on the clip; `effectApplied` = `"Hot Spot"` |
| Keystroke | — | Disabled for stills and plain videos; probably needs a screen recording with a keystroke log [inf] |
| Mask | `Mask` | |
| Media Matte | `MediaMatte` | |
| Mosaic (the menu title ends in a space) | `Pixelate` | Video and still |
| Motion Blur | `MotionBlur` | |
| Motion Path | `MediaPath` | Adds two point keyframes, at 1 s and 2 s |
| Outline Edges | `Sketch` | |
| Reflection | `Reflection` | |
| Remove a Color | `ChromaKey` | |
| Sepia | `Sepia` | |
| Spotlight | `Spotlight` | |
| Static Noise | `Static Noise` | The name contains a space |
| Tiling | `Tiling` | |
| Torn Edge | `Torn Edge` | The name contains a space; its parameter keys are capitalised |
| Vignette | `Vignette` | Capitalised keys |
| Window Spotlight | — | Disabled for stills and plain videos; probably screen-recording-only [inf] |
| Clip Speed | (no effect entry) | Sets `metadata.clipSpeedAttribute` to true and `effectApplied` = `"Clip Speed"`; `scalar` stays 1 |
| *Modify ▸ Add Filter ▸ <name>* | `LutEffect` | `lutSource` = `"<name>.cube"` (a TechSmith LUT, referenced by name only); see below |

## Common observations

- Every entry has `effectName`, `bypassed` (false) and
  `category` = `"categoryVisualEffects"`, then `parameters` [obs].
- The clip's `metadata.effectApplied` is set to the `effectName` of the last
  effect added. For behaviours it is set to the behaviour name [obs].
- Most parameters are bare numbers. `LutEffect` writes its numeric
  parameters in the long form, with `interp: "linr"` and a `uiHints` object.
  `CursorPath` and `MediaPath` write point keyframes [obs]. Readers must
  accept both forms.
- Several colour effects share a tonal-range block: `channel` (0) plus
  `shadowRampStart`/`shadowRampEnd` (0) and
  `highlightRampStart`/`highlightRampEnd` (1) [obs]. Their meaning is in
  `ColorAdjustment.md` and `BlendModeEffect.md`.
- The colour-adjustment defaults (brightness 0.64, contrast 3.98,
  saturation 0) are those of the menu item. They are clearly a preset, not
  a "no change" setting [obs, one save; to be re-checked in a second EF0 run]. Readers must never assume an effect's default
  is the identity.

## Defaults as written

### `BackgroundRemoval`

- Clip `metadata.effectApplied`: `BackgroundRemoval` [inf: in the EF0 save a second effect was stacked on the same clip by a selection slip]; category `categoryVisualEffects`
- `alphaMaskQualityLevel`: 1
- `backgroundOpacity`: 0.0
- `blurBackgroundSigma`: 0.0
- `featherMaskSigma`: 0.0
- `aiModelSourceName`: "modnet"
- `redBlueSwapped`: 0

### `BlendModeEffect`

- Clip `metadata.effectApplied`: `BlendModeEffect`; category `categoryVisualEffects`
- `mode`: 12
- `intensity`: 1.0
- `invert`: 0
- `channel`: 0
- `shadowRampStart`: 0.0
- `shadowRampEnd`: 0.0
- `highlightRampStart`: 1.0
- `highlightRampEnd`: 1.0

### `BlurRegion`

- Clip `metadata.effectApplied`: `BlurRegion`; category `categoryVisualEffects`
- `mask-shape`: 1
- `mask-invert`: 0
- `sigma`: 15.0
- `color-red`: 1.0
- `color-green`: 1.0
- `color-blue`: 1.0
- `color-alpha`: 0.25
- `mask-blend`: -0.02
- `mask-rotation`: 0.0
- `mask-width`: 360.0
- `mask-height`: 360.0
- `mask-positionX`: 0.0
- `mask-positionY`: 0.0
- `mask-cornerRadius`: 0.0

### `Border`

- Clip `metadata.effectApplied`: `Border`; category `categoryVisualEffects`
- `enabled`: 1
- `color-red`: 1.0
- `color-green`: 1.0
- `color-blue`: 1.0
- `color-alpha`: 1.0
- `width`: 1.0
- `type`: 0

### `CRT Monitor`

- Clip `metadata.effectApplied`: `CRT Monitor`; category `categoryVisualEffects`
- `Warp`: 0.1
- `ScanlineBrightness`: 0.8
- `ScanlineSpacing`: 5.0
- `VignetteIntensity`: 0.2
- `VignetteShape`: 5.0
- `CornerRadius`: 0.0
- `Brightness`: 1.0
- `ChromaticShift`: 0.0

### `ColorAdjustment`

- Clip `metadata.effectApplied`: `ColorAdjustment`; category `categoryVisualEffects`
- `brightness`: 0.64
- `contrast`: 3.98
- `saturation`: 0.0
- `channel`: 0
- `shadowRampStart`: 0.0
- `shadowRampEnd`: 0.0
- `highlightRampStart`: 1.0
- `highlightRampEnd`: 1.0

### `Tonal`

- Clip `metadata.effectApplied`: `Tonal`; category `categoryVisualEffects`
- `intensity`: 0.5
- `desaturation`: 0.5
- `color-red`: 1.0
- `color-green`: 0.18
- `color-blue`: 0.33
- `color-alpha`: 1.0
- `colorLumaCutoff`: 1.0
- `secondColor-red`: 0.35
- `secondColor-green`: 0.34
- `secondColor-blue`: 0.84
- `secondColor-alpha`: 1.0
- `secondColorLumaCutoff`: 0.0
- `channel`: 0
- `shadowRampStart`: 0.0
- `shadowRampEnd`: 0.0
- `highlightRampStart`: 1.0
- `highlightRampEnd`: 1.0

### `Colorize`

- Clip `metadata.effectApplied`: `Colorize`; category `categoryVisualEffects`
- `enabled`: 1
- `color-red`: 0.0
- `color-green`: 1.0
- `color-blue`: 0.0
- `color-alpha`: 1.0
- `amount`: 1.0
- `mode`: 0
- `channel`: 0
- `shadowRampStart`: 0.0
- `shadowRampEnd`: 0.0
- `highlightRampStart`: 1.0
- `highlightRampEnd`: 1.0

### `RoundCorners`

- Clip `metadata.effectApplied`: `RoundCorners`; category `categoryVisualEffects`
- `radius`: 20.0
- `top-left`: 1.0
- `top-right`: 1.0
- `bottom-left`: 1.0
- `bottom-right`: 1.0

### `CursorPath`

- Clip `metadata.effectApplied`: `CursorPath`; category `categoryVisualEffects`
- `cursorLocation`: keyframed: [{"endTime": 705600000, "time": 705600000, "value": [80, 100, 0], "duration": 0}, {"endTime": 1411200000, "time": 1411200000, "value": [320, 300, 0], "interp": 
- `cursorOpacity`: 1.0
- `cursorScale`: 2.25
- `cursorTrackLevel`: 10000.0
- `cursorAction`: keyframed: [{"endTime": 0, "time": 0, "value": 0, "duration": 0}]
- `smoothCursorAcrossEditDuration`: 235200000
- `cursorImagePath`: "Mac/pointer"

### `DeviceFrameEffect`

- Clip `metadata.effectApplied`: `DeviceFrameEffect`; category `categoryVisualEffects`
- `deviceFrameSource`: "Desktop_1.mp4"

### `DropShadow`

- Clip `metadata.effectApplied`: `DropShadow`; category `categoryVisualEffects`
- `angle`: 5.49778714378214
- `enabled`: 1
- `offset`: 10.0
- `blur`: 10.0
- `opacity`: 0.4
- `color-red`: 0.1216
- `color-green`: 0.1216
- `color-blue`: 0.1216
- `color-alpha`: 1.0

### `Glow`

- Clip `metadata.effectApplied`: `Glow`; category `categoryVisualEffects`
- `radius`: 35.0
- `intensity`: 0.6

### `Mask`

- Clip `metadata.effectApplied`: `Mask`; category `categoryVisualEffects`
- `mask-shape`: 0
- `mask-opacity`: 0.0
- `mask-blend`: -0.02
- `mask-invert`: 0
- `mask-rotation`: 0.0
- `mask-width`: 360.0
- `mask-height`: 360.0
- `mask-positionX`: 0.0
- `mask-positionY`: 0.0
- `mask-cornerRadius`: 0.0

### `MediaMatte`

- Clip `metadata.effectApplied`: `MediaMatte`; category `categoryVisualEffects`
- `matteMode`: 1
- `intensity`: 1.0
- `trackDepth`: 10002

### `MotionBlur`

- Clip `metadata.effectApplied`: `MotionBlur`; category `categoryVisualEffects`
- `intensity`: 1.0

### `MediaPath`

- Clip `metadata.effectApplied`: `MediaPath`; category `categoryVisualEffects`
- `mediaLocation`: keyframed: [{"endTime": 705600000, "time": 705600000, "value": [0, 0, 0], "duration": 0}, {"endTime": 1411200000, "time": 1411200000, "value": [768, 432, 0], "interp": {"b
- `mediaPathAutoOrient`: 0

### `Sketch`

- Clip `metadata.effectApplied`: `Sketch`; category `categoryVisualEffects`
- `intensity`: 1.0
- `desaturation`: 1.0

### `Reflection`

- Clip `metadata.effectApplied`: `Reflection`; category `categoryVisualEffects`
- `distance`: 20.0
- `opacity`: 0.4

### `ChromaKey`

- Clip `metadata.effectApplied`: `ChromaKey`; category `categoryVisualEffects`
- `enabled`: 1
- `tolerance`: 0.1
- `softness`: 0.1
- `clrCompensation`: 0.0
- `defringe`: 0.0
- `color-red`: 0.0
- `color-green`: 1.0
- `color-blue`: 0.0
- `color-alpha`: 1.0
- `invertEffect`: 0.0

### `Sepia`

- Clip `metadata.effectApplied`: `Sepia`; category `categoryVisualEffects`
- `intensity`: 1.0

### `Spotlight`

- Clip `metadata.effectApplied`: `Spotlight`; category `categoryVisualEffects`
- `color-alpha`: 0.35
- `color-blue`: 1.0
- `color-green`: 1.0
- `color-red`: 1.0
- `brightness`: 0.5
- `concentration`: 0.4
- `opacity`: 0.1
- `positionX`: -200.0
- `positionY`: 200.0
- `directionX`: 0.0
- `directionY`: 0.0

### `Static Noise`

- Clip `metadata.effectApplied`: `Static Noise`; category `categoryVisualEffects`
- `Scale`: 4.0
- `Intensity`: 3.0
- `Speed`: 2.7

### `Tiling`

- Clip `metadata.effectApplied`: `Tiling`; category `categoryVisualEffects`
- `positionU.x`: 400.0
- `positionU.y`: 0.0
- `positionV.x`: 0.0
- `positionV.y`: 400.0

### `Torn Edge`

- Clip `metadata.effectApplied`: `Torn Edge`; category `categoryVisualEffects`
- `Top`: true
- `Right`: true
- `Bottom`: true
- `Left`: true
- `Color0-alpha`: 1.0
- `Color0-blue`: 1.0
- `Color0-green`: 1.0
- `Color0-red`: 1.0
- `Margin`: 0.0
- `Size`: 50.0
- `Taper`: 1.0
- `Blend`: 0.7
- `Amount`: 0.2
- `Jaggedness`: 0.3
- `Random`: 0.0

### `Vignette`

- Clip `metadata.effectApplied`: `Vignette`; category `categoryVisualEffects`
- `Amount`: -100.0
- `Size`: 50.0
- `Roundness`: 0.0
- `Feather`: 100.0

### `FreezeRegion`

- Clip `metadata.effectApplied`: `FreezeRegion`; category `categoryVisualEffects`; extra keys: `start`, `duration`
- `mask-shape`: 1
- `freezeEndFrame`: 0
- `mask-opacity`: 1.0
- `mask-blend`: -0.02
- `mask-invert`: 0
- `mask-rotation`: 0.0
- `mask-width`: 360.0
- `mask-height`: 360.0
- `mask-positionX`: 0.0
- `mask-positionY`: 0.0
- `mask-cornerRadius`: 0.0

### `Pixelate`

- Clip `metadata.effectApplied`: `Pixelate`; category `categoryVisualEffects`
- `intensity`: 0.25

### `LutEffect`

- Clip `metadata.effectApplied`: `LutEffect`; category `categoryVisualEffects`; extra keys: `metadata`
- `lutSource`: "Basic Black & White.cube"
- `lut_intensity`: 1.0 (long form, interp linr)
- `channel`: 0
- `shadowRampStart`: 0.0 (long form, interp linr)
- `shadowRampEnd`: 0.0 (long form, interp linr)
- `highlightRampStart`: 1.0 (long form, interp linr)
- `highlightRampEnd`: 1.0 (long form, interp linr)

