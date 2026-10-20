# Spec: clip geometry on the canvas (transform, crop, opacity)

Behavioural spec for placing a visual clip on the canvas. Black-box only:
derived from project JSON, the user's own media, and the Camtasia-rendered
project thumbnail stored in `metadata.ProjectThumbnail`.

Tags: **[obs]** observed in files, **[inf]** inferred, **[?]** unknown.

## Evidence base

- **E1 — demo project** (`~/Documents/demo project.cmproj`, Camtasia 2026.2.3,
  canvas 1920×1080). Group `4` (`widthAttr` 1920, `heightAttr` 1080, no
  transform keys) holds three tracks:
  - track 0: shader background `VMFile` 5, source 1920×1080, no transform keys;
  - track 1: `ScreenVMFile` 6, `.trec` stream 0 (3024×1964), `scale0/1` =
    0.54989816700611, `translation0` = −1.1e−13, no `translation1`;
  - track 2: `UnifiedMedia` 7 whose `video` (`VMFile` 8) is `.trec` stream 1
    (camera, `trackRect` 1920×1080, while the source `rect` is 3024×1964),
    `translation0/1` = (554.297629490835, −384.104025549898),
    `scale0/1` = 0.28869624898167, plus a `Mask` effect
    (`mask-width`/`mask-height` 1080, position 0,0).
- **E2 — demo `ProjectThumbnail`**: 640×360 PNG (scale 1/3 of the canvas)
  rendered by Camtasia. Edge positions measured by scanning pixel rows and
  columns for colour jumps.
- **E3 — survey of 24 projects** (demo, the user's vlog, 22 Camtasia sample
  projects read in place; formats 2.0–10.0, Mac and Windows writers). Counts
  below come from walking every clip, including clips nested in groups,
  stitched media and unified media.

## 1. Canvas coordinate system

| Claim | Tag | Evidence |
|---|---|---|
| Canvas size is top-level `width` × `height` (doubles, px). | [obs] | all projects |
| `translation0`/`translation1` are the offset of the layer's centre from the canvas centre, in canvas px. | [obs] | E1+E2, below |
| +x points right. | [obs] | E2: camera (tx = +554) is right of centre |
| **+y points up.** | [obs] | E2: camera (ty = −384) is in the bottom part of the image |
| Missing translation → 0 (layer centred). | [obs] | E2: screen recording (no `translation1`, tx ≈ 0) is centred: left edge at x = 43, right edge at x = 597 in the 640-px thumbnail; prediction 42.8 / 597.2 |

Conversion to a conventional top-left, y-down raster of the canvas:

```
x_px = W/2 + translation0
y_px = H/2 − translation1
```

Numeric check (E2, thumbnail scale s = 1/3):

| Feature | Predicted (thumbnail px) | Measured |
|---|---|---|
| Screen recording left / right edge | (960 ∓ 3024·0.549898/2)/3 = 42.85 / 597.15 | 43 / 597 |
| Camera mask centre x | (960 + 554.30)/3 = 504.77 | circle spans 453–556 on row 308 → 504.5 |
| Camera mask centre y (y-down) | (540 + 384.10)/3 = 308.03 | circle top at row 256, radius 52 → 308 |
| Camera mask diameter | 1080·0.288696/3 = 103.9 | 104 |

The camera also shows that the user snapped it to a corner, which only works
with the conventions above: its bottom edge is at
−384.104025549898 − 1080·0.28869624898167/2 = **−540.000000000000** (canvas
bottom, +y up), and its right edge at
554.297629490835 + 1920·0.28869624898167/2 = **831.446028513238**, which equals
the screen recording's right edge 3024·0.54989816700611/2 =
**831.446028513238** to all 15 digits [obs].

## 2. Layer size (the quad before transform)

| Clip | Natural size | Tag |
|---|---|---|
| `VMFile` / `ScreenVMFile` | **`sourceTracks[trackNumber].trackRect` w×h**, *not* the source `rect` when they differ | [obs] E1: the camera (stream 1 of a 3024×1964 `.trec`) only lands on the canvas corner with 1920×1080 (its `trackRect`). With 3024×1964 its bottom edge would be at −667 px. |
| `IMFile` | source `rect` w×h (= its single `sourceTracks[0].trackRect`) | [obs] |
| `UnifiedMedia` | its `video` child (geometry keys live on the child; the parent carries none) | [obs] vlog: 58/58 unified clips have `scale0/1` on `video` only |
| `StitchedMedia` | the segments' video size; geometry keys live on the **stitched parent**, segments carry only zero crops | [obs] vlog clips 72 and 82: parent `scale0/1` = 0.714285714285714, segment `video` children have no scale/translation |
| `Group` | `attributes.widthAttr` × `heightAttr` | [obs] demo (1920×1080). Format-2.0 groups (ThemeEditorDemo) have no `widthAttr`: use the project canvas [inf] |
| `Callout` | `def.width` × `def.height` | [inf] |
| `.tscshadervid` source | `rect` (= shader JSON `width`/`height`) | [obs] demo 1920×1080 |

For the source `rect` itself: it is `[0, 0, w, h]` in every source in E3, and
equals the `trackRect` of the source's first track (`[0, 0, 0, 0]` for
audio-only files) [obs].

## 3. Scale

| Claim | Tag | Evidence |
|---|---|---|
| `scale0` / `scale1` multiply the layer's natural width / height (px → canvas px). 1.0 = one source pixel per canvas pixel. | [obs] | E1/E2: 3024·0.549898 = 1663 px wide on canvas, measured 554 px in the 1/3 thumbnail (1662) |
| Missing scale → 1.0 (not "fit to canvas"). | [inf] | `DynamicCaptionPreview*`: 1920×1080 `VMFile` on a 1920×1024 canvas has no scale keys and `default-scale` "1"; demo shader `VMFile` 1920×1080 has no scale keys and fills the canvas in E2. In every observed clip with a non-1 `default-scale`, explicit `scale0/1` keys are present. |
| `scale0` = `scale1` in every observed clip (uniform scale), but they are stored separately; treat them independently. | [obs] | E3 |
| `scale2` was never observed as a parameter. | [obs] | E3 |
| Negative scale (flip) never observed. | [?] | |

### `metadata.default-scale`

- A string with ≤ 6 significant digits, e.g. `"0.592593"`, `"0.62439"`,
  `"0.714286"`, `"1"` [obs].
- It records the **fit-to-canvas scale when the media was added, capped at 1**:
  `min(1, W/w, H/h)` [inf, 8 of 10 distinct cases match]:
  384×216 on 240×128 → 0.592593 ✓; 384×205 → 0.62439 ✓;
  2688×1512 on 1920×1080 → 0.714286 ✓; 156×105 and 128×128 (smaller than the
  canvas) → 1 ✓ (no upscaling); 240×128 → 1 ✓.
  Exceptions: a 512×512 image on 240×128 says "1" (scale 0.2 set by hand), and
  1920×1080 on 1920×1024 says "1" (canvas likely resized after import).
- Callouts and some images use `default-scale0/1/2` objects
  (`{"type": "double", "value": 1.0}`) instead [obs].
- **Rendering must use `scale0/scale1` only.** `default-scale` is metadata
  (for a "reset size" command) and never changes the picture [inf].
- New media added by WizRec should get `scale0/1 = default-scale =
  min(1, W/w, H/h)` to match Camtasia's import behaviour [inf].

## 4. Rotation

| Claim | Tag | Evidence |
|---|---|---|
| `rotation2` is rotation about the screen-normal (Z) axis, **in radians**. | [obs] | MotionBlurPreview keyframes `rotation2` 0 → **−6.28318530717959** (exactly −2π: one full turn) |
| Sign: negative = clockwise as seen on screen (i.e. positive = counter-clockwise, the maths convention for +y up). | [inf, weak] | The same clip moves right (`translation0` −465 → 458) while rotating to −2π, like a ball rolling right, which turns clockwise. Needs experiment X2. |
| Pivot is the layer centre. | [inf] | Natural for a centre-origin translation; no rotated sample to check. Experiment X2. |
| The Properties *Rotation Z* field shows degrees and writes `rotation2` in radians with the **same sign**: entering +30 writes +0.523598775598299 (π/6) [obs, RT-007]. On-screen direction of positive values is still [inf, weak] (needs a render). | [obs] value / [inf] direction | RT-007 `x2-rot30` |
| *Rotation Y* writes `rotation1` (+30° → +π/6); *Rotation X* is the third field (presumably `rotation0`). The menu animations *Tilt Left/Right* animate `rotation1` to ±π/6 together with x ±480 and scale [obs, RT-004]. Rendering of X/Y rotation (perspective or orthographic) is [?]. | [obs] keys | RT-007 `x2d-rotY30` |
| *Skew* writes `shear0` with the number shown (10 → 10.0); its unit (degrees?) and axis are [?]. | [obs] key | RT-007 `x2b-skew10` |
| The *Size* width field is display only: setting width 800 on a 1600-wide still writes `scale0`/`scale1` 0.5 (aspect locked) [obs]. | [obs] | RT-007 `x2c-width800` |
| Missing → 0. | [inf] | |

## 5. Transform order

```
canvas_point = T(translation0, translation1) · R(rotation2) · S(scale0, scale1) · local_point
local_point  ∈ [−w/2, w/2] × [−h/2, h/2]   (layer centred on its own origin, +y up)
```

[obs] for T·S (E1/E2 numbers above, no rotation present). The position of R
(between T and S) is [inf]: it only matters for non-uniform scale with
rotation, which no sample has.

## 6. Crop

Two families of four keys each: `geometryCrop0..3` and `sourceCrop0..3`.

| Claim | Tag | Evidence |
|---|---|---|
| Values are fractions of the layer's natural size (0 = no crop). | [inf] | All observed values are 0 or float noise (−8.6e−14, −4.9e−14, −7.2e−14, −4.0e−14 in the demo). **No project in E3 has a non-zero crop.** |
| Edge order 0,1,2,3 = left, top, right, bottom. | [inf, unverified] | In the demo noise values, crop0 = crop2 and crop1 = crop3 on both clips (−8.56e−14 / −7.23e−14 on the 3024×1964 clip, −4.92e−14 / −4.00e−14 on the 1920×1080 clip). That pairs 0↔2 and 1↔3, consistent with (left, top, right, bottom) or (left, bottom, right, top) — **x-edges are 0 and 2** [obs]; which of 1/3 is top is [?]. Experiment X1. |
| Float noise: treat \|v\| < 1e−9 as 0 and clamp each value to [0, 1]. | [inf] | |
| `geometryCrop*` appears on every visual clip type and on groups; `sourceCrop*` appears on images, callouts and screen recordings only. | [obs] | E3: geometryCrop on Callout 13, Group 1, IMFile 8, ScreenVMFile 2, StitchedMedia 9, VMFile 67; sourceCrop on Callout 6, IMFile 8, ScreenVMFile 1 |
| Difference between the two families. | [?] | Hypothesis: `sourceCrop` trims the source image before effects (e.g. drop shadow follows the cropped edge), `geometryCrop` trims the transformed layer. Experiment X1. |
| A crop removes the cropped strip without moving the remaining pixels (the layer centre stays where it was). | [inf] | Camtasia's canvas crop handles behave this way in the UI; experiment X1 confirms. |

## 7. Opacity and visibility

| Claim | Tag | Evidence |
|---|---|---|
| `opacity` 0–1, missing → 1.0. | [obs] | Demo clips have no `opacity` key and are fully visible in E2. Animated values observed in [0, 1] only. |
| Observed only on `Callout` (6) and `IMFile` (2) in E3, always animatable. | [obs] | |
| Group opacity composes multiplicatively with child opacity. | [inf] | No group with opacity in E3. |
| Track stacking: `trackIndex` ascending = bottom → top. | [obs] | Demo group: shader (track 0) is behind the screen recording (track 1), which is behind the camera (track 2) in E2. |
| Top-level hide flags live in `timeline.trackAttributes[i]` (same order as `tracks`); tracks inside a group carry `ident`, `audioMuted`, `videoHidden`, `magnetic`, `matte`, `solo` **inline on the track object**. | [obs] | Demo group tracks. |

## 8. Groups

| Claim | Tag | Evidence |
|---|---|---|
| A group's children are positioned in a `widthAttr`×`heightAttr` canvas whose centre is the group's local origin, with the same conventions (§1). | [obs for an untransformed group] | Demo: group has no transform keys; child positions match E2 relative to the project canvas centre, which coincides with the group canvas centre (both 1920×1080). |
| The group's own transform applies on top: `M_child_on_canvas = M_group · M_child`. | [inf] | ThemeEditorDemo (format 2.0, 840×700): group at (−48.7, −257.4) holds title callouts at small offsets (±180, ±47) — a lower-third layout, consistent with composition. No reference render. Experiment X3. |
| Group geometry/opacity apply to the flattened group image (group crops cut the composite) — so render a group with non-identity crop or opacity < 1 offscreen. | [inf] | |
| `maxDurationAttr` is a timing attribute, not geometry (see time-mapping.md). | [obs] | |

## 9. Background

- `timeline.backgroundColor` = `[r, g, b, a]`, integers 0–255 [obs]. Values
  seen: `[0, 0, 0, 255]` (22 projects), `[255, 255, 255, 255]`
  (DropShadowPreview), `[21, 25, 28, 255]` (ThemeEditorDemo).
- It fills the canvas behind track 0 [inf]; in the demo the full-canvas shader
  hides it.
- Not to be confused with `timeline.captionAttributes.backgroundColor`
  (caption box colour) [obs].

## 10. Effect geometry units (aside for M4)

- `Mask` `mask-width`/`mask-height`/`mask-positionX/Y` are in **source pixels of
  the layer, origin at the layer centre** [obs: E1 mask 1080 × camera scale
  0.288696 = 311.8 canvas px = 104 thumbnail px, centred on the camera centre].
- `DropShadow` / `CursorShadow` `angle` is in radians (4.71238898038469 = 3π/2,
  3.92699081698724 = 5π/4) [obs values; direction convention ?].

## 11. Missing key → value (M1 parameters)

| Key | Default | Tag |
|---|---|---|
| `translation0`, `translation1`, `translation2` | 0 | [obs] (0/1), [inf] (2) |
| `scale0`, `scale1` | 1 | [inf] (§3) |
| `rotation0..2` | 0 | [inf] |
| `geometryCrop0..3`, `sourceCrop0..3` | 0 | [inf] |
| `opacity` | 1 | [obs] |
| `volume` | 1 | [obs] (groups and stitched media write 1.0 explicitly) |
| Group `widthAttr`/`heightAttr` | project `width`/`height` | [inf] |
| `timeline.backgroundColor` | `[0, 0, 0, 255]` | [inf] (every observed project has the key) |

An animatable parameter's value before its first keyframe is its
`defaultValue`; see `time-mapping.md` §6.

## 12. Open questions and experiments

These need Camtasia to answer; each is a short session for the user.
The `ProjectThumbnail` stored on save is a Camtasia render of the canvas at
the playhead, so most need only "edit, park playhead, save".

- **X1 — crop order and families.** New 1920×1080 project, import any
  landscape image, leave it at default size. Select it and, using the crop
  handles on the canvas (or the Crop fields in Properties if shown), crop
  **only the left side** by roughly a quarter, park the playhead on the clip,
  *File ▸ Save As* `x1-left.cmproj`. Undo, crop **only the top**, save
  `x1-top.cmproj`. Send both project bundles.
- **X2 — rotation sign and pivot.** Done by automation 2026-10-20 (RT-007): the
  value sign is settled (above). The on-screen direction and pivot still need a
  render, which waits on reference exports.
- **X3 — group composition.** Two images side by side, group them, move the
  group right by ~200 px and set the group scale to 50 %, save
  `x3-group.cmproj`.
