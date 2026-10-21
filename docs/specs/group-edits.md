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

### 1a. Key layout of a new group (X3 saves, answers to an implementer question)

All of the following is [obs] in Camtasia's first save after *Group*, and
unchanged after the scale/position edit.

- **Group object key order:** `id`, `_type`, `parameters`, `tracks`,
  `attributes`, `effects`, `start`, `duration`, `mediaStart`,
  `mediaDuration`, `scalar`, `metadata`, `animationTracks`.
- **`assetProperties`** sits **inside `attributes`**, as its last key:
  `ident`, `widthAttr`, `heightAttr`, `maxDurationAttr`, `gain`,
  `mixToMono`, `assetProperties` (an empty list).
- **Group `parameters`**:
  - Every value is a **bare number** (short form), not the long object form.
  - Order: the re-centring offset `translation0` first, then
    `geometryCrop0`…`geometryCrop3` (bare 0.0), then `volume` (1.0).
  - After the group's scale was set, the order became `translation0`,
    `scale0`, `scale1`, then the four geometry crops, then `volume`.
- **Member `parameters`**:
  - Every value is also a **bare number**, including the new `translation0`.
  - Camtasia writes them in its own canonical order, whatever order the input
    file used: `translation0`, `scale0`, `scale1`, then
    `geometryCrop0`…`geometryCrop3`.
  - The WizRec input had `sourceCrop0..3`, `geometryCrop0..3`, `scale0`,
    `scale1`, `translation0`, all in the long form. Camtasia dropped the zero
    source crops, put `translation0` first and wrote everything short.
  - For the member that had **no** `translation0` before (it was at x 0),
    the new key was likewise placed first [obs].
  - The general rule is that Camtasia re-serialises the parameter map in a
    fixed key order: translation, then rotation, then scale, opacity, crops,
    then the rest [inf]. The exact order of keys not seen here (rotation,
    opacity) is [?]. `transform.md` §defaults lists the order seen in user
    projects.
- **Inner track key order:** `trackIndex`, `medias`, `parameters`, `ident`,
  `audioMuted`, `videoHidden`, `magnetic`, `matte`, `solo`.
- **When the short form changes.** Only after a *Cut/Paste* (§3) does
  Camtasia write the long form for all of these.

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

## 8. Copy and paste with groups (session 8, 2026-10-21)

This answers the open [WizRec] items of DECISIONS "Copy/paste inside groups".

Sources:

- **Plain groups.** Base: the 10 s video and the 1600×900 photo, selected
  together and grouped. The group's scale was set to 50 % and X to 200
  (`g1-group`). A second group holds one video and has an identity
  transform.
- **Rev media.** A copy of the user's demo project. Its group has
  `groupType` "revMedia".

All saves are under `camtasia_rea_refs/research/groups/`. Clips were
selected with a single click on the timeline, then copied and pasted with
*Edit ▸ Copy/Paste*; the paste goes to the playhead.

### 8.1 Opening a group

| Claim | Tag |
|---|---|
| A plain group opens with its "+" button (or *View ▸ Open Group*). While it is open, the timeline shows **only that group's inner tracks**, at timeline positions; the top-level tracks are not shown. The close button sits on the bar above the ruler | [obs] |
| An open group is saved with `metadata.isOpen` = true; closing it writes false | [obs] `g1b-open`, `g5-paste-top` |
| **Rev media cannot be opened.** *View ▸ Open Group* is disabled for it, and its context menu offers only *Unpack Rev Media*, *Rename Rev Media* and *Modify Rev Media…* | [obs] |
| *Clip Speed* is **disabled for groups**; it is enabled for clips inside an open group | [obs] |

So a selection always comes from one container: the top-level tracks, or
the inner tracks of the one open group [obs, a consequence of the UI].
Nothing can be copied out of, or pasted into, Rev media without unpacking
it. **WizRec's "one container" rule matches.**

### 8.2 What a copied clip carries

| Claim | Evidence | Tag |
|---|---|---|
| A nested clip keeps its own `duration`, `mediaStart`, `mediaDuration` and `scalar`. A 2× inner video (`scalar` 1/2, `mediaStart` 2 s, 4 s long) pasted at top level is identical | `g11-speed-copy-out` | [obs] |
| Groups cannot have a speed, so there is no group speed to bake in | §8.1 | [obs] |
| **Transforms are copied in canvas space.** The copied clip's transform is composed with its enclosing group's transform. The photo inside the 50 %/X 200 group (its own transform identity) pasted at top level arrives with `scale0`/`scale1` 0.5 and `translation0` 200 | `g5-paste-top` | [obs] |
| **On paste into a group, the canvas-space transform is re-expressed relative to that group.** Pasted back into its own group, it is identity again. In the identity group, it keeps scale 0.5 and X 200. A clip copied at top level with X 0, pasted into a group whose `translation0` is 1, gets `translation0` −1 | `g2-paste-open-6s`, `g6-paste-other-group`, `rev5-plain-group` | [obs] |
| Pasted parameters are written in the long form (`{type, defaultValue, interp}`), as in §3 | g5, g6 | [obs] |
| `metadata` (including `ShaderVidSource`) is copied as is | `rev4-bg-copy`, `rev5-plain-group` | [obs] |

The group composition maths (scale × child, translation × group scale +
group translation) is §6's ungroup rule; the paste into a group inverts it
[inf].

- **Matches WizRec:** the clip keeps its own `duration` and `scalar`.
- **Differs from WizRec:** the transform *is* baked. WizRec copies the inner
  clip's local transform unchanged.
- **Needed change [inf]:**
  - On copy from inside a group, store the composed (canvas) transform.
  - On paste into a group, divide it back out through every enclosing
    group.
  - A top-level paste of a group-copied clip then lands where the clip was
    seen on the canvas.

### 8.3 Pasting into an open group

| Claim | Evidence | Tag |
|---|---|---|
| **Playhead mapping.** Inner start = playhead − group `start` + group `mediaStart` (scalar 1). Playhead 15 s on a group at 12 s gives inner 3 s; playhead 16 s on a group at 14 s with `mediaStart` 2 s gives inner 4 s | `g8-paste-offset-group`, `g9-paste-trimmed-group` | [obs] |
| **Playhead before the window.** The paste lands at the window start (inner time = group `mediaStart`). Playhead 5 s, group at 14–22 s, `mediaStart` 2 gives inner 2 s | `g10-paste-outside-window` | [obs] |
| **Playhead at or after the window end.** The playhead cannot pass the project end. At the group's end (10 s) the clip landed at inner 10 s, entirely **outside** the visible window (hidden), and nothing refused it | `g4-paste-open-past-end` | [obs] |
| **Track choice.** The clip goes to an existing inner track that is free for its whole span, and the lowest such track was used each time. Inner 6 s went to inner track 1 (track 0 busy). Inner 10 s went to inner track 0 (track 1 busy) | g2, g4 | [obs]; "lowest free" [inf] |
| **Overlap.** When no inner track is free, a **new inner track** is added on top (index = count). Seen four times | g3, g8, g9, g10 | [obs] |
| **The group never grows.** `duration`/`mediaDuration` stay as they were, even when the pasted clip runs past the window (inner 6–11 s in a 0–10 s group; inner 10–15 s). The overflow is simply hidden | g2, g4, g9 | [obs] |

WizRec (`PasteClips` group mode, `InsertClipInGroup`):

- **Matches:** the playhead mapping; a new inner track for an overlap.
- **Differs: the window bound.** WizRec requires the start to be inside the
  visible window. Camtasia clamps a playhead before the window to its start,
  and accepts an end-of-window paste that is wholly hidden.
- **Differs: growth.** WizRec grows the group (and every enclosing group).
  **Camtasia does not.**
- **Needed change [inf].** Clamp `time` to `[window start, window end]` and
  don't grow the group. If WizRec wants to keep growth as a convenience, it
  must be a separate, explicit command.

### 8.4 Group keys

| Claim | Evidence | Tag |
|---|---|---|
| A plain group (made by *Edit ▸ Group*) has no `Rev*` keys and no `groupType`, and pasting a background clip into it adds none | `rev5-plain-group` | [obs] |
| A copied or pasted clip keeps `ShaderVidSource` (top-level copy, and a paste into a plain group) | `rev4-bg-copy`, `rev5-plain-group` | [obs] |
| Rev media can't be opened, so nothing is pasted into it and none of its inner clips can be copied. `RevBackground`/`RevLook`/`RevLayoutID` only travel when the whole Rev group is copied | §8.1 | [obs]; whole-group copy [inf from §3] |
| *Unpack Rev Media* removes the group, and with it every `Rev*` key. The background clip keeps `ShaderVidSource` at top level and gains the usual clip metadata keys, in sorted order (`ShaderVidSource`, `audiateLinkedSession`, `clipSpeedAttribute`, `colorAttribute`, `effectApplied`) | autosave of the unpacked project (`rev3-autosave`) | [obs] |

**WizRec matches:** group keys never travel with a nested clip;
`ShaderVidSource` does; a pasted background sets no `RevBackground`.
**Additional rule:** WizRec may treat `groupType` "revMedia" groups as
closed. Camtasia never lets the user edit inside them [inf, UI parity].

### 8.5 Other observations

- Trim Start to Playhead on a group whose inner track holds a video moves
  that video's `start` and `mediaStart` (2 s and 2 s) and writes no
  `trimStartSum` [obs, `g9-paste-trimmed-group`].
- **Unexplained `translation0` of ±1.** In two saves, a clip that was clicked
  or pasted got `translation0` 1.0 that nobody asked for (`g2` id6,
  `rev4` pasted copy). That is probably a one-pixel canvas nudge from the
  synthetic click. It is not a paste rule [?].

## Open

- Rotation and crop in the bounding box at group creation, and rotation in
  ungroup composition [?].
- ~~Whether drops into an open group grow the group~~: pastes never grow it
  (§8.3). Drops from the media bin into an open group were not tried [?].
- ~~How trim-start behaves on inner videos~~: `mediaStart` moves (§8.5)
  [obs].
