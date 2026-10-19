# Camtasia projects

WizRec opens `.cmproj` packages and bare `.tscproj` files from Camtasia on Mac or Windows
(project format 2.0 through 10.0), and saves them in the same format.

## What carries over

- **Everything you don't touch stays byte-for-byte.** WizRec edits the project in place:
  settings it doesn't understand, the order of entries and the exact numbers are kept, so
  Camtasia sees the same project plus your edits.
- Clips, tracks, groups, stitched clips, speed changes, keyframes, markers, effects,
  transitions, callouts, captions and cursor data are read and kept.
- What WizRec can't draw yet (a few effects, some callout styles) still stays in the file and
  shows up again in Camtasia. In WizRec those parts are left out of the preview.

## Moving projects between machines

A `.cmproj` package holds its own copies of imported media under `media/` and recordings
under `recordings/`. Some projects instead point at files elsewhere on the original
computer. When WizRec can't find a file, it lists the missing media and lets you **relink**
each item to a file on this Mac.

## Saving

- File ▸ Save replaces the project atomically and keeps the previous version as
  `project.tscproj.wizrec-backup` inside the package.
- New projects use the current format (10.0), so recent Camtasia versions open them.

## Limits

- Camtasia-only features (quizzes, hotspots, Smart Player, TechSmith cloud sharing) are kept
  in the file but not supported.
- WizRec never contains or unlocks any part of Camtasia itself.
