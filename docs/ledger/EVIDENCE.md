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

(none)
