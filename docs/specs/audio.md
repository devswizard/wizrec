# Spec: audio (gain, loudness normalisation, audio effects)

What the project files say about audio levels, loudness normalisation and
audio effects, and what still needs a reference export.

Tags: **[obs]** observed in files, **[inf]** inferred, **[?]** unknown.

## Evidence base

- **A1: 24 projects.** Audio-relevant keys were counted across every clip,
  including clips nested in groups, stitched media and unified media.
- **A2: 59 audio `sourceTracks`.** These come from the demo, the vlog and
  the bundle samples, and include `integratedLUFS` and `peakLevel` values.
- **A3: bundle resource names** (names only):
  - `iconAINoiseRemoval`, `iconNoiseReduction`;
  - `iconAudioFadeIn`, `iconAudioFadeOut`;
  - `iconDynamicsProcessor`, `iconEmphasize`, `iconPitch`;
  - `iconClipSpeed`, `iconClickSound`;
  - `AudioFX*` timeline-strip images;
  - `VST/DFN3NoiseRemoval.vst3`.
- **A4: runtime saves (session 5).** Camtasia 2026.2.3 applied each audio
  effect, fade and volume point to generated projects and saved them (AU1).
  It also re-measured the AU2 test signals on save. See §2.1, §3 and §4.
- **No reference export** with audio exists. The installed Camtasia is a
  trial with an export watermark gate, so every rule about the mix that comes
  out stays [?].

## 1. Level keys in the project

| Key | Where | Values | Meaning |
|---|---|---|---|
| `targetLoudness` | top level | −18.0 (18 projects; absent in 6 older ones) | Normalisation target, LUFS [obs value] |
| `shouldApplyLoudnessNormalization` | top level | true (17), false (1), absent (6) | Project-wide switch [obs] |
| `loudnessNormalization` | `sourceBin[]` | true (66), false (1), absent (15) | Per-source switch [obs] |
| `attributes.loudnessNormalization` | `AMFile`, `StitchedMedia` | true (125) | Per-clip switch [obs] |
| `integratedLUFS` | `sourceTracks[]` | −11.3 … −39.0 for real audio; `-Infinity` for silence; `100.0` on video and image tracks (a sentinel) | Measured integrated loudness of the source track, LUFS (EBU R128) [obs values; inf method] |
| `peakLevel` | `sourceTracks[]` | 0.08 … **1.034** for audio; 0.0 for silence; −1.0 on non-audio (a sentinel) | Peak as a **linear** amplitude (1.0 = 0 dBFS). Values above 1 come from resampling to the mix rate (§2.1) [obs/inf] |
| `attributes.gain` | `AMFile`, `StitchedMedia`, `Group` | 1.0, 0.0, 0.5, 0.1, 0.338…, 0.676… | Linear clip gain; nested gains multiply (`defaults.md`) [obs/inf] |
| `parameters.volume` | `Group`, `StitchedMedia`, `AMFile` | 1.0 constant (17) in the corpus; keyframes after fades or audio points | Animatable volume, linear. Fades and audio points are keyframes here (§4) [obs, AU1] |
| `timeline.gain` | timeline | 1.0 (12), absent (12) | Master gain, linear [inf] |
| `timeline.legacyAttenuateAudioMix` | timeline | false (12), absent (12) | Old-style mix attenuation. Probably a fixed attenuation by track count when true [?] |
| `audioFormatSampleRate` | top level | 44100 | Mix and export sample rate; also the rate at which sources are measured (§2.1) [inf] |
| `sourceTracks[].sampleRate`, `numChannels`, `bitDepth` | source | 44100/48000; 1/2; 0 or 16 | Source format (display only; `media-streams.md`) |

Example of a hard case (vlog, A2): one source at **−38.99 LUFS** with peak
**0.1016** (−19.9 dBFS). Raising it to −18 LUFS needs +21 dB, which would
put its peak at about +1.1 dBFS. Normalisation therefore needs a peak rule
or a limiter.

## 2. Loudness measurement and normalisation

### 2.1 How Camtasia measures a source (AU2, runtime save)

AU2 (session 5): Camtasia opened a WizRec-generated project with four
original mono 48 kHz test signals, and the project was saved again. Camtasia
filled in `integratedLUFS` and `peakLevel` for each source. We compared its
values with our own BS.1770 measurement (and with ffmpeg `ebur128`) of the
same files.

| Signal (mono, 48 kHz) | Ours, as mono | Camtasia `integratedLUFS` | Ours, dual-mono resampled to 44.1 kHz | Camtasia `peakLevel` (dBFS) | Sample peak at 48k / at 44.1k |
|---|---|---|---|---|---|
| pink noise | −40.0 | **−37.25** | −37.2 | 0.0473 (−26.5) | −26.3 / −26.4 |
| click train | −30.0 | **−26.95** | −26.9 | 0.891 (−1.0) | −1.0 / −1.0 |
| pink noise, loud | −10.0 | **−7.55** | −7.2 | 1.0347 (+0.30) | −0.5 / +0.4 (true peak +0.6) |
| synthetic speech (AU1) | −17.2 | **−14.19** | −14.2 | 0.8305 (−1.6) | −1.6 / −1.6 |

| Claim | Tag |
|---|---|
| Camtasia measures a source when it is added or first opened, and stores the result on the source track. A project with the sentinel values (100.0 / −1.0) gets real values on its first save | [obs] |
| A **mono** source is measured as if its one channel played on both stereo channels. The result is about 3 LU louder than a plain BS.1770 mono reading | [obs] (+3.0 on speech and clicks) |
| The measurement is taken at the project's mix rate (`audioFormatSampleRate`, 44100), after resampling. Matching values for the low-level pink noise only appear once we resample to 44.1 kHz | [inf, good fit] |
| Projects without a usable `audioFormatSampleRate` (Camtasia always writes the key): WizRec's mixer measures unmeasured sources at its own mix rate (48 kHz on export), not at 44.1 kHz, so it never resamples a whole source just to measure it (AUD12-1) | [WizRec] |
| `peakLevel` is a linear sample peak taken after that resampling. It is neither the 48 kHz sample peak nor a 4× oversampled true peak; the loud pink noise reads +0.30 dBFS, between the two | [inf] |
| The loud pink noise reads 0.35 LU lower than our 44.1 kHz dual-mono value. Clipping in the conversion, or Camtasia's resampler, may explain it | [?] |
| WizRec should store values computed the same way (dual-mono for mono sources, at the mix rate, sample peak after resampling), so that projects round-trip without Camtasia remeasuring them differently | [inf] |

### 2.2 Normalisation on output

| Claim | Tag |
|---|---|
| Normalisation applies when all three switches are on: project, source and clip | [inf] |
| Gain is computed **per source**, not on the final mix | [inf] |
| Working formula: the gain in dB is `targetLoudness` minus `integratedLUFS`, capped so the stored peak does not go above 0 dBFS | [inf, weak] |
| Normalisation gain multiplies with `attributes.gain`, `parameters.volume`, group gains and `timeline.gain` | [inf] |
| `-Infinity` LUFS (silence) gets no normalisation gain | [inf] |
| Whether a peak cap or a limiter is used, and whether `targetLoudness` drives a limiter on the final mix | **[?] blocked**: AU2 needs an audio export, and the installed Camtasia is a trial whose only export choices are "with/without watermark" (DECISIONS 2026-10-20). Without the user's licensed export this stays open |

## 3. Audio effects

### 3.1 Catalog (Camtasia 2026.2.3)

The Audio Effects panel lists exactly these items [obs]: AI Noise Removal,
Audio Compression, Captions, Clip Speed, Emphasize, Fade In, Fade Out, Pitch.
There is **no** classic "Noise Removal" and **no** "Volume Leveling" item in
this version [obs]. Older projects may still contain other effect names;
WizRec must keep any unknown audio effect as it is.

Each item, applied with defaults to an audio clip and saved (AU1, runtime):

| Panel name | What the save contains | Default parameters |
|---|---|---|
| AI Noise Removal | effect `VSTEffect-DFN3NoiseRemoval` | `Amount` 0.8, `Bypass` 0.0, plus opaque `metadata.ExtandableEffectData` (the same 244,201-character blob as in the corpus) |
| Audio Compression | effect `WinCompression` | `ratio` 10.0, `threshold` −20.0, `gain` 9.0, `attack` 0.0, `release` 3500.0, `preset` 1 (integer) |
| Emphasize | effect `Emphasize` | `emphasizeAmount` 0.8, `emphasizeRampPosition` 0 (integer), `emphasizeRampInTime` and `emphasizeRampOutTime` both 705600000 (1 s in ticks) |
| Pitch | effect `Pitch` | `pitch` −200.0, `effectBlend` 100.0, `smoothness` 50.0, `tightness` 50.0 |
| Clip Speed | **no effect entry**. Only `metadata.clipSpeedAttribute` turns from false to true, and `metadata.effectApplied` becomes "Clip Speed". `scalar` stays 1 until a speed is set | — |
| Fade In / Fade Out | **no effect entry**: volume keyframes (§4) | — |

Common shape of every audio effect entry [obs]: `effectName`, `bypassed`
false, `category` "categoryAudioEffects", `parameters` as plain numbers (no
`type`/`keyframes` wrappers), and no `start`/`duration`. Adding any effect
also sets the clip's `metadata.effectApplied` to that effect's name; the key
reads "none" on a clip without effects [obs].

### 3.2 Meaning of the parameters

| Effect | Parameter | Meaning | Tag |
|---|---|---|---|
| `VSTEffect-DFN3NoiseRemoval` | `Amount` 0–1 | Noise-removal strength. WizRec maps it to its own open model | [inf] |
| | `Bypass` | Plug-in-level bypass (0/1), separate from `bypassed` | [inf] |
| | `ExtandableEffectData` (sic) | Opaque plug-in state. Preserve it verbatim; never interpret it | [obs] |
| `WinCompression` | `threshold` | Level in dBFS above which gain is reduced | [inf] |
| | `ratio` | Compression ratio (10 means 10:1) | [inf] |
| | `gain` | Make-up gain in dB applied after compression | [inf] |
| | `attack`, `release` | Times in milliseconds (0 and 3500) | [inf from magnitudes] |
| | `preset` | Index of the UI preset the values came from; 1 is the default preset. It doesn't change the sound by itself | [inf] |
| `Emphasize` | `emphasizeAmount` 0–1 | How much the **other** tracks are lowered (ducked) while this clip plays | [inf] |
| | `emphasizeRampInTime`, `emphasizeRampOutTime` | Duck fade-in and fade-out lengths in ticks | [inf] |
| | `emphasizeRampPosition` | Where the ramps sit relative to the clip edges (0 = inside the clip) | [?] |
| `Pitch` | `pitch` | Pitch shift in **cents** (−200 is two semitones down) | [inf] |
| | `effectBlend` 0–100 | Wet/dry mix in percent | [inf] |
| | `smoothness`, `tightness` 0–100 | Quality controls of the pitch shifter; no audible rule known | [?] |

Each mapping above needs an exported reference to confirm the sound, which is
blocked by the trial export gate [?].

### 3.3 AI Noise Removal without the plug-in blob (answer to audio, 2026-10-20)

Test (RT-019): a Camtasia-saved project was copied, and only the
`metadata.ExtandableEffectData` object was removed from its
`VSTEffect-DFN3NoiseRemoval` entry, leaving `effectName`, `bypassed`,
`category` and `parameters` {`Amount` 0.8, `Bypass` 0.0}.

| Check | Result | Tag |
|---|---|---|
| Opening it in Camtasia | No alert. Properties shows *AI Noise Removal* with Amount 80 | [obs] |
| Saving it unchanged | The effect is kept, and Camtasia **regenerates** `metadata.ExtandableEffectData` (the same length and form as before) | [obs] |
| Changing Amount to 50 in the panel, then saving | `Amount` 0.5 is saved, with a regenerated blob that differs from the 0.8 one in its first bytes. The clip's `metadata` also gains `default-VSTEffect-DFN3NoiseRemoval-Amount` "0.8": the value before the user's change, recorded as a string | [obs] |

So the blob is **optional on input**. Camtasia rebuilds it from
`parameters` and works normally. WizRec may write this effect **without**
`metadata` when it creates one, and must still preserve an existing blob
verbatim [obs]. WizRec must not compute or interpret the blob.

## 4. Fades and volume points

Fades are **not** effects. They are written as keyframes of the clip's
`parameters.volume` (linear, 1.0 = unchanged) [obs, AU1]:

- **Fade In** on a 13.17 s clip writes two points: 0.0 at clip time 0 and
  1.0 at 1 s. Default fade length: **1 s** [obs].
- **Fade Out** on the same clip writes three points: 1.0 at 0, 1.0 at
  (clip duration − 1 s) and 0.0 at the clip's end [obs].
- **Edit ▸ Add Audio Point** on a clip without volume keyframes writes two
  points: one at clip time 0 and one at the playhead, both at the current
  level (1.0). A second use adds one more point at the new playhead [obs].
- Keyframe times are relative to the clip's start (in these tests the clip's
  `mediaStart` was 0, so clip time and media time match). Every point has
  `duration` 0 and `endTime` equal to `time` [obs].
- No point carries an `interp` key. Between points the level changes linearly
  in the linear-gain domain [inf]. The exact curve needs an export [?].
- When volume keyframes exist, the constant form of `volume` is replaced by
  `{type: "double", keyframes: [...]}` with no `defaultValue` [obs].

## 5. Experiments

- **AU1** (done, runtime saves): `research/audio/au1-audio.cmproj`,
  `au1b-fades.cmproj`, `au1c-fades.cmproj`. Still open: setting a volume point
  to 50 % and Clip Speed to 2× through the UI (both need a value field or a drag
  that the automation doesn't reach yet). These are covered by
  `time-mapping.md` (speed) and §4 (keyframe form).
- **AU2** (save done, export blocked): `research/audio/au2/au2.cmproj` gives
  the measurements in §2.1. The output side (per-clip vs mix, cap vs limiter)
  needs `au2.m4a` from a licensed Camtasia.
