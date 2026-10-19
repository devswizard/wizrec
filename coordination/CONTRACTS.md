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
| Stream time origin | Movie presentation timeline: edit lists applied, AAC priming (2112 samples when no edit list says otherwise) removed — AVFoundation semantics [obs, `docs/specs/media-streams.md`]. Don't subtract ffprobe `start_time`. |
| Stream index | Position among the file's **audio/video streams only** (data/tmcd tracks and attached cover pictures skipped), in container order; equals a clip's `trackNumber` and the index into `sourceTracks` [obs]. Demo `.trec`: 0 = tscc2 screen, 1 = h264 camera, 2 = aac. |
| Colour | tscc2 is untagged: decode as **BT.601 limited range** [obs, vs Camtasia thumbnail]. Tagged streams follow their tags. Output sRGB. |
| `VideoFrame.pixelBuffer` | `32BGRA`, IOSurface-backed, `kCVPixelBufferMetalCompatibilityKey`. Never mutated after publish. |
| `MediaSource.audio` | Float32 non-interleaved, resampled to the requested `PCMFormat`, silence-padded outside the stream. |
| `MediaPool.frame(_:)` | LRU cache keyed by `FrameRequest` *after* snapping to the frame's PTS (two requests landing on the same frame share one entry). Budget `cacheLimitBytes`. |
| `MediaPool.prefetch` | Non-blocking pre-roll; later `frame(_:)` calls hit the cache. |
| Images | `frame(stream: 0, at: any)` returns the image as a single frame. |
| Decoders | AVFoundation (`AVAssetReader`) for h264/hevc/prores/aac; libavcodec via `CFFmpeg` for `tscc2` and anything AVFoundation rejects. |
| Performance | 1080p h264 sequential decode ≥ 120 fps; random seek ≤ 50 ms mean for ≤ 1080p h264; ≤ 150 ms mean for long-GOP all-reference HEVC ≥ 1.5K (revised 2026-10-19, measured: DJI 2.7K 10-bit 115 ms). |
| Prefetch | One ordered lane per stream; a new `prefetch` call replaces that stream's unstarted requests. |

## RenderEngine (`Sources/RenderEngine/Contract.swift`)

**`SceneModel(project:resolve:)`** projects the project into immutable value
types once (rebuild after each edit). **`evaluate(at:)`** is pure.

Time mapping, per clip, from the parent's time *t* (ticks):

- Visible when `start ≤ t < start + duration`.
- Local media time `m = mediaStart + (t − start) / scalar` (exact `Rational`).
  `scalar = 1/speed`: `mediaDuration × scalar = duration` [obs, vlog; fixed
  2026-10-19, see DECISIONS]. `Clip.mediaTime(atTimeline:)` implements this.
- `Group`: children are evaluated at `m` on the group's inner timeline.
- `StitchedMedia`: the segment containing `m` (segment `start` relative to the
  stitched clip's inner timeline, per FORMAT.md) is evaluated with the same
  rule, recursively.
- `UnifiedMedia`: the `video` child is the visual layer (its `clipID`); the
  `audio` child becomes an `AudioSegment`.
- Leaf video clip: `FrameRequest(url, stream: trackNumber, time: m → CMTime)`.
- **Published spec: `docs/specs/time-mapping.md`** (wins over this summary).
- Keyframe time base is the clip's **media time**: `mediaStart + (t − start)`
  for scalar 1 [obs], `inner(c, t)` for sped-up clips until experiment X4.
  First keyframe animates from `defaultValue`. Evaluate with
  `Parameter.value(at:)` (eioe ≈ smoothstep until `docs/specs/animation.md`;
  `bnce` exists, treat as linear in M1). `animationTracks` can be ignored by
  the renderer.
- `UnifiedMedia` children have the parent's `start`; evaluate them at the
  parent's track time with their own fields.

Layer geometry (**published spec: `docs/specs/transform.md`** — it wins over this summary):

- `size` = `sourceTracks[trackNumber].trackRect` w×h for video [obs], source
  `rect` for images, group `widthAttr`/`heightAttr`.
- `transform` = translate(`translation0`, `translation1`) · rotate(`rotation2`)
  · scale(`scale0`, `scale1`), canvas px, origin centre, **+y up** [obs,
  checked against Camtasia's ProjectThumbnail]. `rotation2` in radians [obs].
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

---

# Contracts — M2+ (wave A, 2026-10-19)

Same rules as above. New frozen stubs: `Sources/TimelineEngine/ContractM2.swift`,
`Sources/TSCProjKit/BundleWriting.swift`, `Sources/TimelineUI/Contract.swift`,
`Sources/Recorder/Contract.swift`. `AudioEngine`, `Exporter`, `Captions` are
placeholder targets until wave B writes their contracts.

```
TSCProjKit ◄─ TimelineEngine ◄─ TimelineUI ◄─┐
     ▲              ▲                          ├─ WizRecApp (+ PlayerKit)
     ├─ MediaEngine ◄─ RenderEngine ◄─ AudioEngine ◄─ Exporter
     └─ Captions                    Recorder (no project deps) ─┘
```

## Writing projects (first writes ever — safety rules)

- Every write goes through TSCProjKit (`ProjectBundle.saveWithBackup`,
  `create`, `importFile`) and TimelineEngine commands. Untouched keys, key
  order and number lexemes survive.
- Agents test writes **only on copies** in a temp dir. The user's projects in
  `~/Documents` stay read-only for agents; the app may write them only when the
  user saves.
- Save = atomic replace of `project.tscproj` + `project.tscproj.wizrec-backup`
  of the previous version. No autosave into the bundle in M2.
- New projects: format `10.0`, editRate 705600000, `authoringClientName`
  `{name: "WizRec", platform: "Mac", version}`.

## TimelineEngine M2/M3

M2 commands (stubs in `ContractM2.swift`): `AddSource`, `InsertClip`,
`DeleteClips(ripple:)`, `AddTrack`, `RemoveTrack`, `SetTrackFlag`,
`SetParameter(keyframeAt:)`, `RelinkSource`. Semantics follow
`docs/specs/*.md`; where a spec says [?], pick the rule, document it in a doc
comment and list it in REVIEW.

M3 commands (timeline adds them as additive API, announced with
`API_CHANGE TimelineEngine`): ripple trim/move, magnetic tracks, a pure
`Snapping` helper (clip edges, playhead, markers; frame grid), copy/paste
(`ClipboardPayload` = JSON subtree + id remap), group/ungroup, stitch/unstitch,
detach audio, clip speed, extend frame, markers, add/remove/reorder effects and
effect parameters, add/remove transitions. Each command: expected-JSON test +
byte-identical revert.

## MediaEngine M2 (additive)

- `StreamInfo` gains what `SourceDescriptor.Track` needs: stream timescale,
  length in that timescale, bit depth (PlayerKit maps `MediaInfo` →
  `SourceDescriptor`).
- Waveform peaks: min/max per bucket for a stream, cached per URL.
- Filmstrip thumbnails: batch API on a separate decoder pool so it never moves
  playback lanes.
- Playback throughput for high clip speeds (async `VTDecompressionSession`),
  plus a documented "nearest decoded frame" policy the player can opt into.

## TimelineUI

`TimelineModel` (`@MainActor @Observable`) + `TimelineView` (`NSView`). The
view never mutates JSON: every gesture becomes a TimelineEngine command on
`model.undo`. Ticks everywhere; points only in the view. Thumbnails and
waveforms come from MediaEngine via an injected provider so tests run without
media.

## RenderEngine M4+

render extends the contract with `API_CHANGE RenderEngine` as needed:
effects drawn per layer in `effects` order (layer → offscreen → effect passes),
`LayerContent.shader` gets a time value, transitions in the plan, later
`LayerContent.callout` (M5) and a cursor layer (M6). Every effect follows a
published spec in `docs/specs/effects/<Name>.md`.

## Recorder

`RecordingSession` + `RecordingOptions`/`RecordingResult`
(`Sources/Recorder/Contract.swift`). Output: MP4 screen (cursor not drawn by
default), optional camera MP4, audio files, `cursor.json` in our own format
(`docs/specs/cursor-log.md`, written by recorder). Recorder never touches
projects; the app adds a result to a project via `importFile` + `AddSource` +
`InsertClip`, under `recordings/<ts>/`.

---

# Contracts — wave B (M8 audio, M9 export, M10 captions)

Frozen stubs: `Sources/AudioEngine/Contract.swift`, `Sources/Exporter/Contract.swift`,
`Sources/Captions/Contract.swift`.

- **AudioEngine** builds its own `AudioScene` value projection (like
  `SceneModel`): clip time mapping per time-mapping.md, `attributes.gain`
  × `volume` (keyframed) × group/stitched gains (defaults.md), track mute/solo,
  audio fades and transitions (`useAudioPreRoll`), loudness normalisation to
  `targetLoudness` when `shouldApplyLoudnessNormalization`, clip speed
  (pitch-preserving time-stretch), audio effects by `effectName` (noise
  removal with an open model, e.g. RNNoise BSD-3, never TechSmith's VST).
  `AudioMixer.render(range)` is deterministic and chunk-seamless. The player
  (PlayerKit) and Exporter both use it.
  - Session 3 (additive, approved): `AudioScene.sampleRate: Double?` = the
    project's `audioFormatSampleRate` in Hz, nil when absent, not a number or
    outside 8000…384000.
- **Exporter**: `ExportSession` drives `OfflineRenderer` frames + `AudioMixer`
  audio into AVAssetWriter (H.264/HEVC/ProRes, VideoToolbox), GIF (palette per
  segment) and audio-only (m4a/wav; mp3 through libavcodec `libmp3lame`, which
  the Homebrew FFmpeg already has — add `libavformat` muxing via CFFmpeg if
  needed). Export frame N must equal the preview frame N; A/V sync within 1
  frame. Progress + cancel (partial file removed).
  - Session 3: audio is mixed and written at `AudioScene.sampleRate ?? 48_000`
    Hz (presets carry no sample rate).
- **Captions**: `SpeechRecognizer` backends: Apple Speech on-device first (no
  new dependency; needs Speech Recognition permission), whisper.cpp second
  (MIT; ask the lead before installing anything or downloading models).
  Transcripts are written via TimelineEngine commands that captions adds
  (`ApplyTranscription` → `sourceBin[].sourceTracks[].parameters.transcription`
  per captions.md; `AddCaptions`/dynamic-caption callouts). SRT/VTT import and
  export.
