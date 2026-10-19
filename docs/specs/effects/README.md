# Effects: common model, evidence and the measurement plan

This page covers what every visual effect shares: the entry layout, units,
ordering and edge ramps. It also lists the experiments that will pin down
each effect's maths. Per-effect specs are in this folder.

Tags: **[obs]** observed in files, **[inf]** inferred, **[?]** unknown.

## Evidence base (all effect specs)

- **E-demo: the user's demo project** (Camtasia 2026.2.3, canvas 1920×1080).
  It has the only effect instances on real media:
  - `DropShadow` and five cursor effects on `ScreenVMFile` 6 (scale
    0.54989816700611);
  - `RoundCorners` and `Mask` on the camera `VMFile` 8 (scale
    0.28869624898167).
- **E-thumb: the demo `ProjectThumbnail`.** 640×360, rendered by Camtasia at
  the playhead (12.1 s, `docPrefs`). It is **the only Camtasia render of any
  effect available to us**. The bundle's sample projects have no thumbnail,
  and their "preview" projects carry `dummy` placeholder effects that
  Camtasia replaces at run time [obs]. The background behind the screen
  recording is known exactly from our shader fit
  (`shader-backgrounds.md` §2), so any residual around that layer is the
  shadow.
- **E-vlog: the user's vlog**, which has `ColorAdjustment` on one clip. It is
  not visible in the vlog thumbnail (playhead 2.7 s, clip at 277 s).
- **E-samples: bundle samples, read in place.**
  - BlendModePreview: `BlendModeEffect` on three callouts.
  - MediaMattePreview: `MediaMatte`, `MotionBlur`, a behaviour and a
    transition.
  - MotionBlurPreview: `MotionBlur` on an image animated with `bnce`/`eioe`.
- **Not in the corpus:** `Border` and `Reflection`. Their parameter names are
  [?] until experiment EF0.

## 1. Effect entry

```
{
  "effectName": "<Name>",
  "bypassed": false,
  "category": "categoryVisualEffects",     cursor: "categoryCursorEffects", audio: "categoryAudioEffects"
  "parameters": { <name>: number | animatable object },
  "metadata"?: { "effectIndex": "3" },
  "leftEdgeMods"?: [...], "rightEdgeMods"?: [...],
  "start"?, "duration"?                     ticks, clip-relative (rare)
}
```

| Claim | Tag |
|---|---|
| `bypassed: true` means the effect is skipped at render, but kept and saved | [inf] |
| Parameters are bare constants (older samples) or animatable objects (`{type: "double", defaultValue, interp: "linr", uiHints, keyframes?}`) | [obs] |
| Effect parameters are written with `interp: "linr"`, while clip transforms use `"eioe"`. Keyframes carry their own `interp` | [obs] |
| `uiHints: {userInterfaceType, unitType}` appear only on doubles. Values seen: (0,0) almost everywhere; (1,0) for `LeftClickScaling` scale/speed; (1,1) for `CursorMotionBlur` intensity; (0,1) for percentage parameters of shader sources. `unitType` 1 probably means percentage display. Neither value changes the render | [obs values; inf meaning] |
| `metadata.effectIndex` (a string) records the effect's position in the UI stack across the parent and children of a `UnifiedMedia` | [obs] demo: the parent `UnifiedMedia` 7 lists VST "2", RoundCorners "3" and Mask "4"; its `video` child 8 lists RoundCorners "3" and Mask "4"; its `audio` child 9 lists VST "2" |
| **On `UnifiedMedia`, the parent's `effects[]` is the union of the children's.** Render the `video` child's list for pixels and the `audio` child's for sound, and never apply the parent's entries a second time | [inf] The parameter values are identical in both places |
| Clip `metadata` keeps UI defaults such as `default-<Effect>-<param>` and `effectApplied`. They never change the picture | [inf] |

### Order

- **Effects apply in array order** [inf].
  - Shape effects (`RoundCorners`, `Mask`, `Border`) work on the layer's own
    pixels, after source crop and before the transform [inf].
  - `DropShadow` may be applied after the transform, in canvas space
    (§2, [?]).
  - The demo is consistent with this order: `RoundCorners` then `Mask` gives
    a circle only if the mask shape is an ellipse; see `Mask.md`.
- **Shadows and borders extend beyond the layer bounds** [obs: the demo
  shadow is visible outside the screen recording]. Draw each layer into an
  offscreen buffer padded by the effect's reach.

### Edge ramps (`leftEdgeMods` / `rightEdgeMods`)

[obs, BlendModePreview, three instances]:

```
"leftEdgeMods":  [ { "group": "Video", "duration": 0, "parameters": [ { "name": "intensity", "func": "FadeInFunc"  } ] } ],
"rightEdgeMods": [ { "group": "Video", "duration": 0, "parameters": [ { "name": "intensity", "func": "FadeOutFunc" } ] } ]
```

This describes an automatic fade of the named parameter at the effect's
start and end over `duration` ticks [inf]: `FadeInFunc` ramps from 0 up to
the value, and `FadeOutFunc` ramps back down to 0. With `duration` 0 there is
no ramp [inf]. The ramp's shape is [?]; linear is the assumption.

- The preview samples store `metadata.default-easeIn: "30"` and
  `default-easeOut: "30"` (frames at `editRate` 30, i.e. 1 s). These are
  probably the UI defaults for those ramps [inf].
- The `dummy` effects in the preview samples (`start` 20, `duration` 80 on
  a 120-frame clip) show that an effect can cover only part of a clip, with
  `start`/`duration` relative to the clip [obs].

## 2. Units

Geometric parameters must be stored in some unit. Two candidates exist:

- **layer px**: pixels of the layer's natural size, before `scale0/1`;
- **canvas px**: pixels after the transform.

| Evidence | Points to |
|---|---|
| `RoundCorners.radius` = 233.809757619281 on a clip at scale 0.28869624898167. 233.809757619281 × 0.28869624898167 = **67.5000000000** (= 1080/16) | **layer px**. Camtasia stored a round canvas-px value divided by scale [obs arithmetic; inf meaning] |
| `Mask` `mask-width` 1080 × scale gives the measured circle diameter (104 thumbnail px) | **layer px** [obs, `transform.md` §10] |
| `DropShadow` offset 15 and blur 25 (round values) on a clip at scale 0.5499. In E-thumb the fitted offset is ≈15 canvas px | **canvas px**, weakly (`DropShadow.md`) |

Working rule: shape parameters (radius, mask size and position) are in layer
px. Shadow offset and blur are [?]: canvas px is the working assumption.
EF1 decides.

## 3. Experiments: the effect sheet

The lead asked for experiments where **one saved project answers several
parameters at once**. Two outputs per project make that work:

- the **project thumbnail**: save with the playhead on the frame;
- one **full-resolution frame**: *Share/Export ▸ Export Frame As…* PNG at
  the same playhead. This is preferred because it is 3× sharper.

`qa` builds the projects (our own synthetic media only) from the tables in
each effect spec. The user opens each one, saves it and exports one PNG, and
answers no other questions. Everything goes into
`~/WorkDir/vibe_coding/camtasia_rea_refs/research/effects/`.

Synthetic media for all sheets, generated by qa (all original):

| Id | Media | Purpose |
|---|---|---|
| M-grey | 400×400 PNG, solid mid-grey `#808080`, opaque | Shadow, border, corner and mask shapes on a known colour |
| M-disc | 400×400 PNG, opaque white disc of diameter 300 on a transparent background | Do shadow and border follow alpha or the bounding box? |
| M-card | 1920×1080 colour-bar and grey-ramp test card (the existing `A-testcard` frame) | Colour effects, blend modes |
| M-grad | 1920×1080 horizontal black→white ramp PNG | Blend-mode curves, matte luminance |

Canvas: 1920×1080, `backgroundColor` `[255, 255, 255, 255]`, i.e. white, as
in DropShadowPreview.

- **EF0: parameter discovery (Camtasia UI, about 5 minutes).** New project.
  Put one M-grey image on each of nine tracks. From *Visual Effects*, drag
  onto each image, one per track and with default settings: Border,
  Reflection, Drop Shadow, Corner Rounding, Color Adjustment, Mask, Blend
  Mode, Motion Blur, Media Matte. Save as `ef0-defaults.cmproj`. This fills
  in every parameter name and default that the specs mark [?].
- **EF1 to EF7**: generated sheets. Each is defined in its effect's spec,
  and each needs only *open → save → export frame*.
