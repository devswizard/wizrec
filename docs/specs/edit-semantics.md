# Spec: edit semantics (split, trim, move) — evidence status

How Camtasia's edits change the project JSON. These are the assumptions
TimelineEngine made for M1/M3. Each one is marked with what the existing files
show and, where they show nothing, the experiment (X7, below) that settles it.

Tags: **[obs]** observed in files, **[inf]** inferred, **[?]** unknown.

## What the existing files already show

### E1 — split products in the user's vlog

The vlog holds 18 pairs of clips that sit next to each other on the same
track, use the same source, and continue each other's media: 1 pair of
`UnifiedMedia` and 17 of `AMFile`. These pairs are what a split produces [obs]:

```
right.start      = left.start + left.duration
right.mediaStart = left.mediaStart + left.mediaDuration
scalar           = 1 on both
```

- Apart from the times and ids, each pair is identical. The one difference is
  `attributes.gain` (for the `UnifiedMedia` pair, `audio.attributes.gain`),
  which the user changed after splitting. Parameters, effects, metadata and
  other attributes are equal [obs].
- So a split copies every non-timing field to both halves [inf, strong].
- In the `UnifiedMedia` pair, each half's `video` and `audio` children repeat
  that half's times (`time-mapping.md` §4). Both children are therefore cut
  at the same track time [obs, for scalar 1].

### E2 — ids are renumbered on save

In all 24 projects, the integer `id`s are **dense (1…n) and strictly
increasing in document order**. That covers `sourceBin` ids, `timeline.id`
and every clip, nested ones included [obs]. Example: vlog, 283 ids, 1…283, in
order. The ids of edit history cannot all be dense like this, so Camtasia
must renumber on save [inf, strong].

Consequences:

- Camtasia does not keep ids stable across its own saves. Transition
  `leftMedia`/`rightMedia` and every other id reference are rewritten
  together with the ids [inf].
- WizRec can allocate new ids above `maxID`, as the contract says. Tests
  must not expect Camtasia to keep our ids.
- Id order in a Camtasia-saved file reveals nothing about which half of a
  split is "new" [obs].

### E3 — frame alignment

With `allowSubFrameEditing: false`, every `start`, `duration`, `mediaStart`
and `mediaDuration` in v10 files is a whole number of output frames. The only
exception is the `mediaDuration` of a sped-up clip (`time-mapping.md` §2)
[obs, 297/298]. So in this mode, UI edits (split, trim, move) snap to output
frames [inf, strong]. How editing behaves with `allowSubFrameEditing: true`
is [?]; no file has it set. This is low priority and not in X7.

## Assumptions and status

| # | Assumption (timeline) | Status | Resolved by |
|---|---|---|---|
| 1 | **Split `StitchedMedia`** partitions the segments. The left half keeps the segments up to its media end; the right half keeps the segments from its media start, rebased so they start at 0. (The alternative is that both halves keep every segment and only `mediaStart`/`mediaDuration` move.) | [?] Both readings fit the data. Every stitched clip has `minMediaStart` 0.0 and windows inside the segment list (`time-mapping.md` §4), and no stitched clip in the corpus has been split. | X7-split |
| 2 | **Split `Group`**: both halves get an unchanged copy of the inner timeline; only `mediaStart`/`mediaDuration` move. Inner clips are not cut. | [?] Only two groups exist, and neither is split. | X7-split |
| 3 | **Split with transitions**: a transition at the clip's end moves to the right half, and one at its start stays on the left half. | [?] One transition exists in the corpus (one-sided `RadialWipe`, `rightMedia` only). | X7-split |
| 4 | **Keyframes, effect windows and `animationTracks` are left alone** by split and trim, because they use the media-time base. | [inf] It follows from `time-mapping.md` §6: BlendModePreview callouts were left-trimmed, so they have `mediaStart` 22, and their keyframes stayed at media times 0…142. The split pairs in E1 have no keyframes. Whether Camtasia *prunes* keyframes that fall wholly outside a half is [?]. | X7-split, X7-trim |
| 5 | **Images**: split and trim never change `mediaStart` (0) or `mediaDuration` (1). A left-edge move adds to `trimStartSum`. Extending the left edge past the original edge is allowed and lowers `trimStartSum`, possibly below 0. | `mediaStart` 0 / `mediaDuration` 1 on all 16 images [obs]. `trimStartSum` is 0 everywhere [obs]. The rest is [?]. | X6 (already asked), X7-split, X7-trim |
| 6 | **Trim limits**: a group's right edge cannot pass its latest inner clip end; a stitched clip's right edge cannot pass its last segment end; a callout's right edge is unbounded. | [?] The demo group ends exactly at its latest child end [obs, 1 case]. This only shows the state, not the limit. | X7-trim |
| 7 | **Snapping**: split, trim and move land on output frames unless `allowSubFrameEditing` is set. | [obs + inf] (E3) | — (sub-frame mode [?], not asked) |
| 8 | **Move with transitions**: a one-sided fade travels with its clip. A two-sided transition is removed unless the two clips still touch. | [?] | X7-move |
| 9 | **`UnifiedMedia` halves** are split and trimmed at the same track time for video and audio. | [obs] for split (E1). [inf] for trim, because v10 children always repeat the parent's times. | X7-trim (confirmation) |

Additional [inf] from E1, kept here for timeline:

- A split copies parameters, effects (with their parameters), `attributes`,
  `metadata` and `animationTracks` to both halves unchanged.
- Each half gets new ids, and Camtasia renumbers everything on save anyway.

## X7 results (automated runtime saves, 2026-10-20)

Camtasia 2026.2.3 performed X7 through menu commands. One single-purpose
project was used per track type, so that selection by playhead was
unambiguous (ledger RT-008). Drags were replaced by their menu equivalents:

- **Delete middle piece and close the gap:** *Ripple Delete*.
- **Move:** *Cut*, then *Paste* at the playhead.
- **Trim start:** *Edit ▸ Playhead ▸ Trim Start to Playhead*.

Right-edge trims, past-the-edge extensions and the callout track need mouse
drags, so they were **not** done.

| # | Result | Tag |
|---|---|---|
| 1 | **Split `StitchedMedia`: both halves keep every segment.** Only the outer `start`/`duration`/`mediaStart`/`mediaDuration` change. The right half is a new `StitchedMedia` whose segment list is identical to the left's (new ids), with `mediaStart` at the split point. The segments are not partitioned or rebased. This is the reading the assumption rejected. | [obs] `x7v-d-split` |
| 1b | **Auto-stitch.** After *Split* at 4 s and 8 s and *Ripple Delete* of the middle piece, the two remaining pieces of the same source were saved as **one `StitchedMedia`**, with segments 0–4 s and 8–10 s, with no *Stitch* command. Whether split or ripple-delete triggers it is [?]. The stitched clip's `attributes` gain `gain` 1.0, `mixToMono` false, `loudnessNormalization` true and `sourceFileOffset` 0. Its parameters gain `smoothCursorAcrossEditDuration` 0. | [obs] `x7v-a-cut` |
| 2 | **Split `Group`: both halves get a full, unchanged copy of the inner tracks.** Only `mediaStart`/`duration` differ. Confirmed twice: once on stills (group-edits.md §5) and once on a video+still group split at 3 s, where the right group got `mediaStart` 3 s and inner copies with new ids. | [obs] `x7g-b-split` |
| 3 | **Split with transitions.** The transition at the clip's start stays on the left half, and the one at its end moves to the right half: its `leftMedia` becomes the right half's id. | [obs] `x7p-b-split` |
| 4 | **Split and trim do not touch keyframes, effect windows or behaviour windows.** Both stitched halves keep the 1–2 s scale keyframes, although the right half (media 5–6 s) never reaches them. A Pop Up behaviour keeps `start` 0 and `duration` 5 s on both image halves, and after a trim-start, although each half is shorter. Nothing is pruned. | [obs] `x7v-d-split`, `x7p-b-split`, `x7p-c-trimstart` |
| 5 | **Images.** `mediaStart` 0 and `mediaDuration` 1 (tick) never change. **A split gives the right half `trimStartSum` = the split offset** (2 s for a split 2 s into the image). Trim-start adds the trimmed amount to `trimStartSum` (2 s, then 3 s after a further 1 s). Extending past the original start was not tested (drag). | [obs] `x7p-b-split`, `x7p-c-trimstart`, `x6-image-trim` |
| 6 | Trim limits (right edge) | [?] not automated (drag) |
| 8 | **Move keeps one-sided transitions with their clip.** After Cut/Paste of the right image half (3 → 6 s), its end fade still names it as `leftMedia`. **Two-sided:** moving the incoming clip away splits the transition into an end transition on the clip that stayed and a start transition on the moved clip, both with the same name and duration (`transitions.md` §2, RT-016). | [obs] |
| 9 | **`UnifiedMedia` split** (repeated with our own video+speech MP4, RT-018): the parent and both children (`video`, `audio`) of each half carry **identical** `start`/`duration`/`mediaStart`/`mediaDuration`. A split at 25 s of a clip starting at 22.033 s gives a left half of 2.967 s and a right half with `mediaStart` 2.967 s, with new ids for the parent and both children. Trims are assumed to follow the same rule | [obs] split; [inf] trim |

Transition entries written by *Transitions ▸ Fade ▸ Add to Selected Media* on
a single clip [obs]:

- **Two entries.** One is at the start (only `rightMedia` = clip) and one at
  the end (only `leftMedia` = clip).
- **Fields.** Each has `duration` 1 s, the `name` `"LuminanceFadeIn"` and
  `attributes` {`bypass` false, `reverse` false, `trivial` false,
  `useAudioPreRoll` true, `useVisualPreRoll` true}.
- **Name.** Whether the panel's "Fade" item is the one Camtasia calls
  `LuminanceFadeIn` is [inf]: the search matched the item labelled exactly
  "Fade".

## Part J results (runtime saves, 2026-10-20, RT-018)

- **ED0, insert defaults** [obs]. Media dragged from the bin onto the
  timeline:
  - **Image:** 5 s, with `mediaStart` 0, `mediaDuration` 1 and
    `trimStartSum` 0.
  - **Video:** its full length (10 s).
  - **Video with audio:** one `UnifiedMedia` whose length is the **shorter**
    stream, floored to a whole frame. Video 10 s and audio 9.984 s gave
    9.9667 s (299 frames). The audio is not padded to the video's length.
  - **Start:** the drop position, snapped to a frame.
  - **Metadata:** every inserted clip gets `lockAspectRatio` true and
    `default-scale` "1".
- **ED1, Extend Frame to Playhead** [obs]. A 10 s video at 39.633 s was
  extended to the playhead at 52 s. Camtasia turned the clip into a
  **`StitchedMedia`** (`minMediaStart` 0.0; stitched `attributes` with gain
  1, `mixToMono` false, `loudnessNormalization` true, `sourceFileOffset` 0;
  parameters with plain-number crops and `smoothCursorAcrossEditDuration` 0)
  holding two segments:
  1. the original `VMFile`, 0–10 s;
  2. an **`IMFile` that points at the video source** (same `src`), with
     `ident` "Frame of <original ident>", `mediaStart` = the time of the
     last frame (9.9667 s), `mediaDuration` 1 (the image convention),
     `trimStartSum` 0, and a segment `duration` of 3602.37 s, far longer
     than needed. The outer clip's `duration` (12.367 s = 10 s + the 2.367 s
     extension) is what limits it.

  So a frozen frame is an **image clip that reads one frame of a video
  source**. WizRec must accept an `IMFile` whose source is a video and
  decode the frame at `mediaStart` [obs form; inf rendering].
- **ED2–ED4** were done in session 8 (below).

## Part J, ED2–ED4 (runtime saves, session 8, 2026-10-20, RT-020)

Base: a copy of `format/video-photo-base`: a 10 s video (`VMFile`, no audio)
on track 1 and a 1600×900 photo (`IMFile`, 5 s) on track 2. The setup was
1920×1080 at 30 fps. Inputs and saves are in
`camtasia_rea_refs/research/timeline/ed11/`.

How the steps were automated:

- **Drags** were synthetic mouse events. The helper waits 25 ms between steps
  and holds 0.8 s before releasing.
- **Media-bin drops** landed every time once the timeline pane had been
  enlarged. The earlier failures came from the 186 px timeline pane.
- **Fields** were set by focusing the AX text field, then typing the value
  and Return.

### ED2: Clip Speed 1.5× from the Properties field

*Modify ▸ Add Effects ▸ Visual Effects ▸ Clip Speed* adds a "Clip Speed"
section to Properties. Its fields are *Speed* (shows `1.00x`) and *Duration*
(minutes, seconds, frames). Typing `1.5` into *Speed* gave `1.50x`, and the
project became 6;20 long (`ed2-speed`).

| Field | Before | After | Tag |
|---|---|---|---|
| `scalar` | 1 | `"2/3"`: a rational **string**, = 1 / speed | [obs] |
| `duration` | 10 s | 6.6667 s (4704000000 ticks = 200 frames, exactly 10 / 1.5) | [obs] |
| `mediaStart` / `mediaDuration` | 0 / 10 s | unchanged | [obs] |
| `metadata.clipSpeedAttribute.value` | false | true | [obs] |
| `metadata.effectApplied` | "none" | "Clip Speed" | [obs] |
| `effects` | [] | still [] (no effect entry for Clip Speed) | [obs] |
| Other clips | — | untouched (the video was alone on its track) | [obs] |

**WizRec (`SetSpeed`, `RetimeCommands.swift`): matches.** It uses
`scalar = 1/speed`, keeps the media range, floors `duration` to a frame,
and sets the same two metadata keys without adding an effect. Here
10 / 1.5 is a whole number of frames, so the flooring and the
`mediaDuration` recompute were not exercised. The non-frame-exact case is
answered in the next subsection.

### ED2b: a speed whose duration is not a whole number of frames (session 9, RT-024)

Base: a fresh copy of `format/video-photo-base` (30 fps; the 10 s video is
300 frames). The speed was typed into the Clip Speed *Speed* field, one
value after another on the same clip, with a Save As after each. Saves
are in `camtasia_rea_refs/research/timeline/ed12/`.

| Typed | Exact `mediaDuration / speed` | Saved `duration` | Saved `scalar` | Field shows afterwards | Save | Tag |
|---|---|---|---|---|---|---|
| 1.3 | 230.77 frames | **230 frames** (7;20) | `"23/30"` (= 230/300) | 1.30x | `sp-1_3` | [obs] |
| 0.7 | 428.57 frames | **428 frames** (14;08) | `"107/75"` (= 428/300) | 0.70x | `sp-0_7` | [obs] |
| 1.9 | 157.89 frames | **157 frames** (5;07) | `"157/300"` | **1.91x** | `sp-1_9` | [obs] |
| *Duration* field set to 5;11 | — | 161 frames | `"161/300"` | 1.86x | `sp-dur-5s11f` | [obs] |
| 1.9 on a clip trimmed to `mediaStart` 3 s, `mediaDuration` 7 s | 110.53 frames | **110 frames** (3;20) | `"11/21"` (= 110/210) | 1.91x | `sp-trim3-1_9` | [obs] |

The rule, from these five saves:

- **`duration` is floored to a whole frame**, never rounded: 0.7 and 1.9
  would round up, and both went down [obs].
- **`mediaStart` and `mediaDuration` never change** [obs, all five saves,
  including the trimmed clip].
- **`scalar` is recomputed from the floored duration**:
  `scalar = duration / mediaDuration`, written as a reduced rational
  string. So `mediaDuration × scalar = duration` holds exactly, and the
  effective speed is slightly above the typed one when the floor bites
  [obs]. The *Speed* field then shows that effective speed, rounded to two
  decimals (1.9 is shown as 1.91x) [obs].
- **Typing a duration** works the same way: the frame count you type
  becomes `duration`, and `scalar` = `duration / mediaDuration` [obs].
- Each save changed only `duration`, `scalar`, the project's
  `commandCount` and `projectDuration` [obs].

**WizRec differs [inf].** `SetSpeed` floors the duration as Camtasia does,
but then keeps `scalar = 1/speed` and recomputes `mediaDuration` as
`duration / scalar`. That shortens the media range by up to one frame's
worth of media. Camtasia keeps the media range and adjusts `scalar`
instead. To match, WizRec should keep `mediaDuration` and write
`scalar = duration / mediaDuration` after flooring. When the duration is
frame-exact (ED2), both give the same result.

### ED3: magnetic track drops

The *Enable Magnetic Track* item in the track-header context menu sets
`trackAttributes[i].magnetic` to true [obs]. The photo and the video were
dragged from the media bin onto the new empty magnetic track 3.

| Step | Drop point (cursor) | Result | Save | Tag |
|---|---|---|---|---|
| 1 | photo at ≈ 3 s on the empty track | photo at **0 s** | `ed3a-magnetic-two` | [obs] |
| 2 | video at ≈ 20 s | video at **5 s**, touching the photo | `ed3a-magnetic-two` | [obs] |
| 3 | photo exactly on the 5 s boundary | **inserted** at 5 s; the video was pushed to 10 s | `ed3-magnetic` | [obs] |
| 4 | photo at ≈ 23.6 s, past the end | appended at 20 s | `ed3b-magnetic-append` | [obs] |
| 5 | photo inside the video (≈ 11.9, 15.4 and 15.7 s, video at 10–20 s) | **nothing added**, three times | — | [obs] for these synthetic drags |
| 5′ | control: photo at ≈ 2 s on non-magnetic track 2, over the existing photo | nothing added | — | [obs] |
| 6 | first clip selected, then the Delete key | the gap closed: 5→0, 10→5, 20→15 | `ed3c-magnetic-delete` | [obs] |

- **Packing.** A magnetic track is kept packed from 0 with no gaps. Drops
  into empty space go to the end, and plain Delete behaves as a ripple
  delete [obs].
- **Drops onto a clip.** A drop whose point lies inside a clip is refused,
  as on a normal track, and a drop at a boundary inserts there. This is
  [inf]: the hover feedback was not visible to the automation, and a
  slower drag with a 1.5 s hold made no difference.
- **Defaults.** Dropped clips get the ED0 insert defaults:
  `lockAspectRatio` true, `default-scale` "1", and `effectApplied` "none"
  [obs].

**WizRec (`Magnetic.swift`):**

- **Matches:** packing from 0, appending, inserting at a boundary, and
  closing the gap after a delete.
- **Differs:** a requested start inside a clip. WizRec never refuses: it
  inserts before the first clip whose midpoint lies after the requested
  start. Camtasia refused these drops [inf, see above]. This only matters
  for drag-and-drop UI. API callers that pass a boundary get the same
  result.

### ED4: Shift-drag of a start edge

Setup on a new track 4 (`ed4a-before`): the video at 0–10 s and the photo
at 10–15 s, touching. Then the video's **left edge was dragged right by
2 s while Shift was held**. The Shift key-down/up events were posted
around the drag, and every mouse event carried the Shift flag.

| Case | Result | Save | Tag |
|---|---|---|---|
| Nothing selected before the drag | Video `start` 0→**2 s**, `mediaStart` 0→2 s, `duration` 10→8 s. The photo **did not move** (still at 10 s). The gap is now at 0–2 s | `ed4-shift-trim` | [obs] |
| The photo was still selected from its drop | Shift-press added the video to the selection, and the drag trimmed **both** clips' start edges by 2 s. Video as above; photo `start` 12 s, `duration` 3 s, `trimStartSum` 2 s (`mediaStart` 0, `mediaDuration` 1 unchanged) | `ed4-ripple-try1` | [obs] |

- **Shift-drag is a plain trim.** It does not ripple in Camtasia 2026.2.3
  [obs]. Shift was delivered, because it extended the selection in the
  second case. Shift therefore acts as *add to selection*, and an edge drag
  trims the same edge of every selected clip by the same amount [obs].
- **Video trim-start** moves `mediaStart` and writes no `trimStartSum`.
  Image trim-start adds to `trimStartSum` (as X7 #5) [obs].
- **No ripple trim by edge drag or by menu** [obs, follow-up saves in the
  same folder]. Each case started from `ed4a-before` (or an Undo back to
  it) with nothing selected:

  | Gesture | Result | Save |
  |---|---|---|
  | Plain drag of the start edge (control) | The same as Shift-drag: video 2–10 s, photo still at 10 s | `ed4b-plain-trim` |
  | Command-drag of the start edge | Nothing changed | — |
  | Option-drag of the start edge | Nothing changed | — |
  | Shift-drag of the **end** edge, 2 s left | Video 0–8 s; the photo stays at 10 s, leaving a gap | `ed4c-shift-end` |
  | *Edit ▸ Playhead ▸ Trim Start to Playhead* at 2 s | Video 2–10 s; the photo did not move | `ed4d-trimstart-playhead` |

  - **What Camtasia 2026.2.3 offers.** The Edit menu's only ripple commands
    are *Ripple Cut* and *Ripple Delete*. On a normal track, trims never move
    the neighbours.
  - **Magnetic tracks** pack after every edit (ED3). Trimming there acts like
    a ripple trim [inf].

**WizRec (`RippleTrim`):**

- **Different command.** `RippleTrim` keeps the clip's `start` and shifts
  later clips left. That is not what Shift-drag does in Camtasia, and
  Camtasia has no gesture that does it on a normal track. `RippleTrim` is
  therefore a WizRec-only convenience: keep it, but don't bind it to plain
  Shift-drag if the goal is Camtasia muscle memory [inf].
- **The plain trim matches.** WizRec's plain `TrimClip` gives the same
  result as Camtasia's Shift-drag for one selected clip.
- **Multi-clip trim.** Trimming every selected clip's edge together is not
  a WizRec command [WizRec gap; app-level].

## X7 — one project, four saves (about 10 minutes)

Use the user's own video (≥ 20 s, with sound) and photo. Every step ends with
*File ▸ Save As* into `~/WorkDir/vibe_coding/camtasia_rea_refs/format/`.
Before each save, park the playhead at 6 s. Each later step continues from the
previous save; it does not reopen an earlier one.

**Build** (File ▸ New Project, 1920×1080):

- **Track 1 — stitched clip.**
  1. Put the video at 0 s.
  2. Split it at 4 s and at 8 s, then delete the middle piece.
  3. Drag the right piece left until it touches the first.
  4. Select both pieces, right-click, and choose *Stitch Selected Media*.
  5. On the stitched clip, add a *Scale* animation from 1 s to 2 s and the
     visual effect *Drop Shadow*.
- **Track 2 — image.**
  1. Put the photo at **2 s**, 8 s long, so it ends at 10 s.
  2. Add a *Fade* transition at its start and another at its end.
  3. Add *Behaviors ▸ Pop Up*.
- **Track 3 — group.** Put a second copy of the video and a second copy of
  the photo on two tracks, both from 0 s and each about 10 s long. Select
  both and choose *Group*.
- **Track 4 — two-sided transition.**
  1. Put the video at 0–5 s and another copy at 5–10 s, touching.
  2. Put a *Cube* transition (or any two-sided transition) on the cut
     between them.
- **Track 5 — callout.** Add any callout at 0–3 s.

Save as **`x7-before.cmproj`**.

**Split** (assumptions 1–5 and 9): select the clips on tracks 1, 2 and 3,
put the playhead at **6 s**, and press *S* (Split). At 6 s the stitched
clip's split point falls inside its second segment. Save as
**`x7-split.cmproj`**.

**Trim** (assumptions 4–6 and 9):

1. Drag the left edge of the *right* photo half (track 2) right by 1 s.
2. Drag the left edge of the *left* photo half left by 1 s. This goes past
   its original 2 s start; if Camtasia won't allow it, leave it.
3. Drag the right edges of the right halves on tracks 1 and 3 as far right
   as they will go.
4. Drag the callout's right edge right to 20 s.

Save as **`x7-trim.cmproj`**.

**Move** (assumption 8):

1. Drag the right photo half on track 2 (it carries the end fade) right by
   3 s.
2. Drag the second clip on track 4 right by 2 s, so a gap opens at the cube
   transition.

Save as **`x7-move.cmproj`**.

Send all four bundles. Diffing them answers assumptions 1–6, 8 and 9. X6
(image trim) and X4 (keyframes on a sped-up clip) from `time-mapping.md` are
still needed separately: X7 has no speed change, and X6 includes a fade-in
animation that X7 lacks.
