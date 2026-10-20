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
| 8 | **Move keeps one-sided transitions with their clip.** After Cut/Paste of the right image half (3 → 6 s), its end fade still names it as `leftMedia`. The two-sided case is not yet observed: the Cube transition was not applied, because the panel item name did not match. It is to be repeated. | [obs] one-sided; [?] two-sided |
| 9 | `UnifiedMedia` | [?] the synthetic test cards have no audio stream; to be repeated with a speech+video source |

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
