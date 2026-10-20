# Evidence ledger (RE side only; implementers must not read this file)

This file records every use of REA tools and every static analysis of
TechSmith binaries. Each entry gives the evidence id, the target's SHA-256,
the method, the conclusion and any open unknowns.

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
