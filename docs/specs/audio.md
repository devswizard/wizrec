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
- **No reference export** with audio exists yet, so every rule about the mix
  that comes out is [?] until AU2.

## 1. Level keys in the project

| Key | Where | Values | Meaning |
|---|---|---|---|
| `targetLoudness` | top level | −18.0 (18 projects; absent in 6 older ones) | Normalisation target, LUFS [obs value] |
| `shouldApplyLoudnessNormalization` | top level | true (17), false (1), absent (6) | Project-wide switch [obs] |
| `loudnessNormalization` | `sourceBin[]` | true (66), false (1), absent (15) | Per-source switch [obs] |
| `attributes.loudnessNormalization` | `AMFile`, `StitchedMedia` | true (125) | Per-clip switch [obs] |
| `integratedLUFS` | `sourceTracks[]` | −11.3 … −39.0 for real audio; `-Infinity` for silence; `100.0` on video and image tracks (a sentinel) | Measured integrated loudness of the source track, LUFS (EBU R128) [obs values; inf method] |
| `peakLevel` | `sourceTracks[]` | 0.08 … **1.034** for audio; 0.0 for silence; −1.0 on non-audio (a sentinel) | Peak as a **linear** amplitude (1.0 = 0 dBFS). Values above 1 suggest a true-peak (inter-sample) measure [inf] |
| `attributes.gain` | `AMFile`, `StitchedMedia`, `Group` | 1.0, 0.0, 0.5, 0.1, 0.338…, 0.676… | Linear clip gain; nested gains multiply (`defaults.md`) [obs/inf] |
| `parameters.volume` | `Group`, `StitchedMedia` | 1.0 constant (17); no keyframes in the corpus | Animatable volume, linear [inf]. Fades and volume keyframes are expected here [inf, AU1] |
| `timeline.gain` | timeline | 1.0 (12), absent (12) | Master gain, linear [inf] |
| `timeline.legacyAttenuateAudioMix` | timeline | false (12), absent (12) | Old-style mix attenuation. Probably a fixed attenuation by track count when true [?] |
| `audioFormatSampleRate` | top level | 44100 | Mix and export sample rate [inf] |
| `sourceTracks[].sampleRate`, `numChannels`, `bitDepth` | source | 44100/48000; 1/2; 0 or 16 | Source format (display only; `media-streams.md`) |

Example of a hard case (vlog, A2): one source at **−38.99 LUFS** with peak
**0.1016** (−19.9 dBFS). Raising it to −18 LUFS needs +21 dB, which would
put its peak at about +1.1 dBFS. Normalisation therefore needs a peak rule
or a limiter.

## 2. Loudness normalisation: what is known

| Claim | Tag |
|---|---|
| Loudness is measured **per source track** when the media is imported, and stored on the source (`integratedLUFS`, `peakLevel`) | [obs] |
| Normalisation applies when all three switches are on: project, source and clip | [inf] |
| Gain is computed **per source**, not on the final mix. The stored per-source measurements are what a per-clip gain needs; a mix-level normaliser would need no stored values | [inf] |
| Working formula: `g_dB = targetLoudness − integratedLUFS`, then capped so that `peakLevel · 10^(g_dB/20) ≤ 1.0` (peak-limited gain, no limiter) | [inf, weak] Capping and limiting are both plausible; AU2 decides |
| Normalisation gain multiplies with `attributes.gain`, `parameters.volume`, group gains and `timeline.gain` | [inf] |
| `-Infinity` LUFS (silence) → no normalisation gain | [inf] |
| Whether `targetLoudness` also drives a final mix limiter on export | [?] |

## 3. Audio effects

Only one audio effect occurs in the corpus [obs]:

```
{ "effectName": "VSTEffect-DFN3NoiseRemoval", "bypassed": false,
  "category": "categoryAudioEffects",
  "parameters": { "Amount": 0.8, "Bypass": 0.0 },
  "metadata": { "ExtandableEffectData": "<base64, 244201 chars>", "effectIndex"?: "2" } }
```

| Claim | Tag |
|---|---|
| `VSTEffect-<name>` wraps a bundled VST3 plug-in; `<name>` matches `Resources/VST/<name>.vst3` | [obs] |
| `Amount` (0–1) is the noise-removal strength. `Bypass` is a plug-in-level bypass (0/1), separate from the effect's `bypassed` | [inf] |
| `ExtandableEffectData` (sic) is opaque plug-in state: base64 that is almost all zero bytes (66 distinct characters in 244,201). WizRec must **preserve it verbatim** and must never interpret it or reuse the plug-in | [obs; CLAUDE.md M8: use an open model instead] |
| WizRec maps `Amount` to the strength of its own open noise-removal model (RNNoise/DeepFilterNet) | [inf] |

**Effects named in the bundle but unseen in projects** (A3). Their
`effectName` spellings and parameters are [?] until AU1:

- noise reduction (classic, as opposed to AI);
- fade in and fade out;
- **dynamics processor**: probably "Volume Leveling" / compression;
- **emphasize**: ducking other tracks;
- **pitch**;
- clip speed (affects audio too);
- click sound.

## 4. Classic fades

Camtasia's audio Fade In and Fade Out were historically applied as volume
points. Whether they now appear as `parameters.volume` keyframes or as
effects with `leftEdgeMods`/`rightEdgeMods` (`effects/README.md` §1) is [?].
AU1 settles it.

## 5. Experiments

Save into `~/WorkDir/vibe_coding/camtasia_rea_refs/research/audio/`.

- **AU1: names and parameters (UI, about 5 minutes).**
  1. New project. Put the same audio clip (any 15-s speech) on 8 tracks.
  2. Apply one per track, with defaults: Noise Removal, AI Noise Removal,
     Volume Leveling (or Dynamics Processor), Emphasize, Pitch, Fade In,
     Fade Out.
  3. On the eighth track, set Clip Speed to 2×.
  4. On the first clip, also drag a volume point down to about 50 %.
  5. Save as `au1-audio.cmproj`.
- **AU2: normalisation behaviour (qa-generated synthetic audio; export).**
  qa makes a project from original test signals, at 48 kHz and 10 s each,
  placed one after another on one track:
  - (a) pink noise at −40 LUFS with peak −20 dBFS (low crest);
  - (b) a click train at −30 LUFS with peak −1 dBFS (high crest, so
    normalising would clip);
  - (c) pink noise at −10 LUFS;
  - (d) a copy of (a) with clip `loudnessNormalization` false;
  - (e) (a) and (c) overlapping on two tracks for 5 s (does normalisation
    act per clip or on the mix?).

  The user opens the project (Camtasia measures the sources on import),
  saves it as `au2.cmproj` (this captures `integratedLUFS`/`peakLevel` as
  Camtasia measured them) and exports `au2.m4a` (*Export ▸ Audio only*).
  Analysis: `ffmpeg -af ebur128=peak=true` per 10-s segment against the
  target −18 LUFS.
