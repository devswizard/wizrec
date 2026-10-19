# Reference exports for the golden-frame tests

The golden tests compare WizRec's renderer with Camtasia's own export of the
same project, frame by frame (SSIM ≥ 0.97 on these effect-free cases). This page
tells you how to make those reference exports. It takes about 20–30 minutes for
all 15 cases, and you can do them in any order: every case you export starts
being tested straight away.

Everything here is original test material. `wizrec-testgen` synthesises the
media (test cards with a frame counter, a still card, a magenta marker) and
builds the projects with TSCProjKit. Nothing lives in the repo: the cases sit
next to it, in `~/WorkDir/vibe_coding/camtasia_rea_refs/`.

## 1. Generate the cases (already done once)

```sh
swift run wizrec-testgen            # all cases → ~/WorkDir/vibe_coding/camtasia_rea_refs/
swift run wizrec-testgen --list     # what each case contains
swift run wizrec-testgen --case speed-2x --force   # rebuild one case
```

Each case folder looks like this:

```
camtasia_rea_refs/<case>/
  <case>.cmproj      ← open this in Camtasia
  golden.json        ← test manifest (frames to compare, thresholds)
  reference.mp4      ← your export goes here
```

Rebuilding a case never deletes `reference.mp4`, but if a case changes you
will be told to export it again.

## 2. Export each case

For every folder under `~/WorkDir/vibe_coding/camtasia_rea_refs/` (skip
`_media`):

1. Open `<case>/<case>.cmproj` in Camtasia (double-click it, or
   *File ▸ Open Project…*).
2. Look at it for a moment and note anything from the checklist in §3 that is
   not as described, especially any warning, missing-media message, or
   "project was upgraded/repaired" notice when it opens.
3. *Export ▸ Local File…* and set:
   - **File format:** MP4.
   - **Resolution / size:** **1920 × 1080** (the project's own dimensions;
     no scaling, no letterbox).
   - **Frame rate:** **30 fps**.
   - **Quality:** the highest available (or bitrate ≥ 20 Mbps).
   - **Audio:** either way (the projects have no audio).
   - No watermark, no Smart Player / HTML, no captions.
4. Save it as **`reference.mp4` in the case folder**, i.e. next to
   `<case>.cmproj`, *not* inside it. Example:
   `~/WorkDir/vibe_coding/camtasia_rea_refs/translate/reference.mp4`.
5. Close the project. If Camtasia asks whether to save changes, **Don't Save**
   (saving is harmless, but don't edit anything).

If your Camtasia offers *Batch Export*, you can queue all projects at once with
the same settings; just make sure each output ends up as
`<case>/reference.mp4`.

The export must have exactly the number of frames shown in the table (the
timeline length); the tests check frame *n* at time *n*/30 s.

## 3. Checklist — please report for each case

Reply with one line per case: **opened OK? (yes/no)**, **looks as described?
(yes/no)**, and anything odd. For the "note …" items, a word or two is enough
(e.g. "rotates counter-clockwise").

| Case | Frames | What you should see in Camtasia |
|---|---|---|
| `baseline` | 150 | Test card **A** fills the canvas; the counter starts at `A 0000` and counts up one per frame. |
| `translate` | 150 | A half-size card A sits exactly in the **top-right quarter** of the canvas. |
| `scale-rotate` | 150 | Card A is squashed (wider than tall) and rotated by 30°. **Note:** clockwise or counter-clockwise? What rotation does the Properties panel show? |
| `geometry-crop` | 150 | Card A at 80 % size, cropped by a different amount on each edge. **Note** which edge lost the most (expected: top 20 %, bottom 15 %, left 10 %, right 5 %). |
| `source-crop` | 90 | The still image card, cropped by a different amount on each edge. **Note** which edge lost the most, and whether the visible part stayed centred or shifted. |
| `opacity` | 150 | Card **B** at its native 1280×720 size in the middle, half transparent: card A shows through it. |
| `keyframes-linear` | 180 | The magenta marker (lower half) slides from left to centre (0.5–1.5 s), pauses, then slides to the right (2–5 s), at constant speed. Card A (top-left) grows and fades. Properties shows Position X animating −800 → 0 → 800. |
| `keyframes-eioe` | 180 | Same as above, but each move eases in and out. |
| `keyframes-trimmed` | 150 | A small card A whose counter starts at `A 0030` slides left → right. **Note** the timeline time (or the A counter) where it starts and stops moving. |
| `keyframes-speed` | 120 | Same small card, clip speed **2×** (counter advances by 2). **Note** the A counter values where it starts and stops moving. |
| `group-offset` | 180 | Black for the first second; then one **group** clip: card A on the left (counter starts at `A 0060`), card B joins on the right at 2 s (`B 0000`), A leaves at 3 s. The group is slightly above centre at 80 % size. |
| `stitched` | 120 | One clip with two cut marks. The counter runs `A 0015 … 0059`, jumps to `A 0150 … 0209`, then `A 0090 … 0104`. |
| `speed-2x` | 120 | Clip speed shows **2×** (200 %). The counter advances by 2 per frame from `A 0030`. |
| `speed-half` | 180 | Clip speed shows **0.5×** (50 %). The counter advances every second frame. **Note** whether in-between frames look blended (a double image). |
| `two-track-overlap` | 150 | Three tracks. Card A full screen (bottom), the still card from 1 s to 4 s (upper left), card B from 2 s (counter from `B 0030`) partly covering the still card: **B in front**. |

## 4. After exporting

- Tell the lead which cases are exported and paste the checklist answers.
- Run the golden tests (they skip any case without a `reference.mp4`):

  ```sh
  REFS_DIR=~/WorkDir/vibe_coding/camtasia_rea_refs swift test --filter GoldenTests
  ```

  On a failing frame the test prints where it wrote `rendered`, `reference`,
  `diff4x` and `ssim` PNGs (default `$TMPDIR/WizRecGolden/<case>/`; override
  with `GOLDEN_OUT`, or set `GOLDEN_DUMP=1` to keep them for every frame).
- The "reference shows the predicted source frames" test reads the frame
  counter barcode in the `baseline`, `stitched`, `speed-2x` and `speed-half`
  exports and checks it against the time-mapping spec. It needs no renderer,
  so it gives results as soon as you export.
- The keyframe cases feed the `eioe` curve fit (research backlog item 2):

  ```sh
  swift run wizrec-testgen track-marker ~/WorkDir/vibe_coding/camtasia_rea_refs/keyframes-eioe/reference.mp4 > eioe.csv
  ```

  prints the marker's centre per frame, in canvas pixels from the centre.

## Notes

- The projects carry `authoringClientName.name = "WizRec testgen"`. If
  Camtasia refuses to open them, say so: that field is the first suspect.
- The projects use `editRate` 705600000, format `10.0`, 30 fps, canvas
  1920×1080, black background, and no effects, transitions, audio or callouts.
- The media is linked by hard link from `_media/`, so all cases together take
  only a few MB.
