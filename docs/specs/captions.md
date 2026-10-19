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
| Time axis: the keyframes start at 0 while the clip's `mediaStart` is 1.117 s, so the axis is **clip-local** (or the segments were made before a trim) | [?] Experiment CA1, which adds a left trim |
| `captionAttributes` (above) styles every classic caption | [inf] |

Experiment CA1 confirms the time axis and the non-empty form.

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
- the clip spans the whole audio clip (0 to the audio duration);
- `mediaStart` = 164640000 (0.2333 s) in every sample. Its meaning is [?].

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

## 5. Experiments

Save into `~/WorkDir/vibe_coding/camtasia_rea_refs/research/captions/`.

- **CA1: classic captions.**
  1. New project. Add any 10-s video with speech.
  2. Trim 1 s off its start.
  3. Add three captions by hand (*Captions ▸ Add Caption*), with different
     text and durations, and make one word bold.
  4. Change the caption font size once.
  5. Save as `ca1-captions.cmproj`.
- **CA2: dynamic captions.**
  1. Same video. Run *Generate dynamic captions* (or apply a
     dynamic-caption style to the transcript).
  2. Save as `ca2-dynamic.cmproj` with the playhead mid-sentence.
  3. Export `ca2-dynamic.mp4` (only the first 10 s are needed).
  4. Switch to a different dynamic-caption style from the gallery and save
     as `ca2-style2.cmproj`.
