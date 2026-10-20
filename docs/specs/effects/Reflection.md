# Effect spec: `Reflection`

Draws a mirrored, fading copy of the layer beneath it, like a reflection on
a glossy floor.

Tags: **[obs]** observed in files, **[inf]** inferred, **[?]** unknown.

## Evidence

- **No instance exists in the corpus.** `ReflectionPreview.tscproj` carries
  only a `dummy` placeholder (`start` 20, `duration` 80 frames) [obs].
- The bundle has `Reflection.mp4` and `iconReflection.png` (names only)
  [obs].
- The project `effectName` is `"Reflection"` [obs, EF0 runtime save].

## Parameters (EF0, runtime save, 2026-10-20)

Camtasia 2026.2.3 wrote these defaults when Reflection was added from the
menu to a 400×400 grey still [obs]:

| Key | Default | Meaning |
|---|---|---|
| `distance` | 20.0 | gap between the layer's bottom edge and the mirrored copy [obs]. Units are [?], probably px [inf] |
| `opacity` | 0.4 | strength of the reflection, 0–1 [obs] |

- The effect name is `"Reflection"` [obs].
- There is no fade-length, size or blur key [obs], so the fade-out ramp
  along the reflection is fixed by Camtasia. Its shape is [?]; EF9 measures
  it.

## Model (provisional)

```
R = the layer flipped vertically about its bottom edge, shifted down by distance
R.alpha *= opacity · ramp(1 → 0 over a fixed fade length [?] from the flip line)
draw R under the layer
```

- The reflection is part of the layer, so it moves, scales and rotates with
  it [inf].
- It is drawn **below** the layer itself [inf].

## EF9: reflection sheet (qa, once EF0 gives the names)

| Cell | Media | Settings |
|---|---|---|
| 1 | M-card, scale 0.33, upper half of the canvas | Defaults |
| 2 | Same | Opacity at its maximum |
| 3 | Same | Distance or gap at a non-zero value |
| 4 | Same, `rotation2` = 0.3 | Does the reflection rotate with the layer? |
