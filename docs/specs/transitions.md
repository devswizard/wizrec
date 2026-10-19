# Spec: transitions

Behavioural spec for transitions: where they live in the project, the
catalog of names, their parameters, the window they occupy, and the inputs a
transition shader expects.

Black-box only. This spec records names, identifiers, types and counts. It
contains no shader code. Transition definition files are TechSmith content
and are never copied into the repo.

Tags: **[obs]** observed in files, **[inf]** inferred, **[?]** unknown.

## Evidence base

- **T1: MediaMattePreview** (bundle sample, format 4.0, `editRate` 30). This
  is the only project in the corpus with a non-empty `transitions[]`:
  - track 4 holds a single clip, `IMFile` 9 (start 0, duration 88);
  - `transitions[0]` = `{name: "RadialWipe", duration: 21, trivial: false,
    reverse: false, bypass: false, useAudioPreRoll: true,
    useVisualPreRoll: true, rightMedia: 9}`.
- **T2: GenericTransitionPreview.** Two images end to end (0–45 and 45–120)
  with **no** `transitions` key. Camtasia inserts the transition at run time
  to draw its preview tiles [inf].
- **T3: bundle resource names**, names only. There are preview movies and
  icons named after transitions, e.g. `RadialWipe.mp4` and
  `iconRadialWipe.png`.
- **T4: 148 `Transitions/*.tsceffect` files** in the bundle, read in place by
  a script that prints only keys, names, types and identifier lists.
- The user's demo and vlog projects have no transitions [obs].

## 1. Where transitions live

```
track = { trackIndex, medias[], transitions[]?, parameters }
transition = {
  name:              string    "RadialWipe" (§3)
  duration:          ticks     length of the transition window
  leftMedia?:        clip id   the clip that ends at the transition point (outgoing)
  rightMedia?:       clip id   the clip that starts at the transition point (incoming)
  trivial:           bool
  reverse:           bool
  bypass:            bool
  useAudioPreRoll:   bool
  useVisualPreRoll:  bool
  attributes?:       {…}       expected for parameterised shader transitions [?]
}
```

- **Track level.** Transitions sit on the track, beside `medias[]`, not on
  the clips [obs, T1]. A track with no transitions omits the key [obs].
- **Ids.** `leftMedia` and `rightMedia` hold clip `id`s on the same track
  [obs]. When an edit renumbers ids, both must be remapped with the clips
  [inf].
- **Sides.**
  - Only `rightMedia`: the transition is at the **start** of that clip, a
    "transition in" [obs, T1: clip 9 starts at 0 and nothing precedes it].
  - Only `leftMedia`: the transition is at the **end** of that clip [inf, by
    symmetry].
  - Both: the transition sits at the cut between two adjacent clips [inf].
- `duration` uses the project's `editRate` [obs: 21 ticks at `editRate` 30
  = 0.7 s].

## 2. Timing

| Case | Window | Tag |
|---|---|---|
| Only `rightMedia` (clip starts at S) | `[S, S + duration)` | [inf, strong] T1: S = 0 and the window cannot start before the timeline |
| Only `leftMedia` (clip ends at E) | `[E − duration, E)` | [inf] |
| Both, cut at C | **[?]** Either centred, `[C − d/2, C + d/2)`, or wholly after/before the cut. Experiment TR1 | [?] |
| Progress inside the window | `p = (t − windowStart) / duration`, from 0 to 1, linear in time | [inf] Any easing lives inside each transition |

Working rule for the both-sides case, until TR1 is done [inf]: the window is
**centred on the cut**. The outgoing clip keeps playing its media past its
own end (`mediaStart + mediaDuration`), and the incoming clip starts showing
`d/2` before its `start`, rewinding its media by `d/2`. This is the usual NLE
model, and it is why Camtasia warns about clips that lack extra media at the
ends [inf]. Images, callouts and shader sources never run out of media.
Freeze video at its first or last frame if a handle is missing [inf].

### Flags

| Key | Values seen | Meaning |
|---|---|---|
| `trivial` | false | [?]. Possibly "no visual content", like an audio-only fade [inf, weak] |
| `reverse` | false | Plays the transition backwards (p → 1 − p) or mirrors its direction [inf, weak] |
| `bypass` | false | When true, the transition is disabled and the cut is hard [inf, by analogy with `bypassed` on effects] |
| `useVisualPreRoll` | true | Whether the incoming clip shows pre-roll frames, i.e. media before its `mediaStart`, during the window rather than freezing [inf, weak]. Experiment TR1 |
| `useAudioPreRoll` | true | The same choice for audio [inf, weak] |

## 3. Name catalog

There are two families.

### 3.1 Classic transitions (named in the project directly)

- **Observed in a project:** `RadialWipe` [obs, T1].
- **Rest of the family.** Each name below has a matching `<Name>.mp4` preview
  and `icon<Name>.png` in the bundle. The project `name` is assumed to equal
  that base name, as it does for `RadialWipe` [inf]:

  `BarnDoor`, `Blinds`, `CheckerBoard`, `CircleReveal`, `CircleStretch`,
  `CubeRotate`, `Dissolve`, `Fade`, `FadeThroughBlack`, `Flip`, `Fold`,
  `GlowTransition`, `GradientWipe`, `Inset`, `Iris`, `PageRoll`, `PageTurn`,
  `RadialBlur`, `RadialWipe`, `RandomBars`, `RandomDissolve`, `Ripple`,
  `SlideLeft`, `SlideRight`, `SphericalSpin`, `Spiral`, `Stretch`, `Strips`,
  `Wheel`, `ZigZag`.

- **Unclear family:** `Pixelate` and `Mosaic` could be transitions or visual
  effects [?]. `Glow` is the visual effect and `GlowTransition` the
  transition [inf].
- **Classic transitions carry no parameters in the project** [obs, T1]. Their
  look must come from reference renders (TR2).

### 3.2 Shader transitions (`.tsceffect`, type `"transition"`)

Each file is a JSON object with these keys [obs, T4]:

| Key | Meaning |
|---|---|
| `name` | CamelCase identifier, e.g. `Accordion`, `CardFlip` |
| `localizedName` | `{lang: display name}` |
| `type` | Always `"transition"` |
| `category` | One of `wipes` (26), `divisions` (25), `solids` (21), `splits` (18), `blurs` (17), `fades` (15), `radial` (12), `3d` (10) |
| `version` | `"1.0"`, `"2.0"`, `1.0` or `2.0` (string or number) |
| `attributes` | Parameter definitions, present in 93 of 144 (§4) |
| `code` | The transition's fragment shader (§5) |

- **Lenient parsing.** 4 files (`likesnloves`, `smileys`, `spinflip`,
  `transmission`) are not strict JSON: they write numbers with a trailing dot
  such as `8.` [obs]. A reader must accept that.
- **How a project refers to one** is [?]: by `name`, by file name, or by
  path. No project in the corpus uses a shader transition. Experiment TR3.
  Working assumption: `transition.name` = the file's `name` field [inf].

The catalog, by category (`name` field):

| Category | Names |
|---|---|
| wipes | ActionWipe, AngledLineWipe, Arrows, BarWipe, Bounce, CascadingSquares, ColorWipe, DistortedFall, Drop, ExpandingSquares, Fan, FourColorWipe, HitchPush, JaggedWipe, LineWipe, PaintArcs, PaintDrip, PaintStrokes, PaintSwipe, PrismWipe, Push, Shockwave, Shutters, SlantShutters, Tile, WalkingWipe |
| divisions | AnimatedMosaic, Bubbles, Bubbles2, CellZoom, Circles, Diamonds, Digital, Drops, Fall, GridFlip, Hexagonalize, Hexagons, HexMagnify, ImplodingHexagons, ImplodingSquares, PerlinBlobs, Puzzle, RandomSquares, RhombusDots, RoundedSquares, Shatter, ShuffleSlice, SquareDrops, SquarePops, SquaresRotateAway |
| solids | AngledSliders, ArrowSlice, ArrowsSolid, BoxIris, BurstingHeart, Chevrons, CircleBloom, ColorSpinDoor, FallingHearts, FourColorIris, FourSquares, GrowingSquares, HeartFlips, HeartPops, RollingSquares, ShiftingHearts, ShutterSnap, SlidingTriangles, SpinningColorWipe, Waves, Waves2 |
| splits | Accordion, Bars, CenterSlice, CircleSlice2, DiagonalSlice, Drawbridge, FoldShut, GeometricSlice1, GradientDoor, Interference, InwardSlice, Noise, PurpleTriangles, QuarterSplit, SlamShut, SlidingBars, SpinningBlinds, Unfold |
| blurs | BlurOffset, BlurSlide, BlurSpin, BlurStretch, BlurStretch2, BlurZoom, CrossZoom, DiagonalMove, Flashback, HeartOffset, SimpleZoom, SmoothSlide, Spin, SpinView, SpinView2, ZoomBlur, ZoomIn |
| fades | BurnThroughFade, ColorBurn, ColorDistance, Flare, Flare2, Glitch, Glitch2, Glitch3, LinearBlur, LuminanceFadeIn, LuminanceFadeOut, Morph, MultiplyBlend, Static, ZoomFade |
| radial | Blob, Blob2, Burn, CircleCrop, CircleOffset, ConcentricRings, DialWipe, HexSpinCascade, OpacitySquares, Portal, SwirlSpin, Vortex |
| 3d | CardFlip, CardFlipSwap, CardSlide, CardSwap, Cube, Doorway, InvertedPageCurl, SnapShot, Swap, Swing |
| unparsed (strict JSON) | likesnloves, smileys, spinflip, transmission: file names only |

The file name is the lower-cased `name`, except `spinviews` → `SpinView` and
`spinviews2` → `SpinView2` [obs].

## 4. Shader-transition parameters (`attributes`)

Each entry has `{name, type, …}` [obs, T4: 219 entries]:

| `type` | Count | Fields | Uniform |
|---|---|---|---|
| `double` | 108 | `defaultValue`, `minValue`, `maxValue` | `float _<name>` |
| `bool` | 39 | `defaultValue`, `minValue: false`, `maxValue: true` | **`float _<name>`** (0 or 1) |
| `Color` | 72 | `value`: a 6-hex-digit RGB string | **`vec3 _<name>`**, with no alpha (unlike backgrounds, which use `vec4`) |

- **Hints:** `userInterfaceType: "directional"` (46 entries) and `unitType`
  `"radians"` (12) or `"percentage"` (4) [obs].
- **Common names:** `Number` (39), `Random` (30), `FlipX` (23), `Color0` and
  `Color1` (21 each), `Angle` (16), `Color` (14), `FlipY` (14), `Width` (7),
  `Color2` (7), `Color3` (6), `Depth` (5) [obs].
- **In a project**, these probably appear under the transition object, as
  `attributes` or `parameters`, with colours split into `-red/-green/-blue`
  as on `SourceEffect` [?]. Experiment TR3.

## 5. Shader-transition host inputs

These names are used in transition code without being declared, so the host
provides them [obs, T4: counts out of 144 parsed files]:

| Name | Files | Meaning |
|---|---|---|
| `_Progress` | 144 | Transition progress from 0 to 1 (§2) |
| `_TexCoord` | 144 | Normalised frame position, the same convention as backgrounds: top-left origin, y down (`shader-backgrounds.md` §2) [inf] |
| `_FragColor` | 143 | Output colour |
| `_ImageSize` | 110 | Output size in pixels [inf] |
| `textureA(vec2 uv)` | 143 | Returns the **outgoing** (left) clip's colour at normalised position `uv` |
| `textureB(vec2 uv)` | 143 | Returns the **incoming** (right) clip's colour at normalised position `uv` |

How A and B are known: 10 files end with a plain blend from A toward B.
In the 3 of them whose blend weight is `_Progress` itself, or a smoothstep
that rises with `_Progress`, the weight goes from 0 to 1 as progress does
[obs]. So progress 0 shows A only and progress 1 shows B only, which makes A
outgoing and B incoming [inf, strong]. Two files call `getFromColor` and
`getToColor` instead, with the same meaning. These names come from the
common open "from/to" transition convention, and the host should provide
both pairs [obs names; inf meaning].

Coordinates passed to `textureA`/`textureB` may fall outside [0, 1].
Treat outside as transparent [inf; see TR2]. No sampler uniforms are declared
[obs]: the host binds the two frames behind these functions.

## 6. One-sided transitions and fades

| Claim | Tag |
|---|---|
| In a one-sided transition, the missing side is **transparent**: the transition reveals lower tracks and does not draw black | [inf] `FadeThroughBlack` exists as a separate named transition, which implies that plain `Fade` does not go through black. A track-4 transition in T1 sits above three populated tracks. Experiment TR1 |
| Between two clips, `Fade` / `Dissolve` is a straight cross-dissolve: `out = mix(A, B, p)` | [inf] Experiment TR2 |
| `FadeThroughBlack`: A fades to black over the first half, then black fades to B | [inf, weak] Experiment TR2 |
| Composition: the transition's output replaces both clips for the duration of the window and is composited at the track's position in the stack | [inf] |

## 7. Experiments

These need Camtasia. For each, save into
`~/WorkDir/vibe_coding/camtasia_rea_refs/research/transitions/`.

- **TR1: window placement and one-sided fades.**
  1. New 1920×1080, 30 fps project. On track 2, put two long video clips
     end to end, cutting at 10 s. Put any image on track 1, under the full
     range, so transparency shows.
  2. Add `Fade` between the clips with a duration of 1.00 s.
  3. Add `Fade` to the start of the first clip only (transition in).
  4. Save as `tr1.cmproj`.
  5. Export frames 0–45 and 280–320 as MP4 (or the whole thing) to
     `tr1.mp4`.
- **TR2: classic looks.** In the same project, replace the middle transition
  with `FadeThroughBlack`, then `RadialWipe`, then `CubeRotate`. Save each
  as `tr2-<name>.cmproj`, with the playhead in the middle of the
  transition.
- **TR3: a shader transition in a project.**
  1. Add `Accordion` (Splits) between the clips.
  2. Change its *Number* parameter and set one colour.
  3. Save as `tr3.cmproj`.
