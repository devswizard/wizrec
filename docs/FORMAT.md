# Camtasia project format (`.cmproj` / `.tscproj`)

Clean-room notes from reading project files that Camtasia writes. These were
derived from 25 projects: the user's own projects, plus the sample projects
inside a local Camtasia 2026.2.3 install. Together they span format versions
2.0 through 10.0 and include files written by both Mac and Windows Camtasia.
TechSmith's files are read in place and are not copied into this repo.

Each claim is tagged with how it is known:

- **[obs]** seen directly in the sample files
- **[inf]** an inference from the samples, not yet confirmed against Camtasia
- **[?]** still unknown

## Container

A macOS project is a folder named `*.cmproj` [obs]:

| Path | Contents |
|---|---|
| `project.tscproj` | The timeline, stored as UTF-8 JSON (described below). |
| `~project.tscproj` | A 0-byte marker that Camtasia keeps while the project is open [inf]. |
| `docPrefs` | XML plist holding editor UI state: which panels are open, splitter positions, scroll. |
| `bookmarks.plist` | Plist of security-scoped bookmarks to linked media outside the bundle [inf]. |
| `media/<unix-ts>/<file>` | Imported media. |
| `recordings/<unix-ts>/<file>.trec` | Screen recordings. |
| `audiate/` | Data that links the project to Audiate. |

On Windows, and for exported projects, the project can also be a bare
`.tscproj` file. In that case `src` paths resolve relative to the folder that
holds the file [inf].

## JSON conventions

- All files are UTF-8 with no BOM, and non-ASCII text is written raw (not
  escaped) [obs].
- Doubles use 15 significant digits and always keep a fractional part, for
  example `1920.0`, `0.714285714285714` and `-1.79769313486232e+308` [obs].
- Whitespace differs between writer versions, and even between fields from the
  same writer: `[0, 0, 2688, 1512]` sits next to `[ 0, 0, 0, 204]` [obs].
  Readers must ignore whitespace.
- **Rule for writers:** keep the original key order, the exact text of each
  number, and every key you don't recognise. `TSCProjKit` does this, and all
  25 samples round-trip with no structural change.

## Time

- **Ticks.** Every time value is an integer count of ticks. The top-level
  `editRate` says how many ticks make one second [obs].
  - Projects from format 4.0 onward mostly use `705600000`. This number divides
    evenly by 23.976, 24, 25, 29.97, 30, 50, 59.94 and 60 fps, and by 44.1 and
    48 kHz, so every frame and audio sample boundary falls on a whole tick.
  - Older projects use `30`, so one tick is one frame [obs].
  - Never hard-code either value; always read `editRate`.
- **`start` / `duration`.** A clip's position and length on its parent track,
  in ticks [obs].
- **`mediaStart` / `mediaDuration`.** The part of the source media the clip
  uses, also in project ticks. These are usually integers. After a speed
  change they can be floats or exact rational strings such as
  `"13771788800000/113"` [obs].
- **`scalar`.** Media-to-timeline factor, where
  `mediaDuration × scalar = duration`, i.e. `scalar = 1 / speed`: a clip
  played at 2× has scalar `1/2`. It is `1` at normal speed, or a rational
  string such as `"304/457"` (≈1.5× speed) [obs: both non-unit scalars in the
  user's vlog satisfy this exactly; the reverse relation holds for neither].
- **Keyframes.** Keyframe times are on the clip's media-time axis (the same
  axis as `mediaStart`), not relative to the clip's start: after a left trim
  of 22 frames, keyframes run to `mediaStart + duration` [obs]. With speed
  ≠ 1 the exact base is [?]. See `docs/specs/time-mapping.md`.
- **Frame alignment.** With `allowSubFrameEditing: false`, every `start`,
  `duration`, `mediaStart` and `mediaDuration` is a whole number of output
  frames, except the `mediaDuration` of a sped-up clip [obs].

## Top level

```
title, description, author
version                "2.0" … "10.0"
editRate               ticks per second
width, height          canvas size in px (doubles)
videoFormatFrameRate   export fps (absent in format ≤ 3.0)
audioFormatSampleRate
targetLoudness, shouldApplyLoudnessNormalization
allowSubFrameEditing
authoringClientName    {name, platform: Mac|Windows, version}
sourceBin[]            media files
timeline               {id, sceneTrack, trackAttributes[], parameters,
                        captionAttributes, gain, backgroundColor[RGBA 0–255], metadata}
metadata               ProjectThumbnail (base64 PNG), ruler guides, theme id, …
```

## sourceBin[]

```
id, src ("./media/<ts>/file.mp4"), rect [x, y, w, h], lastMod, loudnessNormalization
sourceTracks[]: {
  type          0 = video, 1 = still image (png, pdf), 2 = audio [obs]
  editRate      unit of `range` only (30 … 240000); never a frame rate
  range         [0, n]: playable length after edit lists and AAC priming,
                n / editRate seconds [obs]
  sampleRate    approximate average fps for video (e.g. "2997/50"); Hz for audio
                (display only, never for timing)
  trackRect, numChannels, bitDepth, integratedLUFS, peakLevel, metaData
}
```

## Timeline

The structure is
`timeline.sceneTrack.scenes[0].csml.tracks[]`. Every sample has exactly one
scene [obs].

Each entry in `tracks[]` looks like this:

```
{trackIndex, medias[], transitions[]?, parameters}
```

- Index 0 is the bottom of the visual stack [obs: demo thumbnail].
- The UI state for each track sits in a separate list,
  `timeline.trackAttributes[]`, in the same order as the tracks. It holds
  `ident`, `audioMuted`, `videoHidden`, `magnetic`, `matte`, `solo`
  and `metadata`. Tracks inside a group carry these flags inline on the
  track object instead [obs].

### Clip types (`_type`)

| `_type` | Meaning | Extra keys |
|---|---|---|
| `VMFile` | Video stream of a source file | `src`, `trackNumber` (index into the source's `sourceTracks`, which lists only audio/video tracks) |
| `ScreenVMFile` | Video stream of a `.trec` recording, with cursor data | `src`, `trackNumber`, cursor params |
| `AMFile` | Audio stream | `src`, `trackNumber`, `channelNumber` ("0,1"), `attributes.gain/mixToMono/loudnessNormalization` |
| `IMFile` | Still image | `src`, `trimStartSum` |
| `UnifiedMedia` | A video+audio pair from one file, edited as a single clip | `video`, `audio` (each a full clip with the parent's own `start`, not offset from it) |
| `StitchedMedia` | Cut segments of one source, joined back together | `medias[]` (segments end to end from 0 on the stitched clip's inner timeline), `minMediaStart` |
| `Group` | Nested timeline | `tracks[]` (same shape as top-level tracks) |
| `Callout` | Annotation: shape, text, arrow… | `def` |

Every clip has these keys:
`id, _type, start, duration, mediaStart, mediaDuration, scalar, parameters, effects[], attributes, metadata, animationTracks`.

`id` values are unique across the whole document, nested clips included.
A new clip must use an id above the current maximum [inf].

### Parameters

Each entry in `parameters` comes in one of two shapes [obs]:

- **Constant:** a bare number, e.g. `"translation0": 172.7`.
- **Animatable:** an object,
  `{"type": "double", "defaultValue": v, "interp": "eioe"|"linr", "uiHints"?, "keyframes"?}`.
  Older files (format ≤ 4.0) omit `interp`.

Each keyframe is `{time, endTime, duration, value, interp?}`. The parameter
moves from the previous value to `value` between `time` and `endTime`, where
`endTime = time + duration` [obs + inf]. The first keyframe starts from
`defaultValue` [inf, strong]; the last value holds afterwards [inf].

`interp` takes three values [obs]:

- `linr`: linear.
- `eioe`: ease in and out. TSCProjKit approximates it with smoothstep; the
  exact curve Camtasia uses is unknown [?].
- `bnce`: bounce (MotionBlurPreview sample); curve unknown [?].

Clip transform keys [obs]:

| Key | Meaning |
|---|---|
| `translation0/1/2` | Offset of the layer centre from the canvas centre, canvas px, **+y up** [obs] |
| `scale0/1` | Multiplies the layer's natural size (`sourceTracks[trackNumber].trackRect`); missing = 1 [inf]; `metadata.default-scale` = min(1, fit) at import, metadata only |
| `rotation2` | Z rotation in radians [obs]; sign and pivot [inf] |
| `geometryCrop0..3` | Crop fractions; 0/2 are the x-edges [obs], top/bottom order [?]; no non-zero crop in any sample |
| `sourceCrop0..3` | Crop applied in source space (images, callouts, screen recordings) [?] |
| `opacity`, `volume` | Opacity and audio volume |
| `cursorScale`, `cursorOpacity`, `cursorTrackLevel`, `smoothCursorAcrossEditDuration` | Screen-recording cursor settings |

### animationTracks

`animationTracks.visual[]` holds entries of the form
`{endTime, duration, range: [start, len], interp?}` [obs].

They are the animation segments ("visual animations" in the UI): every
keyframe window `(time, endTime)` on the clip's parameters and its effects'
parameters equals one entry's `(range[0], range[0] + range[1])` (118 / 118)
[obs]. A renderer can evaluate the keyframes alone [inf].

### Effects

Each entry in `effects[]` looks like this:

```
{effectName, bypassed, category, parameters, metadata, start?, duration?}
```

`effectName` values seen so far:

- **Visual:** `RoundCorners`, `DropShadow`, `Mask`, `MotionBlur`,
  `ColorAdjustment`, `BlendModeEffect`, `MediaMatte`.
- **Cursor:** `CursorPath`, `CursorColor`, `CursorShadow`, `CursorMotionBlur`,
  `CursorPhysics`, `LeftClickScaling`.
- **Animated shader backgrounds:** `SourceEffect`.
- **Audio:** `VSTEffect-<name>`, e.g. `VSTEffect-DFN3NoiseRemoval`.
- **Behaviours:** `GenericBehaviorEffect` (with `in`, `center` and `out`
  phases).
- **Placeholders:** `dummy`, which carries only `start` and `duration`.

The parameter names for each effect are listed by the survey script.

### Transitions

Each entry in `track.transitions[]` looks like this [obs, one sample]:

```
{name: "RadialWipe", duration, trivial, reverse, bypass,
 useAudioPreRoll, useVisualPreRoll, leftMedia?, rightMedia?}
```

`leftMedia` and `rightMedia` hold clip ids. When only one side is present, the
transition is a fade in or fade out at a clip edge [inf]. For the catalog,
timing and shader-transition inputs, see `docs/specs/transitions.md`.

### Markers

Timeline markers are stored as `timeline.parameters.toc`, a string
parameter with one keyframe per marker: `{time, endTime: time, duration: 0,
value: name}` [obs: two bundle samples]. Clip markers are [?]. See
`docs/specs/markers.md`.

### Callouts (`def`)

```
kind ("remix"), shape ("speech-bubble2", "shape-rectangle", …), style,
width, height, tail-x, tail-y, word-wrap,
fill-color-{red,green,blue,opacity} (0–1), stroke-color-*, stroke-width, fill-style, stroke-style,
horizontal-alignment, vertical-alignment, text,
font {name, size, weight, tracking, color-*},
textAttributes {type: "textAttributeList", keyframes[]}
```

Rich text can also be stored as RTF, in `metadata.default-text`. For the
`kind`/`shape` catalog and text runs, see `docs/specs/callouts.md`.

### Captions

- Caption style lives in `timeline.captionAttributes`: font, colours, `lang`
  and opacity [obs].
- Transcribed words are stored on the **source**, not on a clip:
  `sourceBin[i].sourceTracks[j].parameters.transcription = {type: "string",
  keyframes[]}`, plus `transcriptionSet: true`. Each keyframe holds one word,
  and its `time` (project ticks, on the source's media axis) is when that word
  starts [obs: seven samples]. Corrected 2026-10-19: this was earlier
  described as a clip parameter.
- A dynamic caption is a `Callout` with `modifier: "dynamicCaption"` and
  `style: "caption"`. Its many `dynamic-caption-*` style keys control how the
  captions look [obs]. See `docs/specs/captions.md`.

## Media files

- **`.trec`** is a QuickTime/MP4 container [obs, via ffprobe]. Its streams are:
  - `tscc2`: TechSmith's screen codec, at a variable frame rate.
    FFmpeg's libavcodec includes a `tscc2` decoder.
  - `h264`: the webcam video.
  - `aac`: the audio.

  - A `.trec` has no fourth track. Two TechSmith atoms follow `moov`:
    `TSCR` (recorder name/version/OS) and `TSCM` (`DATA` records: recording
    environment, captured window/app names, cursor positions, cursor images, clicks)
    [obs]; layout in `docs/specs/trec.md`. `TSCM` holds private desktop data: never log or vendor it.
  - tscc2 is untagged; it decodes correctly as limited-range BT.601 [obs,
    against Camtasia's thumbnail]. 1-byte tscc2 packets mean "no change"
    and decode to no picture [obs].
  - See `docs/specs/media-streams.md`.
- **`.tscshadervid`** is JSON of the form
  `{name, version, width, height, effectDef, code, vertexCode?, numVertices?,
  blend?, signature, copyright}`. `code` is a GLSL fragment shader, and its
  uniforms `_<name>` match the `effectDef` entries and the clip's
  `sourceEffect` parameters [obs]. `_Time` is in seconds [obs]. See
  `docs/specs/shader-backgrounds.md`.
  Shaders that ship with Camtasia are TechSmith content. Render them only when
  a user's own project includes them, and never redistribute them.

## Open questions

- [?] The exact `eioe` easing curve.
- ✅ The layout of `.trec` `TSCM` records (cursor positions, cursor images
  with hotspots, button events, capture region, scale): see
  `docs/specs/trec.md` [obs, file-level only, 2026-10-19].
- [~] Transition names: catalogued in `docs/specs/transitions.md`. How a
  project names a shader transition, and the window placement between two
  clips, are still [?].
- [?] The rendering maths for each effect (shadow, rounded corners, motion
  blur, cursor physics).
- ✅ **Camtasia accepts our rewritten files** [obs, 2026-10-19].
  - We rewrote the demo project with `tscproj roundtrip -o`. The rewrite
    re-indents the file and drops jsoncpp's trailing spaces.
  - Camtasia 2026.2.3 opened and played the result with its group, effects and
    duration intact.
  - So Camtasia ignores whitespace, which means byte-for-byte formatting does
    not matter.
