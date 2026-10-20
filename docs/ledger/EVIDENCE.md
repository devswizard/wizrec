# Evidence ledger (RE side only; implementers must not read this file)

This file records every use of REA tools and every static analysis of
TechSmith binaries. Each entry gives the evidence id, the target's SHA-256,
the method, the conclusion and any open unknowns.

## Status (2026-10-20, end of session 5)

- **Still no REA tool use and no binary analysis.** Session 5 added only
  Method 3 (runtime observation by UI automation, approved), entries RT-001
  to RT-019 below: saves and JSON diffs.
- **What was not done:**
  - No exports and no *Export Frame*. The trial gate is RT-001.
  - No screen capture of the canvas, and no use of `ProjectThumbnail`.
  - Nothing licensing-related.
  - The background-file `signature` was only observed as present or absent
    (RT-009). It was never analysed, reproduced or bypassed.
- **Bundle files** were read in place, for names and interface fields only.
  These were the `.tsceffect` attribute lists and the `.tscshadervid`
  `effectDef`s for RT-014 and RT-016.
- **TechSmith files in `camtasia_rea_refs/`.** Camtasia copied some of its
  own files into the saved bundles there: imported backgrounds and the
  sketch-callout SVG embedded in `co3-regions`. These stay outside the repo
  and are never vendored.

## Status (2026-10-19)

**No REA tool use and no binary analysis so far.** Every spec to date was
derived from the methods below. None of them involves Camtasia's code:

- Method 1. The user's own projects and recordings, read only:
  - `~/Documents/demo project.cmproj`;
  - `~/Documents/Moheshkali Dwip Vlog.cmproj`;
  - the demo `.trec` `TSCM` atom, parsed numerically by our own scratch
    scripts, with text records never printed.
- Method 1. Data files inside `/Applications/Camtasia.app/Contents/Resources`,
  read in place and never copied:
  - the sample `.tscproj` and `.trec` files;
  - JSON interfaces of `.tscshadervid` and `.tsceffect` files (keys, names,
    types, ranges and identifier lists only; never code);
  - the `AnnotationsBin` presets (keys and enums only);
  - `calloutindices.plist`;
  - resource file names.
- Our own re-evaluation of the user's copy of one background shader, used to
  fit `_Time` against the user's `ProjectThumbnail`. This lives in a scratch
  script outside the repo.

M6-RES-1 (`.trec` cursor and click stream) was fully answered at file level,
so the static-REA permission in `coordination/DECISIONS.md` was not needed.

## Entries

### Method 3: runtime observation by UI automation (session 5, from 2026-10-20)

Approved in DECISIONS 2026-10-20. The researcher drives the installed
Camtasia 2026.2.3 (`/Applications/Camtasia.app`, bundle
`com.techsmith.camtasia`) through AppleScript and System Events: menus,
playhead time field, Properties text fields and panel context menus.

- **Scope.** Black-box only. Camtasia opens generated projects (copies under
  `camtasia_rea_refs/`, built by `wizrec-testgen experiments` from synthetic
  media). One edit is applied per clip, the result is saved with
  *File ▸ Save As*, and the saved `project.tscproj` is diffed against the
  input.
- **Exclusions.** No exports and no screen capture of Camtasia's canvas. No
  REA tools, no binary analysis, nothing licensing-related.
- **Automation.** It lives outside the repo, in
  `camtasia_rea_refs/_automation/`: `cam.sh`, `drive.py`, `x*.sh`,
  `batch*.sh`, the AppleScript helpers and `jdiff.py`/`clipfx.py` for diffs.
  It contains no TechSmith assets.

| Id | Date | Experiment | Inputs → outputs (under `camtasia_rea_refs/`) | Conclusion | Spec |
|---|---|---|---|---|---|
| RT-001 | 2026-10-20 | Export gate | `baseline` → *Export ▸ Local File…* | A modal offers only "Export without Watermark" / "Export with Watermark" before any settings: a trial gate. Neither button was clicked and nothing was exported; reference exports are blocked (NEED_USER) | — |
| RT-002 | 2026-10-20 | Re-save normalisation | `baseline` → `format/probe-baseline.cmproj`; every later save | Ids renumbered densely, zero `sourceCrop*` dropped, `lockAspectRatio` typed, `default-scale` metadata added, project metadata keys added, H.264 `bitDepth` 0 | `group-edits.md` §7 |
| RT-003 | 2026-10-20 | EF0, all visual effects | `research/effects/ef0-base` → `ef0-all-visual.cmproj`; `vid-base` → `vid-ops.cmproj` | Menu name → `effectName` map and default parameters for 29 effects plus `LutEffect`, Clip Speed and Hotspot; Keystroke and Window Spotlight disabled on non-recordings | `effects/catalog.md`, `effects/Border.md`, `effects/Reflection.md` |
| RT-004 | 2026-10-20 | Behaviours and menu animations | `ef0-base` → `research/behaviors/bh-all.cmproj`; `vid-ops.cmproj` | Defaults of 13 behaviours; menu animations write one 1 s keyframe that ends at the playhead (start may be negative) with no `interp` key | `behaviors.md`, `animation.md` |
| RT-005 | 2026-10-20 | X3 group geometry | `format/x-group-base` → `x3a-group-only`, `x3-group`, `x3b-group-scaled-ungroup` | Group box = union of members, re-centred; group transform independent; ungroup composes position and scale | `group-edits.md` §1, §2, §6 |
| RT-006 | 2026-10-20 | X5 group time | `x3a-group-only` (continued) → `x5a-group-moved`, `x5-group-time`, `x5b-group-split`, `x5c-group-ungroup` | Paste rewrites params to long form; trim-start trims inner clips; split copies inner content whole; ungroup cuts to the window | `group-edits.md` §3–§6 |
| RT-007 | 2026-10-20 | X2 rotation, skew, size; X6 image trim | `format/x-photo-base` → `x2-rot30`, `x2b-skew10`, `x2c-width800`, `x2d-rotY30`, `x6a-image-anim`, `x6-image-trim` | UI rotation Z +30° gives `rotation2` +π/6; Y gives `rotation1`; skew 10 gives `shear0` 10; width 800 of 1600 gives scale 0.5; image trim-start adds to `trimStartSum`, keyframes untouched | `transform.md`, `edit-semantics.md` |
| RT-008 | 2026-10-20 | X7 edit semantics (menu equivalents of drags) | `format/x7-base` → `format/x7/x7v-*`, `x7p-*`, `x7g-*`, `x7c-*` | Split of stitched/group clips copies all segments/inner tracks; auto-stitch after ripple delete; split/trim never prune keyframes or effect windows; image split sets `trimStartSum`; one-sided transitions follow a moved clip | `edit-semantics.md` (X7 results) |
| RT-009 | 2026-10-20 | `.tscshadervid` acceptance | `wizrec-testgen shadervids` → `research/shaders/wizrec-shadervids/`; `format/one-video-base` → `research/shaders/sh-control-import`, `sh-ref-control(-saved)`, `sh-ref-wizrec(-saved)`, `sh-ref-wizrec-numver` | Import of a WizRec file: "not supported or damaged"; a project referencing one opens with "Files not supported" and keeps the entry on save (src points back to the old bundle); a bundled background imports and opens cleanly; a numeric `version` changes nothing. Inferred cause: signed files only. No attempt to sign or bypass | `shader-backgrounds.md` §10 |
| RT-010 | 2026-10-20 | AU1 audio effects, fades, audio points | `research/audio/au1-base` → `au1-audio`, `au1b-fades`, `au1c-fades` (fades by dragging panel tiles onto clips with a synthetic mouse helper) | Panel lists 8 audio items (no classic noise removal or leveling); `effectName`/defaults for AI Noise Removal, Audio Compression (`WinCompression`), Emphasize, Pitch; Clip Speed only flags metadata; fades and audio points are `volume` keyframes (1 s default) | `audio.md` §3, §4 |
| RT-011 | 2026-10-20 | AU2 source measurement | `research/audio/au2/au2-generated` → `au2.cmproj` (save only; export gate) | Camtasia's `integratedLUFS` = dual-mono BS.1770 after resampling to 44.1 kHz (±0.05 LU, except 0.35 LU on the loud pink noise); `peakLevel` = sample peak after resampling | `audio.md` §2.1 |
| RT-012 | 2026-10-20 | CA1/CA2 captions | `research/captions/ca-base` → `ca1-captions`, `ca1b-trimmed`, `ca1c-moved`, `ca2-dynamic`, `ca2-style2` | Add Captions = empty 4 s segments on the media axis from `mediaStart`; dynamic style runs transcription onto the source (`%GAP` end token), adds a 60 s callout at the playhead on a new track; preset keys and values for two presets; font in `textAttributes` | `captions.md` §1, §3 |
| RT-013 | 2026-10-20 | X8 markers | `format/one-video-base` → `x8-markers`; `ca1c-moved` → `x8b-media-markers` (no change), `x8c-marker-ripple` | Timeline markers only (default name "Marker"); no clip-marker command in menus, context menus or shortcuts; ripple delete leaves markers in place | `markers.md` |
| RT-014 | 2026-10-20 | SH2 shader parameter codes | `format/one-video-base` + three bundled backgrounds imported in place → `research/shaders/sh2-codes.cmproj` | `effectDef` numeric codes (radians 3, directional 2, Position scaling 1 / UI 5, z appended), clip `Pos.x`/`Pos.y`, malformed colour string read as RRGGBBAA, 60 s default clip | `shader-backgrounds.md` §6, §9 |
| RT-015 | 2026-10-20 | Blend Mode / Media Matte enums | `research/effects/ef0-base` → `enums.cmproj` (`enums.log` maps clip to UI choice) | Each pop-up entry chosen on its own clip: 31 blend modes → `mode` 0–30 (Normal 0, stencil/silhouette 1–4, Dissolve 5 … Luminosity 30; default Screen 12); matte modes Alpha 1, Alpha Invert 2, Luminosity 3, Luminosity Invert 4; new `trackDepth` 10002 | `effects/BlendModeEffect.md`, `effects/MediaMatte.md` |
| RT-016 | 2026-10-20 | TR2/TR3 transitions, X7 #8 two-sided move | `research/effects/vid-base` → `research/transitions/tr-all` → `tr2-two-sided` (panel tiles dragged onto cuts with the synthetic-mouse helper) → `tr4-two-sided-moved` | Panel names map to `name` (Fade = `LuminanceFadeIn`); shader parameters are constants in `attributes`; FadeThroughBlack has a colour; two-sided default 0.5 s and one-sided 1 s; moving one clip splits a two-sided transition into two one-sided ones | `transitions.md`, `edit-semantics.md` |
| RT-017 | 2026-10-20 | CO3 region, sketch and keystroke callouts | `research/callouts/card-base` → `co3-regions.cmproj` (Annotations tiles dragged onto the canvas) | `def` keys and defaults for Highlighter, Spotlight, Blur (plain and inverted), Pixelate, Sketch Motion (`TypeWinSVG` with embedded SVG `xmlContent`, draw-on `leftEdgeMods`, end `Fade`), Keystroke (`MacKey`); 5 s at the playhead; scale to 640 px wide | `callouts.md` §3.1 |
| RT-018 | 2026-10-20 | Part J (ED0, ED1), UnifiedMedia split | `format/video-photo-base` + our own `research/timeline/media/av-card.mp4` (test card + synthetic speech) → `research/timeline/ed0-insert`; its saved JSON with fresh media copies → `ju-base` → `ju2-split-extend` | Insert defaults (image 5 s, unified = shorter stream floored to a frame); Extend Frame = StitchedMedia with an IMFile "Frame of …" reading the video's last frame; UnifiedMedia split keeps the parent and child times identical | `edit-semantics.md` (Part J, X7 #9) |
| RT-019 | 2026-10-20 | AI Noise Removal without `ExtandableEffectData` | `research/audio/au1-audio` copy with the blob removed by a text edit → `dfn-noblob-plain`, `dfn-noblob-saved` (Amount set to 50 via the Properties field) | Opens without alert; the effect is kept and the blob regenerated on save; Amount edits work; `default-…-Amount` metadata records the prior value | `audio.md` §3.3 |
