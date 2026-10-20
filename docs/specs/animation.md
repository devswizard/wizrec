# Spec: animations (menu animations, keyframe shape, `animationTracks`, `eioe`)

How Camtasia 2026.2.3 writes clip animations.

Source: automated runtime observation (DECISIONS 2026-10-20, ledger RT-004
and RT-007). Camtasia added each *Modify ▸ Add Animation* item to its own
clip with the playhead parked inside the clip, then saved. The saves were
diffed.

The `eioe` curve fit (research backlog item 2) is **still open**. It needs
reference renders, and Camtasia's export is behind a trial-watermark gate
(RT-001).

Tags: **[obs]** seen in Camtasia's saved files, **[inf]** inferred,
**[?]** unknown.

## 1. Where a menu animation lands in time

- **Fixed placement.** An animation added from the menu is one keyframe
  segment, 1 s long, that **ends at the playhead** [obs]:
  - With the playhead 0.5 s into a clip, the keyframe has `time` −0.5 s,
    `endTime` +0.5 s and `duration` 1 s, all in ticks on the clip's time
    axis.
  - With the playhead 1 s into a clip, it runs 0 → 1 s [obs].
- **Negative times are legal.** A keyframe may start before the clip's
  start, so readers must accept a negative `time` [obs].
  - At clip time 0 such a segment is already part-way through.
  - The value at time 0 follows from evaluating the segment, not from
    `defaultValue` [inf, consistent with `time-mapping.md` §6].
- **No `interp` key.** The keyframe has no `interp`, and the parameter
  object has none either [obs].
  - This differs from keyframes in user projects, which carry
    `interp: "eioe"` (or `linr`) on each keyframe.
  - The curve used when the key is absent is [?]. Until a render says
    otherwise, treat a missing `interp` as `eioe`, Camtasia's default for
    new animations [inf].
- **`animationTracks`.** The clip gets one `animationTracks.visual` entry
  per animation, with `endTime` and `duration` (ticks) matching the segment
  [obs].
  - These entries have **no** `range` or `interp` keys, unlike the entries in
    user projects [obs].
  - Several parameters animated by one menu item share a single
    `animationTracks` entry [obs].

## 2. What each menu animation animates

All values are the end value of the 1 s segment. Each starts from the
parameter's value before the animation (`defaultValue`) [obs].

| Menu item | Parameters and end values |
|---|---|
| Custom | No parameter change. Only the `animationTracks` entry is added (an empty animation to edit later) |
| Restore | Same as Custom on an untransformed clip [obs]. The general rule (animate back to the identity) is [inf] |
| No Opacity | `opacity` 1 → 0 |
| Full Opacity | `opacity` → 1; the starting `defaultValue` is set to 0 [obs] |
| Scale Up | `scale0`, `scale1` → 1.25 |
| Scale Down | `scale0`, `scale1` → 0.75 |
| Scale To Fit | `scale0`, `scale1` → 2.7 for a 400×400 still on a 1920×1080 canvas, i.e. 1080 / 400 [obs]. The value fits the height |
| Tilt Left | `translation0` → −480, `rotation1` → +π/6, `scale0`/`scale1` → 0.5 |
| Tilt Right | `translation0` → +480, `rotation1` → −π/6, `scale0`/`scale1` → 2.4 on the 400 px still [obs]. The scale formula is [?] |
| SmartFocus, SmartFocus at Time | No change on a synthetic clip [obs]. These probably need a screen recording with cursor data [inf] |

- **Parameter form.** Animated parameters are written in the long form
  (`type`, `defaultValue`, `keyframes`), with no top-level `interp` [obs].

## 3. Trimming and animations

- **Image trim-start (X6).** Trimming a still's start by 1 s after a 0 → 1 s
  Full Opacity animation changes three things [obs]:
  - the clip `start` increases by 1 s;
  - `duration` decreases by 1 s;
  - `trimStartSum` grows by 1 s, while `mediaStart` stays 0.
- **Keyframes are not moved or pruned.** The keyframe still runs 0 → 1 s and
  `animationTracks` is unchanged [obs]. Keyframe times on a still are
  therefore measured from the clip's original, untrimmed start. In other
  words, keyframe time equals the time since the visible start plus
  `trimStartSum` [inf, strong]. After this trim the fade is already
  complete when the clip appears.

## 4. `eioe` curve

- **[?]** Fitting the curve needs `keyframes-eioe/reference.mp4`, a
  Camtasia export.
  - Export is gated by the trial watermark (RT-001).
  - Camtasia's saved `ProjectThumbnail` cannot replace the export: by lead
    decision it is not to be used as a substitute golden reference.
- Until then, WizRec keeps its provisional curve.
