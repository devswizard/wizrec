# Camtasia session 1: reference exports and experiments

This is one sitting in Camtasia, about 60 minutes. It gives the golden-frame
tests their reference videos and answers the format questions we can't settle
from existing files. Everything is saved to
`~/WorkDir/vibe_coding/camtasia_rea_refs/`, which is outside the repo, and
nothing here touches your existing projects.

## Part A: reference exports (about 25 minutes)

There are 15 small test projects, all made from original synthetic test cards.
Each one is at `~/WorkDir/vibe_coding/camtasia_rea_refs/<case>/<case>.cmproj`.

For each case:

1. Open it in Camtasia.
2. Choose **Export ▸ Local File… ▸ MP4** at 1920×1080, 30 fps, highest
   quality.
3. Save it as `<case>/reference.mp4`, next to the `.cmproj` and not inside it.
   Batch Export is fine if the files land under those names.
4. Close the project **without saving**.

The full per-case checklist is in
[`reference-exports.md`](reference-exports.md). Note these for each case:

- Did it open without a warning?
- Does it look as the checklist describes?
- **scale-rotate:** does it turn clockwise or counter-clockwise, and what
  rotation does Properties show?
- **geometry-crop** and **source-crop:** which edge lost the most, and did the
  visible part stay centred?
- **keyframes-trimmed** and **keyframes-speed:** what is the A-counter value
  when the card starts moving and when it stops?
- **speed-half:** are the in-between frames blended?

## Part B: experiments (about 35 minutes)

For each experiment, make the edit, park the playhead **on the edited clip**,
then **File ▸ Save As** into `~/WorkDir/vibe_coding/camtasia_rea_refs/format/`.
No exports are needed, because each saved project includes a thumbnail that
Camtasia renders itself. Use any photo and any video of your own (at least
20 s long, with sound).

**Setup:** File ▸ New Project (1920×1080), then import one landscape photo
and the video.

- **X1, crop:**
  1. Put the photo on track 1 at 0 s, at its default size.
  2. Crop **only the left side** by about a quarter. Use the canvas crop
     handles, or the Crop fields in Properties.
  3. Save as `x1-left.cmproj`.
  4. Undo, then crop **only the top** by about a quarter.
  5. Save as `x1-top.cmproj`, then undo.
- **X2, rotation:**
  1. Set the photo's Properties ▸ Rotation Z to **+30°**.
  2. Save as `x2-rot30.cmproj`, then undo.
- **X3, group geometry:**
  1. Put a second copy of the photo on track 2, shifted left.
  2. Select both copies ▸ Group.
  3. Move the group right by about 200 px and set its Scale to 50 %.
  4. Save as `x3-group.cmproj`.
- **X5, group time:** this continues from X3.
  1. Drag the group so it starts at 10 s.
  2. Drag the group's **left edge** right by 1 s.
  3. Save as `x5-group-time.cmproj`.
- **X6, image trim:**
  1. On a new track, put the photo at 0 s.
  2. Add Animations ▸ Fade In, or any animation at its start.
  3. Drag its **left edge** right by 1 s.
  4. Save as `x6-image-trim.cmproj`.
- **X7, split, trim and move:** one new project, saved four times. Park the
  playhead at 6 s before each save. Each step continues from the previous
  save, so don't reopen earlier files.
  - **Build** (File ▸ New Project, 1920×1080):
    - Track 1:
      1. Put the video at 0 s.
      2. Split it at 4 s and at 8 s, then delete the middle piece.
      3. Drag the right piece left until it touches the first piece.
      4. Select both pieces ▸ right-click ▸ **Stitch Selected Media**.
      5. On the stitched clip, add a Scale animation from 1 s to 2 s, and add
         the Drop Shadow effect.
    - Track 2:
      1. Put the photo at 2 s, 8 s long, so it ends at 10 s.
      2. Add a Fade transition at its start and another at its end.
      3. Add Behaviors ▸ Pop Up.
    - Track 3: put a copy of the video and a copy of the photo on two tracks,
      both starting at 0 s and each about 10 s long. Select both ▸ **Group**.
    - Track 4:
      1. Put the video at 0–5 s and another copy at 5–10 s, so they touch.
      2. Put a Cube transition (or any two-sided transition) on the cut
         between them.
    - Track 5: add any callout at 0–3 s.
    - Save as `x7-before.cmproj`.
  - **Split:**
    1. Select the clips on tracks 1, 2 and 3.
    2. Put the playhead at 6 s and press **S**.
    3. Save as `x7-split.cmproj`.
  - **Trim:**
    1. Drag the left edge of the **right** photo half (track 2) right by 1 s.
    2. Drag the left edge of the **left** photo half left by 1 s, past its
       original start. If Camtasia refuses, leave it.
    3. Drag the right edges of the right halves on tracks 1 and 3 as far
       right as they will go.
    4. Drag the callout's right edge right to 20 s.
    5. Save as `x7-trim.cmproj`.
  - **Move:**
    1. Drag the right photo half on track 2 (the one with the end fade) right
       by 3 s.
    2. Drag the second clip on track 4 right by 2 s, so a gap opens at the
       Cube transition.
    3. Save as `x7-move.cmproj`.

The old experiment X4 (keyframes on a sped-up clip) is covered by the
`keyframes-speed` case in Part A.

## When you're done

Tell the lead "session 1 done" and paste your notes from Part A. The golden
tests then run with:

```sh
REFS_DIR=~/WorkDir/vibe_coding/camtasia_rea_refs swift test --filter GoldenTests
```
