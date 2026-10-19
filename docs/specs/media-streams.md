# Spec: source media streams (`sourceBin`, `trackNumber`, stream time)

Behavioural spec for how a clip's `src` + `trackNumber` select a stream in a
media file, what `sourceTracks` records, and where stream time 0 is.
Black-box only: project JSON compared with `ffprobe` output and a plain
QuickTime atom walk (sizes, types, header fields) of the user's own media.

Tags: **[obs]** observed in files, **[inf]** inferred, **[?]** unknown.

## Evidence base

- **E1 — demo `.trec`** (`recordings/…/Rec 10-19-2026.trec`, 33.6 MB,
  Camtasia 2026.2.3 recorder).
- **E2 — vlog sources**: 38 camera `.mp4` (HEVC + AAC, plus data tracks),
  17 `.m4a` (Camtasia-recorded voice, mono AAC), 1 `.mp3`. Only structure and
  numbers are reported here; no file content is quoted.
- **E3 — Camtasia sample projects** in the app bundle: three older `.trec`
  (format 3.0/4.0), one `.m4a`, 14 images (`.png`, `.pdf`), shader sources.
- Survey tool: every leaf clip of the 24 projects (175 clips with a `src`).

## 1. `sourceTracks` lists audio/video tracks only

| Claim | Tag | Evidence |
|---|---|---|
| `sourceTracks[i].type`: 0 = video, 1 = still image, 2 = audio. | [obs] | type 1 on all 14 `.png`/`.pdf` sources; 0 on video and `.tscshadervid`; 2 on audio |
| Data, timecode and metadata tracks are **not** listed. | [obs] | Each vlog `.mp4` has 5 tracks in the container (HEVC, AAC, two `meta`-handler data tracks `djmd`/`dbgi`, one `tmcd`) plus an MJPEG cover image in `udta`; `sourceTracks` has exactly 2 entries (video, audio). |
| Order = container track order of the remaining tracks. | [obs] | `.trec` (E1): `sourceTracks` [video 3024×1964, video 1920×1080, audio] = trak 1, 2, 3 = ffprobe streams 0, 1, 2. `.mp4`: [video, audio] = ffprobe 0, 1. |
| Source-type combinations seen: `.trec` (0,0,2), (0,2), (0); `.mp4` (0,2); `.m4a`/`.mp3` (2); images (1); `.tscshadervid` (0). | [obs] | |

## 2. `trackNumber` → stream

- **`trackNumber` is an index into `sourceTracks`**, and the type there
  matches the clip type in every case [obs, 175 / 175]:
  `VMFile`/`ScreenVMFile` → type 0, `AMFile` → type 2, `IMFile` → type 1.
- Distribution: `VMFile` 0 (66) and 1 (1: the demo camera); `ScreenVMFile` 0
  (4); `AMFile` 0 (51), 1 (60), 2 (1); `IMFile` 0 (16) [obs].
- It equals the **ffprobe stream index** in every file of the corpus, because
  audio/video tracks always come before data tracks there [obs]. That is a
  coincidence of these files. **Rule:** enumerate the container's video and
  audio tracks in track order, skipping data / timecode / metadata / cover
  art, and index that list with `trackNumber` [inf].
  - With AVFoundation: `asset.tracks` filtered to `.video`/`.audio`, in
    track order [inf].
  - With libavformat: streams with `codec_type` video or audio, excluding
    `AV_DISPOSITION_ATTACHED_PIC` [inf; the vlog's MJPEG cover is exactly such
    a stream, ffprobe index 5].
- `AMFile.channelNumber` is `"0"` when the audio track has
  `numChannels` 1 (30 clips) and `"0,1"` when it has 2 (82 clips) [obs]:
  a comma list of the source channels the clip uses.
- `AMFile.attributes.sourceFileOffset` is 0 in all 117 cases [obs]; meaning
  [?].
- The demo `.trec` is the only multi-video source: `trackNumber` 0 is the
  screen (`ScreenVMFile`), 1 the camera (`VMFile`), 2 the microphone
  (`AMFile`) [obs].

## 3. `sourceTracks` fields

### `editRate` and `range`

`range = [0, n]`: the track's playable duration is `n / editRate` seconds.

| Source | `editRate` | Container timing | `range[1]` equals | Tag |
|---|---|---|---|---|
| `.trec` video (E1) | 44100 | movie timescale `mvhd` 44100; media timescale 600 | `tkhd` duration in movie units (1132415, 1130798) | [obs] |
| `.trec` audio (E1) | 44100 | `mvhd` 44100; `elst`: 28-unit empty edit, then media from sample 2112 | `tkhd` duration 1133222 (includes the empty edit) | [obs] |
| `.mp4` video (E2) | 60000 | `mvhd` 60000, media 60000 | `tkhd` duration (e.g. 1253252) | [obs, 38/38] |
| `.mp4` audio (E2) | **240000** | `mvhd` 60000, media 48000, no `elst` skip | (AAC frames × 1024 − **2112**) × 5, i.e. the decoded length **minus 2112 priming samples** | [obs, 38/38 exact: `range[1] × 48000 == (ffprobe duration_ts − 2112) × 240000`] |
| `.m4a` (E2) | 48000 | `iTunSMPB` gapless tag: priming 0x840 = 2112, padding 0x1C0 = 448, length 0x13A600 = 1287680 | the `iTunSMPB` valid length (1287680) | [obs] |
| `.mp3` (E2) | 44100 | | 4412160 ≈ ffprobe 100.048969 s × 44100 | [obs] |
| `.m4a` sample (E3) | **1000** | | 8024 = 8.024 s vs ffprobe 8.02322 s (rounded up to ms) | [obs] |
| older `.trec` (E3) | 30 | media timescale 30 | frame count | [obs] |
| images | 600 | — | `[0, 1]` | [obs] |
| `.tscshadervid` | 30 | — | `[0, 9223372036854775807]` (2^63 − 1 = endless) | [obs] |

Conclusions:

- `range[0]` is 0 in every one of the 124 `sourceTracks` [obs].
- `editRate` is just the unit of `range`; it varies per file and per track
  (30, 600, 1000, 44100, 48000, 60000, 240000) [obs]. Never use it as a frame
  rate. For the files above it is a rate in which both the movie and the
  media timescale are whole numbers (44100 for 600 & 44100; 240000 for 60000
  & 48000) [inf]; the sample `.m4a` at 1000 shows it can also be coarser.
- `range` is the **presentation length after edit lists and AAC
  priming/padding removal** — the length AVFoundation reports as the track's
  time range [inf, consistent with all 124].
- `range` can be **longer than the real media**: RightClickEffectPreview's
  `.trec` says 235 frames at 30 (7.83 s) but its tscc2 stream lasts 198
  ticks (6.60 s, 52 frames) [obs]. Clamp requests to the decoded stream.

### Converting clip ticks to stream time

```
stream_seconds = inner(c, t) / project.editRate          (time-mapping.md §4)
```

`sourceTracks.editRate` is not involved: `mediaStart`/`mediaDuration` are
already in project ticks [obs: demo screen clip `mediaDuration`
18110400000 / 705600000 = 25.667 s ≤ range 1132415 / 44100 = 25.678 s; all
175 leaf clips satisfy `mediaStart + mediaDuration ≤ range length`].

### `sampleRate`

- Audio: the sample rate in Hz (44100, 48000) [obs].
- Video: an **approximate average** frame rate, written as a rational with a
  power-of-ten denominator [obs]:
  - `.mp4` 60000/1001 fps → `"2997/50"` = 59.94 (rounded to 2 decimals);
  - demo tscc2: 137 frames / 25.678333 s = 5.335237 → `"6669/1250"` = 5.3352;
  - demo camera: 727 frames / 25.641667 s = 28.35229 → `"283531/10000"` =
    28.3531 (does not match to 4 decimals; source of the small difference [?]);
  - RightClickEffectPreview: `8` for a stream ffprobe reports at 7.88 fps.
- **Do not use `sampleRate` for timing.** Frame timing comes from the
  stream's own timestamps (VFR, §5). It is display/metadata only [inf].

### Other fields

| Field | Meaning | Tag |
|---|---|---|
| `trackRect` | `[0, 0, w, h]` frame size of a video track (`[0,0,0,0]` for audio); per track, so a `.trec`'s camera track can differ from the source `rect` | [obs] |
| `numChannels` | audio channel count (0 for video) | [obs] |
| `bitDepth` | 16 for AAC audio; 24 for `.trec` video; 32 for shader | [obs] |
| `integratedLUFS`, `peakLevel` | loudness analysis of audio tracks; video tracks hold the placeholder 100.0 / −1.0 | [obs] |
| `tag` | `.trec` (E1): 1, 2, 3 = the container track IDs; 0 for every other source; absent in older samples | [obs]; use [?] |
| `metaData` | `"<file name>;"`; for the `.trec` screen track the file name is followed by 11 UUIDs separated by `;` | [obs]; the UUIDs likely name the recording's side streams (cursor, clicks, …) — M6 [?] |

## 4. Stream time origin

**Stream time 0 = the start of the track's presentation timeline (the movie
timeline, edit lists applied), with AAC priming removed.**

| Case | Observation | Consequence | Tag |
|---|---|---|---|
| `.trec` video tracks | `elst` = one edit (media time 0, full duration); first PTS 0 (tscc2), first presented PTS 0 (h264 camera with B-frame reordering: DTS starts at −40/600) | origin = first frame | [obs] |
| `.trec` audio | `elst` = 28/44100 s empty edit, then media from sample 2112 (priming skipped) | origin = movie time 0; the first real sample plays at 0.635 ms. `range` includes the empty edit. | [obs] |
| `.mp4` audio without edit list | Camtasia's `range` is 2112 samples shorter than the raw decode | Camtasia drops the 2112 priming samples; we infer it drops them at the **start** (standard AAC priming) so audio time 0 = decoded sample 2112 | [obs length; inf position] |
| `.m4a` with `iTunSMPB` | `range` = the gapless valid length | skip `priming` samples at the start, `padding` at the end | [obs length; inf position] |

Implementation consequences [inf]:

- **AVFoundation** (`AVAssetReader` on the asset track) already applies edit
  lists and AAC priming trims, so its presentation timestamps follow this
  origin directly.
- **libavcodec/libavformat:** honour edit lists (the default); when an AAC
  track has *no* edit list and no `iTunSMPB`, also drop the first 2112
  decoded samples. Otherwise the audio is 44 ms late relative to Camtasia
  (E2 camera files).
- Do **not** subtract a stream's `start_time` from its timestamps: for the
  `.trec` audio, ffprobe's `start_time` 0.000635 is a real 28-sample offset on
  the movie timeline [obs].
- The `.trec` camera (stream 1, 25.6417 s) and screen (stream 0, 25.6783 s)
  share the movie timeline; both start at 0 [obs]. A/V sync between them
  needs no offsets.

## 5. Frame timing (VFR)

| Stream | Timing | Tag |
|---|---|---|
| `.trec` tscc2 screen (E1) | time base 1/600; **137 packets (82 pictures) in 25.68 s**; packet gaps 5–615 (8 ms – 1.025 s); `stts` has 102 entries; only packet 0 is a keyframe. | [obs] |
| `.trec` h264 camera (E1) | 1/600; 727 frames; gaps 20–27 (33–45 ms), ~28.35 fps average; B-frames (`ctts`, 26 sync frames) | [obs] |
| `.trec` AAC (E1) | 44100 Hz mono, 1109 packets × 1024 | [obs] |
| `.mp4` HEVC (E2) | constant 1001/60000 (59.94 fps) | [obs] |
| older `.trec` (E3) | tscc2 at a 1/30 time base, constant or sparse (52 frames over 198 ticks) | [obs] |

The frame shown at stream time *s* is the last frame with presentation time
≤ *s* (hold) [inf — the only sensible reading of a sparse screen stream;
matches MediaEngine's contract].

**"No change" packets.** 55 of the 137 tscc2 packets in E1 are **1 byte**
long (e.g. PTS 17, 82, 102, 122 …). libavcodec's tscc2 decoder emits no
picture for them: `ffprobe -count_frames` reads 137 packets but 82 frames
[obs]. They mean "the screen did not change" [inf]. A decoder must keep
showing the previous picture through such a packet; frame-accurate seeking
must land on the last packet that produced a picture. Counting frames by
packets (137) or by decoded pictures (82) gives different answers — use
timestamps, never counts.

## 5a. Colour: tscc2 is limited-range BT.601

The demo tscc2 stream carries **no colour tags**: ffprobe reports
`color_range/space/transfer/primaries = unknown`, and the `tsc2` sample
description has no `colr` atom [obs]. (The camera track, by contrast, has
`colr nclc 1/1/1` = BT.709 and ffprobe `tv`/`bt709` [obs].)

Test against Camtasia's own render [obs]:

1. Decode every tscc2 picture at the thumbnail's scale (554×360 = the screen
   recording's area in the 640×360 `ProjectThumbnail`, per `transform.md`)
   and pick the one closest to the thumbnail outside the camera circle:
   picture 15 (PTS 13312/600 = 22.19 s) — mean abs error 1.5/255 at 138×90.
2. Render that picture under four hypotheses (`in_color_matrix` × `in_range`,
   area scaling, full-range RGB out) and compare with the thumbnail.

| Hypothesis | Locally flat pixels (n = 98032), mean \|error\| R/G/B | Saturated flat pixels (n = 1760), mean \|error\| R/G/B |
|---|---|---|
| **BT.601, limited** | **0.01 / 0.12 / 0.70** | **0.94** / 7.44 / **0.57** |
| BT.709, limited | 1.53 / 0.99 / 1.01 | 3.46 / 5.06 / 1.40 |
| BT.601, full | 12.8 / 10.5 / 9.6 | 10.1 / 5.0 / 11.6 |
| BT.709, full | 11.4 / 9.5 / 9.9 | 1.3 / 3.1 / 7.4 |

Point samples (thumbnail → 601-limited → 709-limited):
pink (202,104,123) → (201,104,123) → (209,114,122);
red (255,74,97) → (255,75,98) → (255,94,96);
blue-grey (74,117,173) → (74,117,173) → (69,116,176);
background (20,35,43) → (20,35,44) → (19,34,44).

- **Limited (video) range** [obs]: full range is off by ~10 levels
  everywhere; decoded luma spans 13…239.
- **BT.601 matrix** [obs]: exact to ±1 level on every unclipped colour;
  BT.709 is off by 5–20 levels on saturated reds and pinks.
- The only systematic residue is a saturated blue UI button that clips
  (thumbnail (0,136,255), 601 → (0,149,255)): out-of-gamut values clip
  differently; it does not favour 709 (709 gives 141, also wrong).
- Transfer: none applied beyond the matrix — decoded RGB equals the sRGB
  PNG values [obs]; treat the RGB as sRGB (the PNG has an `sRGB` chunk).

**Rule:** convert tscc2 `yuv444p` with the BT.601 matrix, limited range, into
sRGB [obs]. Tagged streams (h264/HEVC with `colr`) follow their tags [inf].

## 6. What a `.trec` contains

A QuickTime movie (`ftyp` `qt  `), layout `ftyp`, `wide`, `mdat`, `moov`,
then **two top-level TechSmith atoms after `moov`** [obs, E1]:

| Item | Content | Tag |
|---|---|---|
| `moov/trak` 1 | tscc2 screen video, 3024×1964 (`tapt` aperture atom, `sdtp`), `udta/name` "100" | [obs] |
| `moov/trak` 2 | h264 camera 1920×1080, `udta/name` "101" | [obs] |
| `moov/trak` 3 | AAC mono 44.1 kHz, `udta/name` "103" | [obs] |
| `mvhd` | timescale 44100, `nextTrackID` 4 — so there is **no hidden fourth track** | [obs] |
| `TSCR` (80 bytes) | recorder identity: the strings "Camtasia", "2026.2.3", "Mac", "27.0.1" | [obs] |
| `TSCM` (19862 bytes in E1) | a sequence of `DATA` records holding recording-environment text (CPU count, OS version, RAM, capture device names, names/titles of captured applications and windows) and binary records | [obs, list only] |

- Cursor position and click data are **not** in any `trak` [obs: only three
  tracks exist]. They must be in `TSCM` (or be reconstructed from it); the
  layout is M6 work (`docs/specs/trec.md`) [inf].
- **Privacy:** `TSCM` contains window titles and app names from the user's
  desktop at recording time. WizRec must never log, upload or copy it into
  test fixtures [obs content type].
- The 17 vlog `.m4a` files also end with `TSCR` + `TSCM` atoms (they were
  recorded by Camtasia's recorder) [obs]. The camera `.mp4` files do not.

## 7. Non-media sources

- **Images** (`.png`, and `.pdf` in the Camtasia samples): `sourceTracks` =
  one type-1 track, `editRate` 600, `range` [0, 1], `sampleRate` 0, `rect` =
  pixel size (a 160×109 `.pdf`) [obs]. MediaEngine must rasterise PDF page 1
  at `rect` size [inf].
- **`.tscshadervid`**: one type-0 track, `range` [0, 2^63−1], `editRate` 30,
  `sampleRate` 30, `bitDepth` 32, `rect` from the shader's `width`/`height`;
  the source entry also has an `effectDef[]` describing its uniforms
  (`Color0..3`, `MidPointX/Y`, `Speed`, with defaults and ranges) [obs].
  The clip's `metadata.ShaderVidSource` may point into the Camtasia app
  bundle while `src` points at a copy inside the project's `media/` [obs].

## 8. Open questions

- [?] Whether Camtasia drops AAC priming at the start (assumed) or the end of
  E2's `.mp4` audio. A reference export of a clip with a sharp audio transient
  at a known video frame would settle it; low priority (44 ms).
- [?] Meaning of `tag`, `sourceFileOffset`, the 11 UUIDs in the screen
  track's `metaData`, and `TSCM` record layout (M6).
- [?] Exact formula for video `sampleRate` (cosmetic).
