# Effect spec: `Border`

Draws a solid border around the layer.

Tags: **[obs]** observed in files, **[inf]** inferred, **[?]** unknown.

## Evidence

- **No instance exists in the corpus.** `BorderPreview.tscproj` carries only
  a `dummy` placeholder effect (`start` 20, `duration` 80 frames of a
  120-frame clip). Its `metadata.effectApplied` is a leftover `"Colorize"`
  [obs].
- The bundle has `Border.mp4` and `iconBorder.png` (preview assets, names
  only) [obs]. It also has a `Base.lproj/Border.nib`, which suggests the
  effect has its own custom inspector panel [inf].
- The project `effectName` is `"Border"` [obs, EF0 runtime save].

## Parameters (EF0, runtime save, 2026-10-20)

Camtasia 2026.2.3 wrote these defaults when Border was added from
*Modify ▸ Add Effects ▸ Visual Effects ▸ Border* to a 400×400 grey still
[obs]:

| Key | Default | Meaning |
|---|---|---|
| `enabled` | 1 | on/off flag, int [obs] |
| `color-red`, `color-green`, `color-blue`, `color-alpha` | 1.0 each | border colour, 0–1: opaque white [obs] |
| `width` | 1.0 | thickness [obs]. Units are [?]: canvas px or layer px, to be settled by EF8 cells 1 and 2 |
| `type` | 0 | border style enum [obs]. The other values and their looks are [?] |

- The effect name is `"Border"` [obs].
- `metadata.effectApplied` on the clip becomes `"Border"` [obs].
- The parameters are written as bare numbers [obs]. Other effects use the
  same form when nothing is keyframed.
- There is no corner-radius or inside/outside key [obs].

## Model (provisional)

- The border follows the layer's silhouette after the effects earlier in the
  stack, e.g. rounded corners [inf].
- Until EF0 and EF8 land, render an outside stroke of the given thickness
  around the alpha edge.

## EF8: border sheet (qa, once EF0 gives the names)

| Cell | Media | Border settings |
|---|---|---|
| 1 | M-grey, scale 0.5 | `width` 20 |
| 2 | M-grey, scale 0.25 | `width` 20 (units) |
| 3 | M-disc | `width` 20 (silhouette or box) |
| 4 | M-grey + RoundCorners radius 80 | `width` 20 (follows the rounding?) |
| 5 | M-grey | colour (0, 0, 1), alpha 0.5 |

## Properties panel

UI controls, ranges, display formats and the keys they write (RES15-1, RT-030): `inspector.md` §2.
