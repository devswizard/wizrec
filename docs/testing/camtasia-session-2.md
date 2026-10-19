# Camtasia session 2: effect sheets and research experiments

This is one sitting in Camtasia, about **2 hours**. Every part stands alone, so
you can stop at the end of any part and carry on later. It gives the effect
golden tests their reference renders and answers the format questions that
the specs mark [?].

- Everything is saved under `~/WorkDir/vibe_coding/camtasia_rea_refs/`, which
  is outside the repo. Nothing here touches your existing projects.
- Session 1 (`camtasia-session-1.md`) is separate. Nothing from it is
  repeated here.
- Paths below are written in full so you can paste them into a Save dialog:
  press **⇧⌘G** in the dialog and paste the folder.

| Part | What | Minutes |
|---|---|---|
| 0 | Setup | 3 |
| A | Generated effect and callout sheets (EF1–EF7, CO1, CO2) | 25 |
| B | Effect parameter discovery (EF0) | 6 |
| C | Shader backgrounds (SH1–SH3) | 6 |
| D | Transitions (TR1–TR3) | 12 |
| E | Behaviours (BH1–BH2) | 8 |
| F | Region callouts (CO3) | 5 |
| G | Captions (CA1–CA2) | 12 |
| H | Screen recordings and cursor effects (TM1–TM3, CE1–CE3) | 20 |
| I | Audio (AU1–AU2) | 10 |
| J | Edit behaviour checks (ED0–ED4) | 10 |
| K | Report back | 3 |

## Part 0: setup (3 minutes)

You need:

- one landscape photo of your own;
- one video of your own, at least 20 s long, **with speech** (you talking to
  the camera is ideal). Use nothing private: it ends up in saved projects;
- Terminal, for two short commands (Parts H and I are the only ones that
  need it).

Create the research folders once. Paste this into Terminal:

```sh
mkdir -p ~/WorkDir/vibe_coding/camtasia_rea_refs/research/{effects,shaders,transitions,behaviors,callouts,captions,cursor,audio,timeline}
```

**When saving:** always use **File ▸ Save** (⌘S) or **File ▸ Save As…** as the
step says. If Camtasia asks to update or convert a project, accept, and note
it for Part K.

## Part A: generated sheets (about 25 minutes)

These nine projects were generated from our own synthetic images (grey
squares, a white disc, a test card, a grey ramp). Each lives at:

```
~/WorkDir/vibe_coding/camtasia_rea_refs/<group>/<case>/<case>.cmproj
```

For **each** case in the table:

1. Open the `.cmproj` in Camtasia.
2. Check the playhead is at the time in the table (it should open there). If
   it is not, move it there.
3. Look at the canvas and compare it with "What you should see". Note any
   difference.
4. **File ▸ Save** (⌘S). This stores Camtasia's own thumbnail render in the
   project.
5. **Export ▸ Export Frame As…** (in some versions **File ▸ Export ▸ Export
   Frame**), format **PNG**. Save it as `reference.png` in the case folder,
   next to the `.cmproj` and not inside it.
6. Close the project.

| # | Case (`<group>/<case>`) | Playhead | What you should see |
|---|---|---|---|
| A1 | `effects/ef1-dropshadow` | 1 s | Ten grey squares (one disc, one rotated 45°) with hard or soft black shadows; one shadow is red. Cells 6 and 10 may show no shadow |
| A2 | `effects/ef2-roundcorners` | 1 s | Five grey squares with rounded corners; one has a single rounded corner, one looks like a circle |
| A3 | `effects/ef3-mask` | 1 s | Ten small test cards cut to shapes (circles, rectangles); one shows the card faintly outside its circle, one has a hole |
| A4 | `effects/ef4-coloradjust` | 1 s | Nine test cards; top-left unchanged, the rest brighter, darker, flatter, harsher, grey or oversaturated |
| A5 | `effects/ef5-blendmode` | 1 s | A black→white ramp with 24 small colour swatches, each blended differently |
| A6 | `effects/ef6-motionblur` | 0.5 s | Four grey squares sliding right in the first second (top row sharp, lower rows smeared), one spinning square at the bottom |
| A7 | `effects/ef7-mediamatte` | 1 s | Twelve small test cards cut by a circle or faded by the ramp, and one card over a grey square at bottom left |
| A8 | `callouts/co1-shapes` | 1 s | Twenty blue callouts in a 4×5 grid: shapes, text, bubbles, text arrows, an arrow, then restyled rectangles and bubbles |
| A9 | `callouts/co2-tails` | 1 s | Top: three speech bubbles with tails pointing down, right and up-left. Middle: three arrows with different start caps. Bottom: four dashed or dotted rectangles |

Extra steps for three cases:

- **A5 (blend modes):** click any swatch, open **Properties**, and note the
  blend-mode **name** shown for swatches 1, 2, 13 and 24 (counting left to
  right, top to bottom; they hold modes 0, 1, 12 and 23).
- **A6 (motion blur):** besides the PNG, also export a video: **Export ▸ Local
  File…**, MP4, 1920×1080, 30 fps, highest quality. Save it as
  `reference.mp4` in the same folder.
- **A7 (media matte):** click the matte image above the first card of the top
  row and note the **Matte mode** name shown in Properties. Do the same for
  the second to fifth cards (modes 1, 2, 3, 4 and 0).

## Part B: effect parameter discovery, EF0 (about 6 minutes)

1. **File ▸ New Project** (1920×1080).
2. Import `~/WorkDir/vibe_coding/camtasia_rea_refs/_sheet-media/M-grey-400.png`.
3. Put that image on **nine tracks**, one copy per track, all at 0 s.
4. From **Visual Effects**, drag one effect onto each copy with its default
   settings: **Border**, **Reflection**, **Drop Shadow**, **Corner Rounding**,
   **Color Adjustment**, **Mask**, **Blend Mode**, **Motion Blur**, **Media
   Matte**.
5. Select the Color Adjustment copy and open Properties. Take a screenshot of
   the Properties panel (⇧⌘4, then Space, then click the window) and save it as
   `~/WorkDir/vibe_coding/camtasia_rea_refs/research/effects/ef0-coloradjust.png`.
6. **File ▸ Save As…**
   `~/WorkDir/vibe_coding/camtasia_rea_refs/research/effects/ef0-defaults.cmproj`.

EF0 gives the Border and Reflection parameter names. Their sheets (EF8, EF9)
are generated afterwards and come in the next session.

## Part C: shader backgrounds (about 6 minutes)

Save into `~/WorkDir/vibe_coding/camtasia_rea_refs/research/shaders/`.

- **SH1, time origin:**
  1. **File ▸ New Project** (1920×1080). From the backgrounds library, add
     **Cool Tones Shifting** to track 1 at 0 s.
  2. Split it at 10 s and delete the left part.
  3. Drag the remaining clip so it starts at **20 s**.
  4. Put the playhead at **25 s**.
  5. **File ▸ Save As…** `sh1-origin.cmproj`.
- **SH2, particles:**
  1. **File ▸ New Project**. Add **Star Field** (or any particle background)
     alone on track 1 at 0 s.
  2. Put the playhead at **3 s**.
  3. **File ▸ Save As…** `sh2-particles.cmproj`.
- **SH3, position parameter:** continue from SH2.
  1. Select the Star Field clip. In Properties, change its position-type
     parameter (the one with an on-canvas handle) to a clearly different
     place.
  2. **File ▸ Save As…** `sh3-position.cmproj`.

## Part D: transitions (about 12 minutes)

Save into `~/WorkDir/vibe_coding/camtasia_rea_refs/research/transitions/`.

- **TR1, window placement and one-sided fades:**
  1. **File ▸ New Project** (1920×1080, 30 fps).
  2. Put your photo on **track 1** from 0 s to the end (stretch it to about
     20 s), so transparency shows.
  3. Put your video on **track 2** at 0 s. Split it at **10 s**, so two clips
     touch at the cut.
  4. Add **Fade** between the two clips. Set its duration to **1.00 s**.
  5. Add **Fade** to the **start** of the first clip only (transition in).
  6. **File ▸ Save As…** `tr1.cmproj`.
  7. **Export ▸ Local File…**, MP4, 1920×1080, 30 fps, whole timeline:
     `tr1.mp4`.
- **TR2, classic looks:** continue from TR1.
  1. Replace the middle transition with **Fade Through Black**. Put the
     playhead at **10 s** (the middle of the transition). **File ▸ Save As…**
     `tr2-FadeThroughBlack.cmproj`.
  2. Replace it with **Radial Wipe**, playhead at 10 s. Save as
     `tr2-RadialWipe.cmproj`.
  3. Replace it with **Cube Rotate**, playhead at 10 s. Save as
     `tr2-CubeRotate.cmproj`.
- **TR3, a shader transition:** continue from TR2.
  1. Replace the middle transition with **Accordion** (Splits category).
  2. In Properties, change its **Number** parameter and set one colour to
     something obvious.
  3. **File ▸ Save As…** `tr3.cmproj`.

## Part E: behaviours (about 8 minutes)

Save into `~/WorkDir/vibe_coding/camtasia_rea_refs/research/behaviors/`.

- **BH1, phase timing:**
  1. **File ▸ New Project** (1920×1080, 30 fps). Add a plain **text callout**
     reading `ABCDE` at 0–5 s.
  2. Apply the behaviour **Fly In** with default settings.
  3. **File ▸ Save As…** `bh1-flyin.cmproj`, then export MP4 `bh1-flyin.mp4`.
  4. Replace the behaviour with **Pop Up**: save `bh1-popup.cmproj`, export
     `bh1-popup.mp4`.
  5. Replace it with **Pulsating**: save `bh1-pulsating.cmproj`, export
     `bh1-pulsating.mp4`.
- **BH2, media clip:**
  1. **File ▸ New Project**. Put your photo at 0–5 s and apply **Fly In**.
  2. Change **In ▸ Movement** to a different value and **Speed** to the
     maximum.
  3. **File ▸ Save As…** `bh2-image.cmproj`, then export `bh2-image.mp4`.

## Part F: region callouts, CO3 (about 5 minutes)

1. **File ▸ New Project** (1920×1080). Import
   `~/WorkDir/vibe_coding/camtasia_rea_refs/_sheet-media/M-card-1920x1080.png`
   and put it on track 1 at 0 s, filling the canvas.
2. From **Annotations**, drag each of these onto the canvas over the test
   card, each on its own track and spread out so they don't overlap: a
   **Blur**, a **Pixelate**, a **Highlighter**, a **Spotlight**, a
   **Keystroke** callout, and one **Sketch Motion** item.
3. Put the playhead over all of them (for example 1 s).
4. **File ▸ Save As…**
   `~/WorkDir/vibe_coding/camtasia_rea_refs/research/callouts/co3-regions.cmproj`.

## Part G: captions (about 12 minutes)

Save into `~/WorkDir/vibe_coding/camtasia_rea_refs/research/captions/`. Use
10 s of your speech video.

- **CA1, classic captions:**
  1. **File ▸ New Project**. Add the video on track 1 at 0 s.
  2. **Trim 1 s off its start** (drag the left edge right by 1 s).
  3. Add three captions by hand (**Captions ▸ Add Caption**) with different
     text and durations. Make **one word bold**.
  4. Change the caption font size once.
  5. **File ▸ Save As…** `ca1-captions.cmproj`.
- **CA2, dynamic captions:**
  1. **File ▸ New Project** with the same video at 0 s. Run **Generate
     dynamic captions** (or apply a dynamic-caption style to the transcript).
  2. Put the playhead in the middle of a sentence. **File ▸ Save As…**
     `ca2-dynamic.cmproj`.
  3. Export the first 10 s as MP4: `ca2-dynamic.mp4`.
  4. Switch to a **different** dynamic-caption style from the gallery.
     **File ▸ Save As…** `ca2-style2.cmproj`.

## Part H: screen recordings and cursor effects (about 20 minutes)

Save into `~/WorkDir/vibe_coding/camtasia_rea_refs/research/cursor/`.

> **Privacy.** Recordings store window titles and everything on screen.
> Before recording, open **TextEdit ▸ File ▸ New** and record **only that empty
> TextEdit window** (choose a region around it). Don't record mail, a browser,
> chats or anything with names or passwords.

Each recording appears in Camtasia's media bin. To save it under the name
given: right-click it ▸ **Reveal in Finder**, then copy the `.trec` file into
the folder above and rename it.

- **TM1, keystrokes:** record 10 s of the TextEdit window. While recording,
  type `abc` and press **⌘S** once (press Esc to close TextEdit's save sheet).
  Save the file as `tm1-keys.trec`.
- **TM2, clicks:** record 10 s of the same window. Move the mouse around,
  **double-click** once, then **middle-click** once if your mouse has a middle
  button. Save the file as `tm2-clicks.trec`.
- **TM3, moving window:** record the TextEdit window (window mode if offered,
  otherwise a region) and **drag the window around** while recording. Save the
  file as `tm3-window.trec`.
- **CE1, cursor effect names and defaults:**
  1. **File ▸ New Project**. Put the TM2 recording on **8 tracks**, one copy
     per track at 0 s.
  2. Apply one cursor effect per copy with default settings: **Highlight**,
     **Magnify**, **Spotlight**, **Cursor Smoothing**, **Click Rings** (left),
     **Click Ripple** (left), **Click Burst 1** (left), **Lens**.
  3. **File ▸ Save As…** `ce1-cursor.cmproj`.
- **CE2, cursor motion:**
  1. **File ▸ New Project** with one copy of the TM2 recording. Apply **Cursor
     Physics** and **Left Click Scaling**, both with defaults.
  2. Export 10 s as MP4: `ce2-motion.mp4`.
  3. Remove both effects, apply **Cursor Smoothing** only, and export
     `ce2-smooth.mp4`.
- **CE3, cursor colour and shadow sheet:**
  1. In Terminal, build the sheet from your TM2 recording (takes about a
     minute the first time):

     ```sh
     cd ~/WorkDir/vibe_coding/camtasia_rea && swift run wizrec-testgen ce3 ~/WorkDir/vibe_coding/camtasia_rea_refs/research/cursor/tm2-clicks.trec
     ```

  2. Open
     `~/WorkDir/vibe_coding/camtasia_rea_refs/research/cursor/ce3-cursor/ce3-cursor.cmproj`.
     You should see six small copies of the recording; the cursor is large in
     five of them, yellow-and-black in three, with a hard shadow in one.
  3. **File ▸ Save**, then **Export Frame As…** PNG as `reference.png` in the
     `ce3-cursor` folder.

## Part I: audio (about 10 minutes)

Save into `~/WorkDir/vibe_coding/camtasia_rea_refs/research/audio/`.

- **AU1, audio effect names and parameters:**
  1. **File ▸ New Project**. Put 15 s of your speech (the video or just its
     audio) on **8 tracks**, one copy per track at 0 s.
  2. Apply one audio effect per copy with defaults: **Noise Removal**, **AI
     Noise Removal**, **Volume Leveling** (or **Dynamics**), **Emphasize**,
     **Pitch**, **Fade In**, **Fade Out**.
  3. On the **eighth** copy set **Clip Speed** to **2×**.
  4. On the **first** copy, drag a volume point down to about **50 %**.
  5. **File ▸ Save As…** `au1-audio.cmproj`.
- **AU2, loudness normalisation** (generated test tones, not speech):
  1. Open
     `~/WorkDir/vibe_coding/camtasia_rea_refs/research/audio/au2/au2-generated.cmproj`.
     It has five 10-s noise/click clips on track 1 and one on track 2 (55 s in
     all). Turn your volume down: one part is loud.
  2. If Camtasia offers to analyse or normalise audio, accept its defaults.
  3. **File ▸ Save As…** `au2.cmproj` in the same `au2` folder.
  4. **Export ▸ Audio Only** (M4A), whole timeline: `au2.m4a` in the same
     folder.
  5. Note whether the project's loudness normalisation setting was on.

## Part J: edit behaviour checks (about 10 minutes)

One new project, saved after each step, as in session 1's X7. Each step
continues from the previous save, so don't reopen earlier files. Save into
`~/WorkDir/vibe_coding/camtasia_rea_refs/research/timeline/`, and park the
playhead at **0 s** before each save.

- **ED0, insert defaults:**
  1. **File ▸ New Project** (1920×1080, 30 fps). Import your photo and your
     video.
  2. Drag the **photo** onto track 1 at 0 s. Don't change its length.
  3. Drag the **video** onto track 2 at 0 s. Don't change it.
  4. Save as `ed0-insert.cmproj`.
- **ED1, Extend Frame:**
  1. Put the playhead at **5 s** over the video on track 2.
  2. Right-click the video ▸ **Extend Frame…** and extend by **2 s**.
  3. Save as `ed1-extend.cmproj`.
- **ED2, clip speed:**
  1. Select the video clip on track 2 (the part before the extended frame).
  2. Add **Clip Speed** and set it to **1.5×**.
  3. Save as `ed2-speed.cmproj`.
- **ED3, magnetic track:**
  1. On a new track 3, turn on **Magnetic** (the magnet in the track header).
  2. Drag the photo onto track 3 at about **3 s**. Note where it lands.
  3. Drag the video onto track 3 at about **20 s**. Note where it lands.
  4. Drag a second copy of the photo onto track 3, dropping it on the
     **boundary between** the first photo and the video.
  5. Save as `ed3-magnetic.cmproj`.
- **ED4, ripple trim of a start edge:**
  1. On a new track 4, put the video at 0 s and the photo right after it, so
     they touch.
  2. Hold **Shift** and drag the **left edge** of the video right by **2 s**
     (a ripple trim).
  3. Note whether the video's start stayed at 0 s and the photo moved left.
  4. Save as `ed4-ripple.cmproj`.

## Part K: report back

Tell the lead "session 2 done" and paste:

1. Any warning or conversion prompt when opening or saving, and for which file.
2. **Part A:** for each case, "as described" or what differed. The blend-mode
   names for swatches 1, 2, 13 and 24 (A5), and the matte-mode names for modes
   1, 2, 3, 4 and 0 (A7).
3. **Part B:** anything odd about the effects' defaults (for example, an effect
   that did nothing on a plain grey square).
4. **Parts C–G:** steps you could not do as written, and what you did instead
   (for example, a renamed menu item or a missing effect).
5. **Part H:** whether the middle-click and window recording were possible.
6. **Part I:** whether loudness normalisation was on, and whether any AU1
   effect was missing.
7. **Part J:** where the photo and video landed on the magnetic track (ED3),
   and what the ripple trim did (ED4).

Then the golden tests run with:

```sh
REFS_DIR=~/WorkDir/vibe_coding/camtasia_rea_refs swift test --filter "GoldenTests"
```
