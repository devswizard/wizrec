# Spec: captions (classic captions, dynamic captions, transcription)

Where Camtasia stores caption style, transcribed words and dynamic-caption
styling, and what can be inferred about how they render.

Tags: **[obs]** observed in files, **[inf]** inferred, **[?]** unknown.

## Evidence base

- **CP1: the seven `DynamicCaptionPreviewBaseProject_<lang>.tscproj`
  samples** (bundle, read in place; format 10.0, Camtasia 2026.0.6, canvas
  1920×1024). Each holds:
  - a shader background;
  - an `AMFile` of a silent audio file, whose source carries a word
    transcription;
  - one dynamic-caption `Callout`.

  The seven `def`s are identical; only the words and durations differ [obs].
  Languages: de-DE, en-US, es-ES, fr-FR, ja-JP, pt-BR, zh-CN.
- **CP2: `timeline.captionAttributes` in all 24 projects** [obs].
- CP3: the user's vlog has one audio clip with a `captions` parameter (classic captions, empty texts) [obs].

## 1. Classic caption style: `timeline.captionAttributes`

[obs, 24 / 24 projects]:

| Key | Values seen | Meaning |
|---|---|---|
| `enabled` | true | Captions are shown [inf] |
| `fontName` | "Arial" | Caption font |
| `fontSize` | 32 (17 projects), 60 (7) | Size in px at canvas resolution [inf] |
| `defaultFontSize` | true | The size is automatic, so `fontSize` is a stored default [inf] |
| `foregroundColor` | `[255, 255, 255, 255]` | Text RGBA, 0–255 |
| `backgroundColor` | `[0, 0, 0, 204]` (17), `[0, 0, 0, 191]` (7) | Box RGBA, 0–255 |
| `opacity` | 0.5 | [?] It does not match the box alpha (204/255 = 0.8); maybe a legacy or UI value |
| `backgroundEnabled` | true | Draw the box |
| `backgroundOnlyAroundText` | true | The box hugs each line of text instead of spanning the full width [inf] |
| `alignment` | 0 | Text alignment enum: 0 = centre [inf] |
| `lang` | "en" (23), "bn" (1, the user's vlog) | Caption language (ISO 639-1) |

### Classic caption text: `parameters.captions` on an audio clip

There is **one instance**, in the user's vlog [obs]: `AMFile` 234, at
timeline 0–25.7 s with `mediaStart` 1.117 s. Only the structure is recorded
here, as the content is personal.

```
"parameters": {
  "captions": {
    "type": "caption",
    "keyframes": [
      { "time": t, "endTime": t, "duration": 0,
        "value": { "text": "<caption text>", "textAttributes": null | <run list> } },
      …
    ]
  }
}
```

| Claim | Tag |
|---|---|
| Captions are a parameter of the **audio clip** they belong to, with one keyframe per caption | [obs] |
| A caption runs from its `time` to the next keyframe's `time`. The vlog has 7 keyframes at 0, 4, 8, …, 24 s: Camtasia's default 4-s segments, all with empty text | [obs] |
| `value.text` is plain text. `value.textAttributes` is null here; when present it uses the run format of `callouts.md` §5 | [obs null; inf format] |
| Time axis: **media time** of the audio clip, like every keyframed clip parameter (`mediaStart + (t − start) / scalar`). The vlog's segments were made before its trim | [obs, CA1 2026-10-20: on a clip trimmed to `mediaStart` 1 s, *Add Captions* wrote keyframes at 1, 5, 9 and 13 s. After the clip was moved to timeline 4 s they stayed at 1, 5, 9 and 13] |
| `captionAttributes` (above) styles every classic caption | [inf] |

**CA1 results (runtime saves, 2026-10-20)** [obs]:

- *Modify ▸ Closed Captions ▸ Add Captions* on a selected audio clip writes
  one empty caption (`text` "", `textAttributes` null) every **4 s of media
  time, starting at the clip's `mediaStart`** and running to the end of the
  media window: 0, 4, 8 and 12 s on an untrimmed 13.2 s clip; 1, 5, 9 and
  13 s after a 1 s left trim. The last segment can be very short (13.0 to
  13.17 s).
- `timeline.captionAttributes` is unchanged by adding captions.
- Split, ripple delete and move keep every caption keyframe on each piece.
  None are pruned or shifted, so a piece can carry captions outside its
  media window (`edit-semantics.md` X7 #4 has the same rule).
- Typing caption text, bold runs and font-size changes were done in
  session 8 (below).

**CA1 caption text (runtime saves, session 8, 2026-10-21, RT-023)**

Saves are under `camtasia_rea_refs/research/captions/ca11/`. Base: a copy
of `ca1-captions` (four empty 4 s captions on a 13.17 s audio clip).

| Claim | Evidence | Tag |
|---|---|---|
| **The caption editor.** Clicking a caption in the caption lane above the timeline ruler opens a "Caption Editor" over the canvas. It has a text area ("Caption Text"), a *Duration* slider and field, *Previous/Next Caption*, *Play Caption*, and a style button | — | [obs] |
| **The style button** opens one global sheet: Font, Size, Text colour, Background colour and Opacity. It writes `timeline.captionAttributes`; Size 32 → 40 gave `fontSize` 40 (`defaultFontSize` stayed true) | `ca11-captions` | [obs] |
| **No bold or other per-word styling.** *Text ▸ Bold/Italic/Underline* are disabled while the text area is being edited. Cmd-B closes the editor and changes nothing. `textAttributes` stays null on every caption | `ca11-try2`, `ca11-captions` | [obs] |
| **Text typed in the editor is saved as RTF** in `value.text`: a Cocoa RTF document (`{\rtf1\ansi\ansicpg1252\cocoartf2907 … \f0\fs36 \cf2 one bold word}`, font ArialMT, 18 pt, colour 54/66/74). This happens even for plain words. The RTF style is the editor's display style, not the caption style: it stays at `\fs36` after `fontSize` changes to 40 | `ca11-try1`, `ca11-captions` | [obs] |
| **Plain text is accepted.** A caption whose `text` is a bare string (written by hand into a copy) shows in the editor, and an untouched caption is saved back as the same bare string | `ca11-plain-in` → `ca11-plain-saved` | [obs] |
| Rendering uses `captionAttributes`, not the RTF's font, size or colour | [inf: the RTF style never changes and matches the editor's look] | [inf] |

Rules for WizRec:

- **Readers.** When `value.text` starts with `{\rtf`, convert it to plain
  text (for example with `NSAttributedString` RTF import) and ignore its
  attributes. Otherwise use it as is [inf]. `textAttributes` may still be
  honoured if present, but Camtasia 2026.2.3 never writes it for classic
  captions [obs].
- **Writers.** Plain strings are fine, because Camtasia reads them and keeps
  them [obs]. WizRec doesn't need to write RTF.
- **[WizRec] ClassicCaptions differs.** It treats `text` as plain text and
  would show RTF source to the user. That is a reader gap to fix.
- **Bold runs** are not a Camtasia classic-caption feature. Drop that test
  expectation.

## 2. Transcription (the words)

The words are stored **on the source, not on a clip** [obs, CP1]:

```
sourceBin[i].sourceTracks[j] = {
  …, "type": 2 (audio),
  "transcriptionSet": true,
  "parameters": {
    "transcription": {
      "type": "string",
      "keyframes": [ { "time": t, "endTime": t, "duration": 0, "value": "<word>" }, … ]
    }
  }
}
```

| Claim | Tag |
|---|---|
| One keyframe per word. `value` is the word including punctuation ("dog."), `time` is when the word starts, and `endTime = time` with `duration` 0 | [obs] all 7 files |
| `time` is in **project ticks** (`editRate`, 705600000/s) on the **source's** time axis: media time, not timeline time. en-US: "The" at 0, "Quick" at 0.1667 s, …, with a final empty marker at 3.233 s | [obs values; inf axis: the times are attached to the source track] |
| A keyframe with `value: ""` closes the previous word (en-US's last keyframe). The other six files end with a real word, so the last word lasts until the clip ends | [obs] |
| Word segmentation follows the language: ja-JP has 10 tokens and zh-CN 4 for whole sentences | [obs] |
| `transcriptionSet: true` flags that transcription exists, even when it is empty [inf] |
| To find the words on screen at timeline time t for an audio clip: `m = mediaTime(clip, t)`, then take the last keyframe with `time ≤ m` | [inf] |

**Correction to `FORMAT.md`:** transcription is a source-track parameter,
not a clip parameter (fixed in the same commit).

## 3. Dynamic captions: the callout

A dynamic caption is a `Callout` with [obs, CP1]:

- `def.kind` = `"remix"`, `shape` = `"text"`, `style` = `"caption"`;
- `modifier` = `"dynamicCaption"`;
- `dynamic-caption-style` = `"block"`;
- a placeholder `def.text` ("ABC");
- in CP1 the clip spans the whole audio clip, with `mediaStart` 164640000
  (0.2333 s). Camtasia's own default differs: see "CA2 results" below.

**Linking.** No key links the callout to the audio clip or source [obs]. The
callout shows the transcription of the audio playing at the same timeline
time [inf]. With several audio clips, which one it uses is [?]. Experiment
CA2.

### Style keys

All values are doubles unless noted; colours are 0–1. Values are from CP1;
the meanings are [inf] from the key names.

| Key | CP1 | Meaning |
|---|---|---|
| `dynamic-caption-style` (string) | "block" | Layout style: a block of lines. Other styles [?] |
| `dynamic-caption-block-transition-name` (string) | "" | Transition between blocks (none) |
| `dynamic-caption-block-transition-duration` | 0.5 | Seconds |
| `dynamic-caption-block-transition-reverse` | 0 | Flag |
| `dynamic-caption-new-paragraph-for-each-sentence` | 0 | Start a new block at each sentence end |
| `dynamic-caption-past-word-opacity` | 1.0 | Opacity of words already spoken |
| `dynamic-caption-future-word-opacity` | 1.0 | Opacity of words not yet spoken |
| `dynamic-caption-current-word-enabled` | 1.0 | Highlight the current word |
| `dynamic-caption-current-word-color-red/-green/-blue/-alpha` | 1, 1, 1, 1 | Current word fill |
| `dynamic-caption-current-word-stroke-color-*` | (1, 0, 0, 1) | Current word outline |
| `dynamic-caption-current-word-stroke-extra-width` | 18.0 | Extra outline width for the current word, px |
| `dynamic-caption-current-word-extra-scale` | 0.0 | Extra scale of the current word (0 = none) |
| `dynamic-caption-current-word-glow-radius` | 0.0 | Glow radius, px |
| `dynamic-caption-word-easing-duration` | 0.0 | Seconds to ease the highlight between words |
| `dynamic-caption-word-rectangle-color-*` | (0, 0.4, 0.98, **0**) | Box behind the current word. Alpha 0 = off |
| `dynamic-caption-word-rectangle-corner-radius` | 20.0 | px |
| `dynamic-caption-word-rectangle-extra-size` | 0.125 | Padding as a fraction of the font size |
| `dynamic-caption-word-rectangle-transition-time` | 0.1 | Seconds for the box to move to the next word |
| `dynamic-caption-background-fill-color-*` | (0, 0, 0, **0**) | Box behind the whole block. Alpha 0 = off |
| `dynamic-caption-background-corner-radius` | 19.2 | px |
| `text-stroke-width`, `text-stroke-color-*`, `text-stroke-alignment` | 3.84; black; 2 | Glyph outline for all words (`callouts.md`) |
| `corner-radius` | 6.0 | |
| `font` | Bebas Neue, `size` 96 | Base font |
| `textAttributes` | `fontSize` 261, weight 700 | The fitted size (`resize-behavior: resizeText`) |
| `width`, `height` | 1804.3 × 387.4 | Caption box in callout px. With `scale0/1` 0.9577 it is 1728 × 371 canvas px |

Every style key is a plain constant inside `def`. None is animatable [obs].

### CA2 results: what Camtasia 2026.2.3 writes (runtime saves, 2026-10-20)

Setup: a WizRec-generated project with a 13.2 s synthetic speech WAV
(`AMFile`, track 1) and a 10 s video (track 2). The automation chose
*Modify ▸ Add Dynamic Caption Style ▸ "Arial 2 Line Dark Background"* with
the playhead at 1 s, then *"Bangers Single Line"* at 4 s. Saves only; no
export was made (trial gate).

**Transcription is created on the source** [obs]. Applying a style ran
speech recognition and added `transcriptionSet: true` and
`parameters.transcription` to the WAV's source track, in the §2 format.

- Times are in project ticks on the source's media axis and are not
  frame-rounded (for example 2776800600).
- The recognised text had 21 word tokens. Any token can contain a sentence
  break with no space ("timing.The"), so a reader must not assume that one
  token is one word [obs].
- The list ends with a keyframe whose `value` is **`%GAP`** at 7.101 s,
  where speech stops. `%GAP` is a reserved marker meaning "no word from here
  on". It is never displayed [inf]. This is the second end-marker form,
  alongside the empty string of CP1. WizRec must treat both as "nothing is
  spoken".
- The words were identical in both saves. Applying a second style did not
  transcribe again [obs].

**The callout** [obs]:

| Property | Value |
|---|---|
| Placement on the timeline | A **new track** above the others. `start` = the playhead (1 s, then 4 s), `duration` **60 s**, whatever the audio's length (13.2 s). `mediaStart` 0, `mediaDuration` 60 s |
| A second style | Applying another style with the first callout unselected **adds a second callout** on a new track. It does not restyle the first one |
| `parameters` | Only `translation1` (vertical position) and the four `geometryCrop*` (0). No scale is written (default-scale "1") |
| Vertical position | `translation1` −396 for the 2-line preset (box `height` 288) and −457 for the single-line preset (`height` 150). Both sit in the lower part of the canvas; the exact rule is [?] |
| Box | `width` 1280 for both presets; `height` 288 (2 lines) or 150 (1 line). The box height carries the line count [inf] |
| `resize-behavior` | `"resizeCallout"` (CP1 had `"resizeText"`) |

So CP1's "spans the whole audio clip" and its `mediaStart` 0.2333 s came
from the way those sample projects were built. Camtasia's own default is
60 s from the playhead with `mediaStart` 0 [obs].

**`def` keys new since CP1** [obs]:

| Key | Arial 2 Line Dark Background | Bangers Single Line | Meaning |
|---|---|---|---|
| `dynamic-caption-display-name` | "Arial 2 Line Dark Background" | "Bangers Single Line" | Gallery name of the preset |
| `dynamic-caption-preset-ID` | "blockPreset8" | "blockPreset1" | Preset identifier |
| `enable-ligatures` | 1.0 | 1.0 | Font ligatures on |
| `hasDropShadow` | 0.0 | absent | Text shadow flag |
| `word-wrap` | 1.0 | 1.0 | Wrap lines inside the box |
| `tracking`, `line-spacing` | 0.0, 0.0 | 0.0, 0.0 | Letter and line spacing |
| `horizontal-alignment`, `vertical-alignment` | "center", "center" | same | Text alignment in the box |

**Preset values that differ** [obs]:

| Key | Arial 2 Line Dark Bg | Bangers Single Line |
|---|---|---|
| text font (`textAttributes` `fontName`, `fontSize`, `fontWeight`, `kerning`) | Arial, 96, 400, −0.02 | Bangers, 96, 400, 0.0 |
| `font` (name / size / weight) | Bebas Neue / 128 / Regular | Bebas Neue / 128 / Regular |
| `dynamic-caption-background-fill-color` (alpha) | black, **0.6** | black, 0.0 |
| `dynamic-caption-background-corner-radius` | 24.0 | 25.6 |
| `dynamic-caption-current-word-enabled` | 0 | 0 |
| `dynamic-caption-future-word-opacity` | **0.0** (words appear as they are spoken) | 1.0 |
| `dynamic-caption-word-rectangle-color` | white, alpha 0 | (0, 0.333, 0.98), alpha **1** |
| `dynamic-caption-current-word-stroke-color` alpha | 0 | 1 |
| `text-stroke-width` / stroke alpha | 0.0 / 0.4 | 8.0 / 1.0 (black) |
| `dynamic-caption-word-rectangle-corner-radius` | 6.0 | 6.0 (CP1: 20.0) |

- **The font comes from `textAttributes`.** `def.font` stayed "Bebas Neue
  128" in both presets, while the visible font of each preset (Arial,
  Bangers) appears only in the `textAttributes` runs. `def.font` is a
  leftover default, and the runs decide the font, size and colour [inf,
  strong].
- The word rectangle is drawn behind the **current** word. It is visible in
  the Bangers preset even though `current-word-enabled` is 0. So the
  rectangle does not depend on `current-word-enabled`, which controls only
  the current word's own colour, stroke, scale and glow [inf].

Still open, since they need an export: block breaking, the fitted text size,
and the exact vertical placement rule [?].

## 4. Rendering model (provisional)

1. Take the words of the current block. A block is filled greedily: as many
   words as fit in the box at the fitted size, wrapping lines
   [inf; block-size rule [?]].
2. Draw past words at `past-word-opacity` and future words at
   `future-word-opacity`.
3. Draw the current word in the current-word colour, with its stroke, glow
   and scale, over the word rectangle when its alpha is above 0.
4. When the playhead passes the block's last word, switch to the next block
   using the block transition.

Block breaking, line count and the fitted size are [?] until CA2.

### WizRec rules used until CA2

Tag **[WizRec]** marks a rule WizRec chose because Camtasia's is unknown.
Each is replaceable once CA2 answers it.

| Rule | Tag | Code |
|---|---|---|
| **Pairing.** A dynamic-caption callout reads the transcribed audio clips (`AMFile`, or a `UnifiedMedia`'s `audio` half, whose source track has `parameters.transcription`) on the **same track list** as the callout and overlapping it. Audio inside groups or stitched clips is not considered | [inf] no linking key [obs]; scope [WizRec] | `SceneBuilder.pairDynamicCaptions` |
| **Several audio clips.** At time t the first paired clip playing at t wins, bottom track first | [WizRec] | `SDynamicCaption.frame(at:)` |
| **Word time.** t → the audio clip's media time (`mediaStart + (t − start) / scalar`, time-mapping.md), then the last word with `time ≤ m` | [inf] (§2) | same |
| **Blocks.** Greedy: chars per line = box `width` / (0.55 × `font.size`), clamped 8–60; 2 lines; new block after a ≥ 1.5 s pause, after 6 s, or at a sentence end when `new-paragraph-for-each-sentence`; a block stays 1 s after its last word | [WizRec] | `CaptionBlockRules` (CaptionLayout) |
| **Size.** Base `font.size`, shrunk until the block fits the box; the `textAttributes` `fontSize` (fitted to the placeholder `def.text`) is ignored, its font/weight/colour kept | [WizRec] | `DynamicCaptionText.fit` |
| **Block transition.** Any non-empty `block-transition-name` fades the block in over `block-transition-duration` | [WizRec] | `DynamicCaptionText.draw` |
| **Easing.** Over `word-easing-duration` the current word's colour, outline and scale ease in while the previous word's ease out; the word box slides over `word-rectangle-transition-time` | [inf] from key names | same |
| **New callout.** 60 s from the playhead on a new top track, `mediaStart` 0, preset `def` keys as in "CA2 results"; a second style adds a second callout. Box size and `translation1` scale with canvas height / 1080 | [obs CA2]; scaling [WizRec] | `AddDynamicCaption`, `DynamicCaptionPreset` |
| **Base size for blocks.** Run `fontSize` when `resize-behavior` is `resizeCallout`, else `font.size` | [inf, CA2] | `CaptionBlockRules.baseFontSize` |
| **Export to SRT/VTT.** One cue per block of every paired audio clip | [WizRec] | `DynamicCaptions.cues` |

## 5. Experiments

Save into `~/WorkDir/vibe_coding/camtasia_rea_refs/research/captions/`.

- **CA1: classic captions.**
  1. New project. Add any 10-s video with speech.
  2. Trim 1 s off its start.
  3. Add three captions by hand (*Captions ▸ Add Caption*), with different
     text and durations. (Done in session 8; a bold word isn't possible,
     because classic captions have no per-word styling: §1.)
  4. Change the caption font size once.
  5. Save as `ca1-captions.cmproj`.
- **CA2: dynamic captions.**
  1. Same video. Run *Generate dynamic captions* (or apply a
     dynamic-caption style to the transcript).
  2. Save as `ca2-dynamic.cmproj` with the playhead mid-sentence.
  3. Export `ca2-dynamic.mp4` (only the first 10 s are needed).
  4. Switch to a different dynamic-caption style from the gallery and save
     as `ca2-style2.cmproj`.
