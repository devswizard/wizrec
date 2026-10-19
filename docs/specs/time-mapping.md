# Spec: time mapping (timeline time → clip time → media time)

Behavioural spec for which source instant a clip shows at a given timeline
time, across every clip type, plus the time base of keyframes and effects.
Black-box only: derived from project JSON and the user's own media.

Tags: **[obs]** observed in files, **[inf]** inferred, **[?]** unknown.

## Evidence base

The same 24 projects as `transform.md` (demo, the user's vlog with 49 sources
and 233 clips, 22 Camtasia sample projects read in place; formats 2.0–10.0;
`editRate` 30 and 705600000). Every clip was walked recursively (groups,
stitched segments, unified children): **298 clips** in total. Numbers were
compared as exact fractions (`int`, `float`, and `"p/q"` strings parsed
exactly).

## 1. Number forms

| Field | Forms observed | Count |
|---|---|---|
| `start`, `duration` | integer | 298 / 298 |
| `mediaStart` | integer 296, float 2 (`0.0` on both groups) | |
| `mediaDuration` | integer 295, float 2 (both groups, e.g. `18110400000.0`), rational string 1 (`"13771788800000/113"`) | |
| `scalar` | integer `1` 296, rational string 2 (`"304/457"`, `"766479/4918496"`) | |

- Readers must accept all three forms for every time field [obs].
- `Group` clips always wrote `mediaStart`/`mediaDuration` as floats in both
  groups seen [obs]; this is harmless.
- Rational strings are exact `numerator/denominator` [obs].

## 2. Frame alignment

- With `allowSubFrameEditing: false` (every v10 project), `start`,
  `duration`, `mediaStart` and `mediaDuration` are whole multiples of one
  output frame, `editRate / videoFormatFrameRate` ticks (23520000 at 30 fps,
  11760000 at 60 fps) [obs: 297 of 298 clips × 4 fields].
- The single exception is the `mediaDuration` of a sped-up clip (vlog 215),
  which is whatever `duration / scalar` gives [obs].
- Example: the demo's screen-recording clip is 18110400000 ticks = 770 frames
  = 25.6667 s, the largest whole number of 30-fps frames inside the 25.6783-s
  stream; the camera clip is 769 frames inside 25.6417 s [obs]. So a clip
  made from a whole source is that source's length **rounded down to a
  frame** [inf].

## 3. Scalar (speed)

**`mediaDuration × scalar = duration` exactly; `scalar = 1 / speed`.**

- Exact for all 298 clips, including both non-unit scalars [obs]:
  - vlog `StitchedMedia` 82: `duration` 3575040000 (304 frames @60),
    `mediaDuration` 5374320000 (457 frames), `scalar` "304/457" →
    5374320000 × 304/457 = 3575040000 exactly. Speed 457/304 ≈ 1.503×.
  - vlog `StitchedMedia` 215: `duration` 18992400000, `mediaDuration`
    "13771788800000/113", `scalar` "766479/4918496" → product = duration
    exactly. Speed ≈ 6.417×.
  - The reverse relation (`duration × scalar = mediaDuration`) fails for both.
- No non-unit scalar exists on any other clip type in the corpus (no sped-up
  `VMFile`, `AMFile`, `UnifiedMedia`, `Group` or `Callout`) [obs]. Applying
  the same rule to them is [inf].
- In both sped-up clips the segments inside have `scalar` 1 [obs]: speed is
  stored only on the outer clip.

## 4. The mapping, per clip

For a clip `c` on a track whose time is `t` (ticks):

```
visible(c, t)   ⇔  c.start ≤ t < c.start + c.duration
inner(c, t)     =  c.mediaStart + (t − c.start) / c.scalar       (exact rational)
```

`inner` lies in `[mediaStart, mediaStart + mediaDuration)` [obs: follows from
§3]. `mediaStart` is in **inner (media) units, not divided by speed**: vlog
215 has `mediaStart` 4998000000 (425 frames) while its speed is 6.4×, and
`mediaStart + mediaDuration` (179.8 s) ≤ the stitched content length
(244.4 s) [obs]. (The opposite reading — `mediaStart` in timeline units —
also fits inside 244.4 s here, so this is [inf, strong] rather than proof; it
follows from `mediaDuration` being in media units, which §3 proves.)

What `inner` addresses depends on the type:

| `_type` | `inner(c, t)` is… | Then |
|---|---|---|
| `VMFile`, `ScreenVMFile`, `AMFile` | the stream time of `sourceTracks[trackNumber]`, in project ticks | decode at `inner / editRate` seconds (see `media-streams.md` for stream origin) |
| `IMFile` | meaningless: `mediaStart` = 0 and `mediaDuration` = 1 (one tick) in all 16 images, whatever the duration | show the still for the whole clip [obs] |
| `.tscshadervid` `VMFile` | shader time; the source track has `range` [0, 2^63−1] (infinite) | feed `inner / editRate` seconds as the shader's time uniform [inf] |
| `Callout` | animation time (no media); `mediaStart` = amount trimmed off the callout's left edge (seen 0, 22, 23, 24, 31, 36, 38) | used as the keyframe time base, §6 |
| `UnifiedMedia` | — evaluate the `video` and `audio` children directly (below) | |
| `StitchedMedia` | a time on the stitched clip's **inner timeline** (segments laid end to end) | find the segment, recurse |
| `Group` | a time on the group's **inner timeline** | evaluate every inner track at that time, recurse |

### UnifiedMedia

- In format 10.0 (demo + vlog, 60 unified clips, 120 children) the `video` and
  `audio` children repeat the parent's `start`, `duration`, `mediaStart`,
  `mediaDuration` and `scalar` exactly [obs]. Children are **not** offset
  from the parent: `child.start == parent.start`, in the same (parent track)
  time frame.
- Format 3.0 samples (CursorEffectPreview, LeftClickEffectPreview) differ:
  the parent's `mediaDuration` is the whole source length (307 / 311) while
  the children carry the real mapping (`mediaDuration` 120, and in one case
  `mediaStart` 10 on the children vs 0 on the parent) [obs].
- **Rule:** map each child with its own fields, using the parent's track time
  `t` directly (no nesting). This gives the right answer for both formats
  [inf].

### StitchedMedia

- `medias[]` are segments laid end to end on an inner timeline starting at 0:
  `seg[0].start == 0` and `seg[i].start + seg[i].duration == seg[i+1].start`
  in all 15 stitched clips (2–4 segments each) [obs].
- Each segment is an ordinary clip (`UnifiedMedia` 20, `AMFile` 17) with its
  own `mediaStart`/`mediaDuration` into the source; all have `scalar` 1 [obs].
- The stitched clip's own `mediaStart`/`mediaDuration` select a window of that
  inner timeline: `mediaStart + mediaDuration ≤ Σ seg.duration` in all 15
  [obs]. E.g. vlog 72: window 15723120000 + 3022320000 inside 37714320000.
- Segments are cuts of **one** source: every segment of a stitched clip has the
  same `src` [obs].
- **Recursion:** `s = inner(stitched, t)`, pick the segment with
  `seg.start ≤ s < seg.start + seg.duration`, then
  `inner(seg, s)` = `seg.mediaStart + (s − seg.start) / seg.scalar`. For a
  `UnifiedMedia` segment, do this for its `video`/`audio` children (equal
  fields) [obs structure, inf evaluation].
- So the effective speed of a stitched segment is `1 / (stitched.scalar ×
  seg.scalar)`; only the outer factor was ever ≠ 1 [obs].
- `minMediaStart` is `0.0` in all 15 [obs]; meaning [?] (perhaps the lowest
  allowed `mediaStart` when the left edge is extended).

### Group

- A group's children live on its inner timeline: `inner(group, t)` is the time
  at which every inner track is evaluated [inf]. **Caveat:** all 2 groups in
  the corpus have `start` 0 and `mediaStart` 0, so the data cannot distinguish
  "children relative to the group's inner timeline" from "children in absolute
  time". The nested-timeline rule matches Camtasia's UI model (a group is a
  sub-timeline you can open and trim) — experiment X5 confirms.
- Group `scalar` was 1 in both; speed on a group is [inf] the same rule, and
  composes with the children's own scalars: total speed
  = `1 / (group.scalar × child.scalar)`.
- Group `duration` = the latest child end (demo: 18110400000 = the screen
  clip's end) [obs, one case].
- `attributes.maxDurationAttr` (demo: 18086880000, the shorter camera/shader
  length, not the latest child end) [obs]; meaning [?]. Not used for
  playback.

## 5. Track time and nesting summary

```
evaluate(track at time t):
  for clip in track.medias where visible(clip, t):
     m = inner(clip, t)
     Group         → evaluate(each inner track at m)
     StitchedMedia → segment containing m → inner(segment, m) → recurse
     UnifiedMedia  → children evaluated at t (not m)
     leaf          → source stream at m
```

- Clips on one track never overlap [inf; no overlap seen].
- Project length = latest `start + duration` over top-level tracks;
  `metadata.projectDuration` holds it as display text ("00:25") [obs].

## 6. Keyframes and animations

### Keyframe fields

- Each keyframe: `time`, `endTime`, `duration`, `value`, optional `interp`
  [obs]. `endTime == time + duration` in all 118 numeric keyframes [obs].
- `interp` codes seen: `eioe`, `linr`, and **`bnce`** (bounce; MotionBlurPreview)
  [obs]. Older files (formats 3.0/4.0) omit `interp` on keyframes and on the
  parameter; the default then is [?] (likely `eioe`).
- The parameter animates **from the previous value to `value` across
  `[time, endTime]`** and holds between keyframes [obs + inf].
  "Previous value" for the first keyframe is the parameter's `defaultValue`
  [inf, strong]: MediaMattePreview fades `opacity` from `defaultValue` 1.0 to
  0.0 over the single keyframe 27→47; MotionBlurPreview moves `translation0`
  from `defaultValue` −465 (off-canvas left) to 59 over 1→60 (a fly-in). With
  "value before first keyframe = first keyframe's value" the first clip would
  be invisible throughout, which makes no sense for a preview.
- After the last keyframe the last `value` holds [inf].
- `defaultValue` of an animated parameter can lie outside the range of its
  keyframe values (BlendModePreview `translation0`: default −24.48, keyframes
  −68, −28.48, −55, −68) [obs]; it is not "the value at the playhead".

### Time base: **media time, not timeline offset**

Keyframe `time`/`endTime` are on the clip's **inner (media) time axis** — the
same axis as `mediaStart` — not relative to the clip's `start` [obs]:

- BlendModePreview callouts: `start` 0, `duration` 120, **`mediaStart` 22**
  (left edge trimmed by 22 frames). Their keyframes run from 0 to **142** and
  their `animationTracks.visual` segments end at **142 = mediaStart +
  duration**, not 120. The visible part is media time 22…142; the 0→17
  keyframes sit in the trimmed-off part.
- 12 keyframes in that project have `endTime > duration` and all have
  `endTime ≤ mediaStart + mediaDuration` [obs].

So for a clip with `scalar` 1:

```
keyframe_time(t) = inner(c, t) = c.mediaStart + (t − c.start)
```

This differs from the current contract ("relative to the clip's own start")
whenever `mediaStart ≠ 0`, i.e. after any left-edge trim.

Open points:
- **With speed ≠ 1** the base could be `inner(c, t)` (media time) or
  `mediaStart + (t − start)` (timeline offset). No keyframed sped-up clip
  exists in the corpus [?]. Use `inner(c, t)` until experiment X4 decides.
- **Images** (`mediaStart` 0, `mediaDuration` 1) keep keyframes beyond 1 tick,
  so for them the base is `t − start` plus `trimStartSum` [inf]
  (`trimStartSum` is 0 in all 16 images; we believe it accumulates left-edge
  trims for images, which have no media time) [?].
- **Groups / stitched / unified** — no keyframes on these in the corpus; use
  the same rule on the clip that owns the parameter (for unified: the
  `video` child) [inf].

### `animationTracks.visual`

- Entries `{endTime, duration, range: [start, length], interp?}` with
  `endTime == range[0] + range[1]` and `duration == range[1]` (36 / 36) [obs].
- Every numeric keyframe window `(time, endTime)` of the clip — on clip
  parameters **and** on effect parameters (e.g. `BlendModeEffect.intensity`) —
  equals one of these entries (118 / 118) [obs].
- So `animationTracks.visual` is the list of animation segments ("arrows" on
  the clip in the UI); parameters keyframed by a segment carry a keyframe with
  the same window [inf]. A renderer can ignore `animationTracks` and evaluate
  the keyframes alone [inf]. An editor must keep both in sync when it moves or
  trims animations [inf].
- An entry's `interp` matches the interp of the keyframes in its window in
  most cases; when parameters in the same window differ (BlendModePreview
  window 87→117 has `linr` on one callout's `translation0` and `eioe` on
  another), each keyframe's own `interp` wins [obs values; inf rule].

### Non-numeric keyframes

- `transcription` (dynamic captions): string values, zero-length windows,
  one per word [obs]; `captions` on the vlog's audio clip: objects
  `{text, textAttributes}` every 2822400000 ticks (4 s), first at time 0 while
  that clip's `mediaStart` is 787920000 [obs] — consistent with the media-time
  base.
- `CursorPath.cursorLocation`: `[x, y, 0]` points with zero duration [obs].
- `def.textAttributes` on callouts: one keyframe at time 0 [obs].

## 7. Effect time windows

- In format 10.0 (demo) no effect has `start`/`duration`: effects cover the
  whole clip [obs].
- Older samples carry windows on placeholder effects only: `dummy`
  (20/80 on a 120-frame clip; 564480000/2257920000 on a 2822400000 clip,
  which ends exactly at the clip end) and `flyIn` (0/88 = the whole 88-frame
  clip) [obs]. Their time base is the same as keyframes [inf; every case has
  `mediaStart` 0, so it cannot be told apart].
- `GenericBehaviorEffect` timing (`in`/`center`/`out` phases) is M4 work [?].

## 8. Missing key → value

| Key | Default | Tag |
|---|---|---|
| `scalar` | 1 | [obs: never missing, always written] |
| `mediaStart` | 0 | [inf] |
| `mediaDuration` | `duration / scalar` | [inf] |
| keyframe `interp` (no parameter-level `interp` either) | `eioe` | [?] |
| effect `start`/`duration` | whole clip | [obs] |

## 9. Experiments for the user

- **X4 — keyframes on a sped-up clip.** New project, import any video ≥ 20 s.
  Put a *Scale* animation on the clip from 5 s to 7 s (timeline time). Then
  right-click ▸ *Add Clip Speed*, set the speed to **2×**, and drag the clip's
  left edge right by about 2 s. Save `x4-speed-kf.cmproj`.
- **X5 — group inner time.** New project, two short clips on two tracks, group
  them, drag the group to start at 10 s, then drag the group's left edge right
  by 1 s. Save `x5-group-time.cmproj`.
- **X6 — image trim.** Import a still image, add a *Fade in* or any
  keyframed animation at its start, then drag its left edge right by 1 s.
  Save `x6-image-trim.cmproj` (expects a non-zero `trimStartSum`).
