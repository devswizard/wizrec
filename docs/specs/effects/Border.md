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
- The project `effectName` is assumed to be `"Border"`, after the resource
  names and the pattern of other effects [inf].

## Parameters

All are [?] until **EF0** (README §3), which adds Border with its defaults
to a clip. By analogy with `DropShadow`, the expected keys are:

- `color-red`, `color-green`, `color-blue` and `color-alpha` (0–1);
- `thickness` or `width` [?], in layer px or canvas px;
- possibly `corner-radius` and `style`, and whether the border sits inside,
  centred on or outside the edge [?].

## Model (provisional)

- The border follows the layer's silhouette after the effects earlier in the
  stack, e.g. rounded corners [inf].
- Until EF0 and EF8 land, render an outside stroke of the given thickness
  around the alpha edge.

## EF8: border sheet (qa, once EF0 gives the names)

| Cell | Media | Border settings |
|---|---|---|
| 1 | M-grey, scale 0.5 | thickness 20 |
| 2 | M-grey, scale 0.25 | thickness 20 (units) |
| 3 | M-disc | thickness 20 (silhouette or box) |
| 4 | M-grey + RoundCorners radius 80 | thickness 20 (follows the rounding?) |
| 5 | M-grey | colour (0, 0, 1), alpha 0.5 |
