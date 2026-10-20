# Spec: behaviours (`GenericBehaviorEffect`)

Behaviours are preset animations ("Fly In", "Pop Up", "Pulsating" and so on)
attached to a clip. Each has an **in** phase, a looping **center** phase and
an **out** phase. This spec covers how they are stored and what can be
inferred about timing.

Black-box only. The corpus holds **a single behaviour instance**, so most of
the motion maths is [?] and waits on the experiments in §6.

Tags: **[obs]** observed in files, **[inf]** inferred, **[?]** unknown.

## Evidence base

- **B1: MediaMattePreview** (bundle sample, format 4.0, `editRate` 30,
  Camtasia 2020). `IMFile` 9 (start 0, duration 88) carries one
  `GenericBehaviorEffect` followed by a `MotionBlur` effect.
- **B2: GenericBehaviorPreview** (format 3.0). A text callout with **no**
  behaviour in `effects[]`, but with `metadata.effectApplied: "jumpAndFall"`.
  Camtasia applies the behaviour at run time to draw its preview tile [inf].
- **B3: bundle resource names**, names only. Preview movies and icons:
  `drifting`, `explode`, `fadeBehavior`, `flyin`, `jumpAndFall`, `popUp`,
  `pulsating`, `reveal`, `scale`, `shifting`, `sliding`, plus `BehaviorFX*`
  timeline-strip images.

## 1. Storage

A behaviour is an entry in the clip's `effects[]`. Unlike the visual effects,
it has no `category` and no `parameters` [obs, B1]:

```
{
  "_type": "GenericBehaviorEffect",
  "effectName": "flyIn",               preset id (§2)
  "bypassed": false,
  "start": 0, "duration": 88,          ticks, relative to the clip (§3)
  "in":     { "attributes": { …phase attributes… } },
  "center": { "attributes": { …loop attributes… } },
  "out":    { "attributes": { …phase attributes… } }
}
```

- **Identifying it.** `_type` is present only on behaviours among the
  effects seen, so readers must key on `_type == "GenericBehaviorEffect"`
  and not on `effectName` [obs].
- **Order.** The behaviour came first in `effects[]`, before `MotionBlur`
  [obs]. Whether order matters (does motion blur see the behaviour's motion?)
  is [?]. Apply behaviours before visual effects [inf].
- **Clip metadata** gets per-preset UI defaults, e.g.
  `default-Movement-flyIn: "0"` and `default-Speed-flyIn: "14.5"`. These are
  metadata only and never affect the render [inf, as for `default-scale`].

### Phase attributes (`in` and `out`)

[obs, B1]:

| Key | B1 `in` | B1 `out` | Meaning |
|---|---|---|---|
| `name` | `"none"` | `"flyOut"` | Which animation the phase plays. `"none"` means the phase is off |
| `type` | 0 | 0 | [?] Possibly a target: whole clip or per character |
| `characterOrder` | 6 | 6 | Order in which text characters animate (enum) [?] |
| `offsetBetweenCharacters` | 0 | 2 | Delay between successive characters [?]. Units are probably frames or ticks of `editRate` 30 here [inf, weak] |
| `suggestedDurationPerCharacter` | 0 | `"141071/10000"` (= 14.1071) | An exact rational string, so parse it as a time value. Units [?]. It is close to `default-Speed-flyIn` 14.5 [obs] |
| `overlapProportion` | 0 | `"1/4"` | Fraction by which character animations overlap [inf] |
| `movement` | -1 | 26 | Motion distance or style [?]. −1 = unused [inf] |
| `springDamping` | 5.0 | 5.0 | Spring model for the motion [inf] |
| `springStiffness` | 50.0 | 50.0 | Spring model [inf] |
| `bounceBounciness` | 0.45 | 0.45 | Bounce model [inf] |

### Loop attributes (`center`)

[obs, B1]:

| Key | B1 | Meaning |
|---|---|---|
| `name` | `"none"` | Loop animation, or `"none"` |
| `type`, `characterOrder`, `offsetBetweenCharacters` | 0, 6, 0 | As above |
| `secondsPerLoop` | 1 | Seconds per loop cycle [inf from name] |
| `numberOfLoops` | -1 | −1 = loop for as long as the center phase lasts [inf] |
| `delayBetweenLoops` | 0 | Pause between cycles, in seconds [inf] |

Numbers can be integers, doubles or `"p/q"` strings. Readers must accept all
three, as for time fields [obs].

## 2. Preset ids

- **Observed in projects:**
  - `flyIn` as `effectName`, with `flyOut` as an `out.name` [obs, B1];
  - `jumpAndFall` in `metadata.effectApplied` [obs, B2].
- **From bundle names**, as lower camel case [inf]: `drifting`, `explode`,
  `fadeBehavior` (or `fade`), `flyIn`, `jumpAndFall`, `popUp`, `pulsating`,
  `reveal`, `scale`, `shifting`, `sliding`. The exact `effectName` spelling
  of each is [?]: the resource is `flyin` while the project says `flyIn`.
- **Phase names.** `effectName` names the preset, while each phase's `name`
  names the animation that phase actually plays: `"flyOut"` in the out phase
  of `flyIn` [obs]. The in-phase name of a fresh `flyIn` is probably
  `"flyIn"`. In B1 it was switched off (`"none"`) [inf].

## 3. Timing

| Claim | Tag |
|---|---|
| `start`/`duration` give the behaviour's span in ticks, relative to the clip start (B1: 0/88 = the whole clip) | [obs values; axis inf, cf. effect `start`/`duration` in FORMAT.md] |
| The in phase runs at the start of the span, the out phase at the end, and the center phase loops between them | [inf, from names and UI] |
| How long the in and out phases last: derived from the per-character duration × the number of characters, with overlap, for text; something fixed for non-text clips | [?] Experiment BH1 |
| Behaviours drive transform and opacity on top of the clip's own keyframes. Composition (additive offset or multiplicative scale) is [?] | [?] Experiment BH2 |

## 4. Text callouts

`characterOrder`, `offsetBetweenCharacters` and `overlapProportion` make
sense only for text: behaviours animate a callout's characters one by one
[inf]. On media clips (B1 is an image) the per-character keys are ignored
[inf].

## 5. Implementation guidance (until experiments land)

1. Parse and preserve all keys (TSCProjKit already does).
2. Render the preset as an opacity fade over the phase durations: in = fade
   up, out = fade down, center = nothing. Mark it visually approximate.
3. Golden tests for behaviours wait for BH1/BH2 reference exports.

## 6. Experiments

Save into `~/WorkDir/vibe_coding/camtasia_rea_refs/research/behaviors/`.

- **BH1: phase timing.**
  1. New 1920×1080, 30 fps project. Add a plain text callout reading
     "ABCDE" at 0–5 s.
  2. Apply the behaviour **Fly In** with default settings.
  3. Save as `bh1-flyin.cmproj`, then export to `bh1-flyin.mp4`.
  4. Repeat with **Pop Up** and **Pulsating** (`bh1-popup`, `bh1-pulsating`).
- **BH2: media clip.**
  1. Put an image (any photo) at 0–5 s and apply **Fly In**.
  2. Change *In ▸ Movement* to a different value and *Speed* to the maximum.
  3. Save as `bh2-image.cmproj` and export `bh2-image.mp4`.

## Menu defaults (runtime save, 2026-10-20)

Source: automated runtime observation (DECISIONS 2026-10-20). Each behaviour
in *Modify ▸ Add Behavior* was added to its own 5 s grey still, and Camtasia
saved the project. Every value is **[obs]**.

- **Window.** Each behaviour is one `GenericBehaviorEffect` with `start` 0 and
  `duration` equal to the whole clip (5 s here).
- **Clip metadata.** The clip's `metadata.effectApplied` is set to the
  behaviour's `effectName`.
- **Phase attributes.**
  - The in and out phases carry `name`, `type` (0), `characterOrder`,
    `offsetBetweenCharacters` (ticks), `suggestedDurationPerCharacter`
    (ticks), `overlapProportion` (a number or an exact fraction string such
    as `"23/60"`), `movement`, `springDamping`, `springStiffness` and
    `bounceBounciness`.
  - The centre phase carries `name`, `type`, `characterOrder`,
    `offsetBetweenCharacters`, `secondsPerLoop` (a number or a fraction
    string), `numberOfLoops` (−1 means for the whole clip) and
    `delayBetweenLoops` (ticks).
- **Phase parameters.** A phase may also have `parameters`. These are
  either:
  - int enums with `valueBounds` and `uiHints`, plus one keyframe at time 0
    holding the value; or
  - doubles with `defaultValue`, `valueBounds` and `uiHints`. Here
    `unitType` 1 is a percentage or factor, and 3 is radians [inf from the
    values].
- **Spring and bounce.** The spring values are 5.0 / 50.0 / 0.45 for every
  behaviour except: Shifting-in uses damping 7.0, and Jump & Fall-in uses
  bounciness 0.4.
- **Values in the table.**
  - "per-char" and "offset" are converted to seconds.
  - "order" is `characterOrder`.
  - Parameter values follow the phase.

| Menu | `effectName` | In phase | Centre phase | Out phase |
|---|---|---|---|---|
| Drifting | `drifting` | `drifting`: movement 17, per-char 1.25 s, overlap 0, order 6, offset 0.05 s; direction 3 | `drifting`: loop 4 s, delay 0 s, order 6, offset 0.03333 s; movement 17 | `drifting`: movement 7, per-char 1 s, overlap 23/60, order 6, offset 0.03333 s; direction 1 |
| Explode | `explode` | `implode`: movement 0, per-char 0.7333 s, overlap 0, order 4, offset 0 s | `none`: loop 1 s, delay 0 s, order 6, offset 0 s | `explode`: movement 0, per-char 0.7333 s, overlap 0, order 4, offset 0 s |
| Fade | `fade` | `fadeIn`: movement 0, per-char 1 s, overlap 0, order 6, offset 0.05 s | `none`: loop 1 s, delay 0 s, order 6, offset 0 s | `fadeOut`: movement 0, per-char 1 s, overlap 0, order 6, offset 0.05 s |
| Fly In | `flyIn` | `flyIn`: movement 0, per-char 0.6 s, overlap 1/4, order 6, offset 0.06667 s | `none`: loop 1 s, delay 0 s, order 6, offset 0 s | `flyOut`: movement 0, per-char 0.4833 s, overlap 1/4, order 6, offset 0.06667 s |
| Jump & Fall | `jumpAndFall` | `bounceIn`: movement 29, per-char 0.75 s, overlap -1/5, order 6, offset 0.08333 s; direction 1 | `jump`: loop 1 s, delay 1.667 s, order 6, offset 0.08 s; jump 60.0 | `drop`: movement 7, per-char 0.5 s, overlap 1/5, order 6, offset 0.08333 s; direction 3 |
| Pop Up | `popUp` | `hinge`: movement 30, per-char 2.45 s, overlap 1/3, order 6, offset 0.05 s; direction 3 | `popUp`: loop 1 s, delay 0 s, order 6, offset 0.17 s; direction 3, movement 27, rotation 0.279252680319093 | `hinge`: movement 7, per-char 0.6667 s, overlap 1/2, order 6, offset 0.05 s; direction 3 |
| Pulsating | `pulsating` | `grow`: movement 30, per-char 0.6 s, overlap 3/4, order 6, offset 0.03333 s | `pulsate`: loop 1 s, delay 0 s, order 6, offset 0.07 s; movement 27, scale 1.08 | `shrink`: movement 11, per-char 0.4833 s, overlap 1/10, order 6, offset 0.03333 s |
| Reveal | `reveal` | `reveal`: movement 16, per-char 0.7333 s, overlap 0, order 7, offset 0.05 s; direction 0 | `reveal`: loop 233/100 s, delay 0.5 s, order 2, offset 0.17 s; movement 0, opacity 0.45 | `reveal`: movement 6, per-char 0.5667 s, overlap 1/2, order 7, offset 0.05 s; direction 2 |
| Scale | `scale` | `grow`: movement 30, per-char 0.6 s, overlap 3/4, order 6, offset 0.03333 s | `none`: loop 1 s, delay 0 s, order 6, offset 0 s | `shrink`: movement 11, per-char 0.4833 s, overlap 1/10, order 6, offset 0.03333 s |
| Shifting | `shifting` | `shifting`: movement 30, per-char 1.517 s, overlap 0, order 4, offset 0.02 s | `shifting`: loop 317/100 s, delay 0 s, order 3, offset 0 s; movement 12, shift 5.0 | `shifting`: movement 14, per-char 0.4333 s, overlap 1/2, order 4, offset 0.03333 s |
| Sliding | `sliding` | `sliding`: movement 16, per-char 1 s, overlap 11/20, order 7, offset 0.05 s; direction 0 | `fading`: loop 2 s, delay 0 s, order 6, offset 0.08 s; movement 0, opacity 0.65 | `sliding`: movement 8, per-char 1 s, overlap 11/20, order 7, offset 0.05 s; direction 2 |
| Tremble | `tremble` | `none`: movement -1, per-char 0 s, overlap 0, order 6, offset 0 s | `tremble`: loop 4/5 s, delay 0 s, order 0, offset 0 s; horizontal 6.0, rotation 0.0174, vertical 2.0 | `none`: movement -1, per-char 0 s, overlap 0, order 6, offset 0 s |
| Wiggle | `wiggle` | `none`: movement -1, per-char 0 s, overlap 0, order 6, offset 0 s | `wiggle`: loop 100000 s, delay 0 s, order 0, offset 0 s; frequency 1.0, nuance 1.0, offsetX 10.0, offsetY 10.0, rotation 0.0, scale 0.0 | `none`: movement -1, per-char 0 s, overlap 0, order 6, offset 0 s |

Notes:

- **Name ≠ menu text.** The menu item *Scale* writes `effectName` `scale`
  with `grow`/`shrink` phases. *Pop Up* writes `popUp` with `hinge` phases,
  not bounce [obs].
- **"Nothing" phases.** Tremble and Wiggle have in and out phases named
  `none`, with `movement` −1 [obs]. Explode, Fade, Fly In and Scale have a
  centre named `none`, with loop 1 s [obs].
- **Wiggle loop.** Wiggle's centre has `secondsPerLoop` 100000, so in
  practice it never loops [obs].
- **Durations.** The rendered in/out duration of each phase on a still is
  [?]. It needs a render, and exports are blocked by the trial watermark.
