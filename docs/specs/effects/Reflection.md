# Effect spec: `Reflection`

Draws a mirrored, fading copy of the layer beneath it, like a reflection on
a glossy floor.

Tags: **[obs]** observed in files, **[inf]** inferred, **[?]** unknown.

## Evidence

- **No instance exists in the corpus.** `ReflectionPreview.tscproj` carries
  only a `dummy` placeholder (`start` 20, `duration` 80 frames) [obs].
- The bundle has `Reflection.mp4` and `iconReflection.png` (names only)
  [obs].
- The project `effectName` is assumed to be `"Reflection"` [inf].

## Parameters

All are [?] until **EF0**. The expected kinds are:

- reflection opacity (0–1);
- distance or gap below the layer;
- fade length or "size", as a fraction of the layer height;
- possibly a blur amount.

## Model (provisional)

```
R = the layer flipped vertically about its bottom edge, shifted down by gap
R.alpha *= opacity · ramp(1 → 0 over fadeLength from the flip line)
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
