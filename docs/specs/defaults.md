# Spec: missing key → value (M1 keys)

What a reader should assume when a key is absent. Collected from the same 24
projects as `transform.md` / `time-mapping.md` (298 clips, 83 track
attribute entries). "Always written" means the key was present in every
instance, so its default never matters for files Camtasia wrote; WizRec
should still write it.

Tags: **[obs]** observed in files, **[inf]** inferred, **[?]** unknown.

## Clip timing

| Key | Default | Evidence |
|---|---|---|
| `start`, `duration` | — (always written, required) | 298 / 298 [obs] |
| `mediaStart` | 0 | always written [obs]; default [inf] |
| `mediaDuration` | `duration / scalar` | always written [obs]; default [inf] |
| `scalar` | 1 | always written [obs] |
| effect `start` / `duration` | the whole clip | absent on every v10 effect [obs] |
| keyframe `interp` with no parameter `interp` | `eioe` | [?] (formats ≤ 4.0 omit both) |

## Visual parameters (`parameters.*`)

Absent keys are the norm: Camtasia writes only what differs from the
default, plus crops on most video clips [obs].

| Key | Default | Evidence |
|---|---|---|
| `translation0`, `translation1` | 0 | screen clip without `translation1` is centred in the thumbnail [obs] |
| `translation2` | 0 | never seen [inf] |
| `scale0`, `scale1` | 1 | never absent where `default-scale` ≠ 1 [inf] |
| `rotation0`, `rotation1`, `rotation2` | 0 | [inf] |
| `geometryCrop0..3`, `sourceCrop0..3` | 0 | [inf] |
| `opacity` | 1 | absent on all 261 non-callout, non-image clips, which render visible [obs] |
| `volume` | 1 | written only on `Group` and `StitchedMedia`, always 1.0 (17) [obs] |

## Audio attributes (`attributes.*` on `AMFile`, `StitchedMedia`, `Group`)

| Key | Default | Evidence |
|---|---|---|
| `gain` | 1.0 | Linear factor. Values seen: 1.0, **0.0** (muted: 37 of 40 unified `audio` children and 9 of 15 stitched clips in the vlog), 0.5, 0.1 (as float 0.100000001490116), 0.338…, 0.676… [obs]. Absent on video/image/callout clips. |
| `mixToMono` | false | always false where present (129) [obs] |
| `loudnessNormalization` | true | true in 125, absent in 2 (older samples) [obs] |
| `sourceFileOffset` (AMFile) | 0 | always 0 (117) [obs]; meaning [?] |

Nesting: the 9 stitched clips with `gain` 0.0 hold segments whose own `gain`
is 1.0 [obs] — the outer gain must therefore apply on top of the inner one
(multiply) for the clip to be silent [inf]. The demo `Group` has `gain` 1.0
[obs]; group gain multiplies the same way [inf]. `parameters.volume`
(1.0 wherever written) also multiplies [inf]. Track mute:
`trackAttributes[i].audioMuted` [obs, all false in the corpus].

## Tracks

| Key | Default | Evidence |
|---|---|---|
| `audioMuted`, `videoHidden` | false | present in all 83 entries [obs] |
| `magnetic`, `solo` | false | present in 68 / 62 of 83 (absent in older files) [obs] |
| `matte` | 0 | present in 62 [obs]; non-zero meaning (track matte mode) [?] |
| `metadata.IsLocked` | `"False"` (a string) | 83 / 83 [obs] |
| Track `parameters` | `{}` | [obs] |

## Timeline / project

| Key | Default | Evidence |
|---|---|---|
| `timeline.backgroundColor` | `[0, 0, 0, 255]` | present in all; 22 / 24 are black [obs] |
| `timeline.gain` | 1.0 | 1.0 in 12, absent in 12 (older files) [obs] |
| `timeline.legacyAttenuateAudioMix` | false | false in 12, absent in 12 [obs]; meaning [?] |
| `videoFormatFrameRate` | 30 | absent in format ≤ 3.0 [obs]; 30 [inf] |
| `allowSubFrameEditing` | false | [inf] |
| Group `widthAttr` / `heightAttr` | project `width` / `height` | absent in the format-2.0 group [obs]; value [inf] |
