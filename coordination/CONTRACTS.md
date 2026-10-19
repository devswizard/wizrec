# Contracts — M1

Public interfaces between modules. The **code is the contract**: each module's
`Sources/<Module>/Contract.swift` holds the frozen public types and signatures
(stub bodies compile today). This file states the semantics the signatures
can't. Changing either needs an `API_CHANGE <module>` message to the lead and
every dependent, and the lead's approval, before the change merges.

Dependency graph (no cycles):

```
TSCProjKit ◄── MediaEngine ◄── RenderEngine ◄── WizRecApp
     ▲               ▲  (CFFmpeg)                  │
     └──── TimelineEngine ◄────────────────────────┘
```

## Shared rules

- **Ownership.** Each agent edits only its own paths (see `BOARD.md`).
  `Package.swift` is lead-owned: an agent may add dependencies, resources or a
  new target *for its own module* and must list the change in its `REVIEW`
  message.
- **TSCProjKit** is shared. Changes are additive only (new members, no
  behaviour change to existing ones), announced with `API_CHANGE TSCProjKit`.
  The lossless round-trip tests must stay green. Never serialise a project any
  other way.
- **Concurrency.** Swift 6 language mode. `Project` and TSCProjKit types are
  not `Sendable` and live on the main actor. Everything crossing to the render
  or decode side is a value type (`SceneModel`, `RenderPlan`, `FrameRequest`).
  `@unchecked Sendable` only with a justifying comment.
- **Units.** Timeline and clip times are project ticks (`Int64`, or
  `Rational` after speed changes). Stream times are `CMTime`. Convert at the
  boundary with `CMTime(value: ticks, timescale: Int32(editRate))` when
  `editRate` fits `Int32` (705600000 does); round rational ticks to the nearest
  tick.
- **Test data.** Never vendor user media. Tests that read
  `~/Documents/demo project.cmproj` (or the vlog) skip when it is missing.
  Synthesise media in tests (AVAssetWriter / `ffmpeg -f lavfi`) instead.

## MediaEngine (`Sources/MediaEngine/Contract.swift`)

| API | Semantics |
|---|---|
| `MediaPool.probe(url)` | Stream metadata, no frame decode. `.trec` → `.recording`, `.tscshadervid` → `.shader` (no streams needed). |
| `MediaPool.source(for:)` | One open `MediaSource` per URL, reused. |
| `MediaSource.frame(stream:at:)` | Frame on screen at stream time *t* = last frame with PTS ≤ *t*. VFR streams (tscc2 is VFR, ~5 fps avg) hold the previous frame. Clamp *t* to the stream. Frame-accurate: a seek to any *t* returns the same frame as sequential decoding would. |
| Stream time origin | 0 = first sample of that stream (container PTS offsets / edit lists removed) [inf — `format` verifies]. |
| Stream index | Container order; equals a clip's `trackNumber` and the order of the source's `sourceTracks` [inf]. For the demo `.trec`: 0 = tscc2 screen, 1 = h264 camera, 2 = aac. |
| `VideoFrame.pixelBuffer` | `32BGRA`, IOSurface-backed, `kCVPixelBufferMetalCompatibilityKey`. Never mutated after publish. |
| `MediaSource.audio` | Float32 non-interleaved, resampled to the requested `PCMFormat`, silence-padded outside the stream. |
| `MediaPool.frame(_:)` | LRU cache keyed by `FrameRequest` *after* snapping to the frame's PTS (two requests landing on the same frame share one entry). Budget `cacheLimitBytes`. |
| `MediaPool.prefetch` | Non-blocking pre-roll; later `frame(_:)` calls hit the cache. |
| Images | `frame(stream: 0, at: any)` returns the image as a single frame. |
| Decoders | AVFoundation (`AVAssetReader`) for h264/hevc/prores/aac; libavcodec via `CFFmpeg` for `tscc2` and anything AVFoundation rejects. |
| Performance | 1080p h264 sequential decode ≥ 120 fps; random seek ≤ 50 ms on Apple silicon. |

## RenderEngine (`Sources/RenderEngine/Contract.swift`)

**`SceneModel(project:resolve:)`** projects the project into immutable value
types once (rebuild after each edit). **`evaluate(at:)`** is pure.

Time mapping, per clip, from the parent's time *t* (ticks):

- Visible when `start ≤ t < start + duration`.
- Local media time `m = mediaStart + (t − start) × scalar` (exact `Rational`).
- `Group`: children are evaluated at `m` on the group's inner timeline.
- `StitchedMedia`: the segment containing `m` (segment `start` relative to the
  stitched clip's inner timeline, per FORMAT.md) is evaluated with the same
  rule, recursively.
- `UnifiedMedia`: the `video` child is the visual layer (its `clipID`); the
  `audio` child becomes an `AudioSegment`.
- Leaf video clip: `FrameRequest(url, stream: trackNumber, time: m → CMTime)`.
- Keyframe times are relative to the clip's own `start` [inf]; evaluate with
  `Parameter.value(at:)` (eioe ≈ smoothstep until `docs/specs/animation.md`).

Layer geometry (pending `docs/specs/transform.md` from `format`):

- `size` = source `rect` w×h (video/image), group `widthAttr`/`heightAttr`.
- `transform` = translate(`translation0`, `translation1`) · rotate(`rotation2`)
  · scale(`scale0`, `scale1`), canvas px, origin centre, **+y up** [inf:
  translation1 < 0 places the demo camera bottom-right].
- `geometryCrop0..3` = left, top, right, bottom fractions [inf].
- Missing parameter → Camtasia default (scale 1, opacity 1, crop 0).
- `background` = `timeline.backgroundColor` / 255.
- Tracks bottom → top = `trackIndex` ascending; hidden tracks
  (`trackAttributes[i].videoHidden`) are skipped.
- Effects are evaluated into `EffectInstance`s but not drawn in M1.
- `.tscshadervid` → `.shader(url, parameters)`; M1 compositor draws a fallback
  (four-colour gradient from `Color0..3`) until M4.

**`Compositor.encode`**: premultiplied-alpha source-over in sRGB, layers in
order; group content with non-identity crop or opacity < 1 is drawn to an
offscreen texture first. Canvas scales uniformly to fit `target`, letterboxed
with `background`. Metal shaders are compiled at runtime from Swift source
strings (`device.makeLibrary(source:)`) so `swift build` needs no Metal
toolchain. Frames enter via `CVMetalTextureCache` (zero-copy).

**`OfflineRenderer.image(at:size:)`**: evaluate → `pool.frame` for every
`frameRequests` entry → composite → `CGImage` (sRGB, 8-bit). Deterministic.

Performance: `evaluate` < 0.5 ms for the vlog project; composite 1080p60
with ≤ 8 layers in < 4 ms GPU time.

## TimelineEngine (`Sources/TimelineEngine/Contract.swift`)

- `EditCommand` is `@MainActor`; `apply` either fully succeeds or throws with
  the project untouched; `revert` restores the exact prior JSON (same keys,
  order and number lexemes). Store the replaced subtrees via `JSON.copy()`.
- `UndoStack` (`@Observable`): `perform` clears redo; `changeCount` bumps on
  every change.
- M1 commands: `SplitClip(clipID:at:)`, `TrimClip(clipID:edge:to:)`,
  `MoveClip(clipID:toTrack:start:)`. New ids are allocated above
  `Project.maxID`. Tests compare resulting JSON against expected JSON.

## App (wave 2)

Consumes the above only. `NSDocument` for `.cmproj`; canvas is an `MTKView`
driven by the display link; audio via `AVAudioEngine` from
`audioSegments` + `MediaSource.audio` as the master clock.
