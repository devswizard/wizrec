# Spec: group edits (create, transform, move, trim, split, ungroup)

What Camtasia 2026.2.3 writes when a user groups clips and then edits the
group. Source: automated runtime observation (DECISIONS 2026-10-20). Camtasia
opened generated projects, applied one menu edit at a time, and saved
(`File ▸ Save As`). Each claim compares the saves before and after. No
exports and no binary analysis were used. Evidence: runtime experiments X3
and X5 (see the evidence ledger, researcher side only).

Tags: **[obs]** seen in Camtasia's saved files, **[inf]** inferred,
**[?]** unknown.

Test material: two copies of a 1600×900 still, both scaled to 50 % (800×450
on the canvas). One copy sits at the canvas centre on track 1; the other is
300 px to the left on track 2. Both run from 0 s to 5 s.

## 1. Creating a group (Edit ▸ Group)

- **Bounding box, not canvas.** The new group's `widthAttr` × `heightAttr`
  is the union of the members' on-canvas rectangles. In the test this was
  1100 × 450, not the 1920 × 1080 canvas [obs].
  - Each member's rectangle is its source size times its scale. Whether
    rotation and crop are taken into account is [?]; the test used neither.
- **Re-centring.** The group's position is set to the centre of that box.
  Every member's position is shifted by the same amount the opposite way,
  so nothing moves on screen [obs].
  - In the test the group went to x = −150. The members went from 0 and −300
    to +150 and −150.
  - Scale, rotation and every other member parameter are left as they were
    [obs].
- **Tracks.** Members keep their relative track order. Each source track
  becomes one inner track, numbered from 0, bottom to top [obs].
  - The group sits on the lowest member track. Higher tracks that became
    empty stay in the project as empty tracks [obs].
  - Each inner track carries the flags `ident` (empty), `audioMuted`,
    `videoHidden`, `magnetic`, `matte` (0) and `solo`, all off [obs].
- **Timing.** The group starts at the earliest member start and lasts until
  the latest member end [obs]. `mediaStart` is written as `0.0` and
  `mediaDuration` as the duration, both as decimal numbers rather than
  integers [obs].
  - Inner clips are re-timed to the group's own clock, so the earliest one
    starts at 0 [obs].
- **Attributes.**
  - The name is `"Group 1"` [obs].
  - `maxDurationAttr` is 0 [obs]. It is not the content length, so readers
    must not rely on it.
  - `gain` is 1.0 and `mixToMono` is false [obs].
  - There is an empty `assetProperties` list [obs].
- **Group parameters.** Only the re-centring offset appears, plus
  `volume` = 1.0 [obs]. Metadata has `isOpen` set to false [obs].

## 2. Changing the group's transform (Properties panel)

- **Scale.** Setting the group's scale to 50 % writes the group's own
  `scale0`/`scale1` = 0.5. Members are untouched [obs].
- **Position.** Setting X to 200 writes the group's `translation0` = 200.
  This is absolute: the re-centring offset is replaced, not added to [obs].
- **Displayed size.** The Size field then shows 550, which is `widthAttr`
  × scale. `widthAttr` itself stays 1100 [obs].

## 3. Moving a group in time (Cut, then Paste at the playhead)

- **Timing.** The group arrives at the playhead (10 s). Its inner timeline,
  `mediaStart` and duration are unchanged [obs].
- **Parameter form.** Every constant parameter of the pasted group, and of
  every clip inside it, is rewritten from the short form (a bare number) to
  the long form: an object with `type`, `defaultValue` and
  `interp: "eioe"` [obs]. Both forms mean the same thing. Readers must
  accept both; writers may use either [inf].
- **Ids.** The pasted group and its members keep their ids in the saved
  file, because the save renumbers densely anyway [obs]
  (`edit-semantics.md` E2).

## 4. Trimming a group's start (Edit ▸ Playhead ▸ Trim Start to Playhead)

Test: the group ran 10–15 s and was trimmed at 11 s.

- **Group.** Start moved to 11 s and duration to 4 s. `mediaStart` became
  1 s (decimal) and `mediaDuration` 4 s [obs].
- **Inner clips are trimmed too.** This differs from session-3's inferred
  rule, and the difference matters for WizRec.
  - Every inner clip that started before the new inner start (1 s) was cut
    there: its inner start became 1 s and its duration 4 s [obs].
  - For stills, `trimStartSum` grew by the trimmed amount, from 0 to 1 s,
    while `mediaStart` stayed 0 [obs].
  - For videos, `mediaStart` would grow instead [inf, from the split rules].
  - The group's `mediaStart` (1 s) and the inner clips' new start (1 s)
    agree, so nothing changes on screen [obs].
- **Scope.** The trim does not shift the inner timeline back to 0. Inner
  clips keep their positions on the group's clock, and only the parts before
  `mediaStart` are removed [obs].

## 5. Splitting a group (Edit ▸ Split)

Test: the trimmed group (11–15 s, `mediaStart` 1 s) was split at 13 s.

- **Two groups.**
  - The left group keeps its id and start. Its duration becomes 2 s and its
    `mediaStart` stays 1 s [obs].
  - The right group is a new group at 13 s, 2 s long, with `mediaStart`
    3 s [obs].
- **Inner content is copied whole, not cut.** Both halves hold a full,
  identical copy of the inner tracks; the right half's copies get new ids.
  The inner clips still span inner 1–5 s in both halves [obs].
  - Only the group window (`mediaStart`/`duration`) differs between the
    halves. This confirms assumption 2 of `edit-semantics.md`.
- **Name and transform.** The right half keeps the name `"Group 1"` and
  the same transform as the left [obs].
- So split and trim-start treat inner clips differently [obs]:
  - Trim-start removes inner material before the new window.
  - Split leaves inner material outside the window in place.

## 6. Ungrouping (Edit ▸ Ungroup)

- **Placement.** Each inner track's clips go back to top-level tracks: inner
  track 0 to the group's own track, inner track 1 to the next one up, and so
  on [obs].
- **Timing.** Only what is visible through the group window survives.
  - Each clip is cut to the window. In the test (right half: 13–15 s, inner
    window 3–5 s), both clips came out at 13 s, 2 s long [obs].
  - For stills, `trimStartSum` absorbed the cut. Here it was 3 s: the 1 s
    trimmed earlier plus the 2 s between the clip's inner start and the
    window start [obs].
- **Transform composition.** The group's transform is folded into each child
  [obs]:
  - **Position:** the child's new position is the group's position plus the
    group's scale times the child's position. The test had group x 200,
    scale 0.5 and children +150 and −150; the children came out at 275 and
    125.
  - **Scale:** the child's new scale is the group's scale times its own
    (0.5 × 0.5 = 0.25).
  - **Zero values:** a position that comes out as 0 is dropped from the
    parameters rather than written as 0 [obs].
  - **Rotation:** composition with group rotation is [?] (not tested).
- **Ids.** The group id is gone, and the save renumbers the children densely
  [obs].

## 7. Normalisation Camtasia applies when it re-saves a WizRec project

These appeared in every experiment save, before any edit. They are not
errors, but WizRec's round-trip tests should expect them when Camtasia has
touched a file.

- **Ids.**
  - Renumbered densely in document order, starting with `sourceBin` [obs].
    For example, WizRec's source id 2 became 1 and the timeline id 1 became 2.
- **Media stamps.**
  - The `media/<stamp>/` folder name is re-stamped on Save As [obs].
- **Parameters and metadata.**
  - Source crop parameters equal to 0 are dropped [obs].
  - Geometry crop parameters are written in the short (bare number) form
    when constant [obs].
  - `metadata.lockAspectRatio` is rewritten from a bare `true` to a typed
    object (`type` bool, `value` true) [obs].
  - Camtasia adds `metadata."default-scale"` = `"1"` to clips [obs].
- **Project metadata.**
  - Adds `projectDuration` (for example `"00:05"`), `firstMedia`,
    `hasNotifiedAboutHFRMedia`, `commandCount` (number of edit commands since
    open) and the thumbnail [obs].
- **Source tracks.**
  - The source `bitDepth` of an H.264 video track becomes 0 [obs]. WizRec
    writes 24.
- **Track height.**
  - `trackAttributes[].metadata.trackHeight` goes from WizRec's "56" to "78"
    [obs]. This is UI only.

## Open

- Rotation and crop in the bounding box at group creation, and rotation in
  ungroup composition [?].
- Whether drops into an open group grow the group. This is DECISIONS
  2026-10-19's inferred rule, and it needs mouse drags, which were not
  automated [?].
- How trim-start behaves on inner videos (`mediaStart` versus a new
  `trimStartSum`) [inf]; the test used stills.
