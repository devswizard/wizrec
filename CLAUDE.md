# CLAUDE.md — WizRec: open-source Camtasia-compatible recorder & editor

## Mission

Build a free, open-source macOS app for recording the screen and editing the
result on a multi-track timeline. The app should match Camtasia's workflow and
features, and it should **open, edit and save Camtasia `.cmproj` /
`.tscproj` projects**, so that work started in Camtasia on any Mac or PC can
continue here.

- **Name: WizRec** (chosen 2026-10-19), a Devs Wizard product.
  - Tagline: *"WizRec — free, open-source screen recorder & editor by Devs
    Wizard. Opens your Camtasia projects."*
  - App target and product: `WizRec`. Swift package: `WizRec`.
  - On 2026-10-19 the user retired the earlier prototypes, the old WizRec
    recorder and Wiz Remove, and moved them to the Trash (source,
    `~/Movies/WizRec` recordings and preferences). This project replaces
    them. Reuse nothing from them; start clean.
  - The old bundle ID `com.devswizard.wizrec` was used by the retired
    prototype. Stale Screen Recording permission entries may remain in System
    Settings.
  - Module names stay descriptive (`TSCProjKit`, `MediaEngine`,
    `RenderEngine`, …).
- **Never put "Camtasia" in a product, module or bundle name.** It is a
  TechSmith trademark, and using it invites takedowns.
- **Describing compatibility is fine.** A line such as "opens Camtasia
  projects" is allowed (nominative use).

## Hard rules (non-negotiable)

1. **Clean room.** Implement from observed behaviour and file formats only.
   - Never copy, transcribe or paraphrase decompiled TechSmith code into this
     repo.
   - Reverse-engineering output goes into *behavioural specs*
     (`docs/specs/*.md`) that describe **what** happens, never **how
     TechSmith's code does it**.
   - Implementers work from those specs. See "Clean-room wall" in
     `docs/HANDOFF.md`.
2. **No licensing work of any kind.**
   - Do not analyse, patch, hook or emulate `TSCLicensing`,
     `TSCActivationKit`, `TSCAccount`, `ShaferFilechck*.dylib`, the
     activation flows, or the trial watermark.
   - Do not build anything that unlocks Camtasia itself.
   - Refuse such requests, even when they are framed as an add-on.
3. **No TechSmith assets in the repo.** That covers themes, shaders
   (`.tscshadervid`), sample projects, callout art, cursors, sounds, icons and
   fonts.
   - Tests may *read* Camtasia's sample projects from
     `/Applications/Camtasia.app` when it is installed. They must skip when it
     isn't.
   - When a user's own project references TechSmith content, render it from
     the user's copy. Never redistribute it.
4. **Prefer black-box observation to decompilation.** Use these methods in
   order:
   1. Read the user's own project and media files.
   2. Use the user's own Camtasia exports as reference renders.
   3. Use REA runtime observation, but only with the user's approval because
      it runs Camtasia.
   4. Use static REA analysis, only when the first three can't answer a
      question that matters for interoperability (for example, the `.trec`
      cursor stream).
5. **Lossless project I/O is the compatibility contract.**
   - Every edit goes through `TSCProjKit`, which preserves unknown keys, key
     order and the exact text of numbers.
   - Never re-serialise a project through `Codable` or `JSONSerialization`.

## Current state (2026-10-21, end of build session 9)

- **Resume from `docs/HANDOFF.md` §0** (session 9 snapshot, follow-ups,
  user's pending items).
- Done and merged: M0–M3, M7 recorder, M8 audio (aligned to Camtasia
  2026.2.3 AU1/AU2), M9 export (ProRes demo 25.7 s in ~2 s), M10 captions
  (whisper.cpp 1.9.5; VAD timing; Bengali via large-v3-turbo; CA1/CA2
  rules), M11 (Sparkle 2.10.0 wired, feed prepared, off until a key exists;
  ad-hoc DMG; **v0.1.0 and v0.1.1 public**), M4–M6 rendering (31 blend
  modes, matte modes, Border/Reflection, CO3 callouts, Extend Frame, Metal
  HDR tone map for playback), group/split/trim/ungroup/marker/copy-paste/
  drop/Clip Speed rules from observed Camtasia saves. Automated UI checks of
  the built app (`scripts/ui-checks/`, 8/8). **1148 tests green** (17 known
  issues = golden-harness and LoadGate self-tests).
- Session 9 landed:
  - **v0.1.1** tagged on the CI-green `0ccf292` and published through
    `publish.yml` (rpath-clean DMG, no `allow-build-rpaths`); public
    2026-10-21T10:05Z, verified from the public URL.
  - Audio export of projects without `audioFormatSampleRate` no longer ~10×
    slower (measured at the mix rate [WizRec]); bit-exact faster resampler
    and DSP; output hash tests.
  - CI tests build with `-Xswiftc -O`: serial media step 515 s → 91 s.
    It exposed a real RenderEngine crash (CVMetalTextures released on
    Metal's completion queue), fixed with a locked texture cache.
  - Captions: whisper-cli stderr never lost on a fast failure.
  - Researcher (save-only, wall-reviewed): Clip Speed rounding (ED2b),
    media-bin drop into an open group (§8.6: no growth, no clamp), Assets
    background placement (§11.2). Timeline and app follow them.
  - App: library Tab order over every tile, `--window-size`.
- **CI / release:** CI green on GitHub (runs 33–34; tests built `-O`). Mix
  digests of `OutputHashTests` vary per CI machine type; each variant is
  pinned, unknown ones show in the "Known issues" annotation.
- Camtasia here is a **trial**: export only offers "with/without watermark",
  so there are still **no reference exports**; golden parity (M1/M4/M5/M6)
  and every look/timing question stay open. The export-only leftovers are
  listed at the end of `docs/testing/camtasia-session-2.md`.
- Camtasia rejects WizRec `.tscshadervid` backgrounds (signed files only);
  WizRec warns on save.
- Remote: `https://github.com/devswizard/wizrec` (public). No Apple
  Developer account: ad-hoc DMGs, never notarized. The old local
  `worktree-agent-*` branches were deleted (user's OK, session 9).
- Still blocked on the user: licensed reference exports; one Sparkle
  `generate_keys` run (public key into `release/sparkle.conf`).

### M0 (2026-10-19)


- **`Sources/TSCProjKit`**: lossless JSON tree (`JSON.swift`); exact rational
  time (`Time.swift`); parameters and keyframes (`Parameter.swift`); clip
  kinds, effects and callouts (`Clip.swift`); project, source bin, tracks and
  transitions (`Project.swift`); `.cmproj` bundle handling (`ProjectBundle.swift`).
- **`Sources/tscproj`**: CLI with `info` and `roundtrip [-o]`.
- **Tests**: 16 Swift Testing tests, all passing. Fixture:
  `Tests/TSCProjKitTests/Fixtures/demo.tscproj`, taken from the user's
  `~/Documents/demo project.cmproj`.
- **Round-trip coverage**: all 24 available projects keep their structure
  after a save. They span formats 2.0–10.0 and include Mac- and
  Windows-authored files.
- **`docs/FORMAT.md`**: the format spec. Each claim is tagged [obs] (observed),
  [inf] (inferred) or [?] (unknown).
- **`Design/AppIcon`**: icon sources (`AppIcon.svg`, plus `AppIcon-small.svg`
  for sizes up to 32 px). `build-icon.sh` produces the `.icns`, the
  `.appiconset` and a 1024 px PNG.
- **Verified in Camtasia (2026-10-19)**: Camtasia 2026.2.3 opens and plays
  `demo-roundtrip.cmproj`, a copy of the demo project rewritten by
  `TSCProjKit`. The group, effects and duration (`00:00:25;20`) are intact, so
  our serialisation is accepted.

## Environment

- macOS 27 on arm64, Xcode 27, Swift 6.4 (strict concurrency).
- Homebrew provides `ffmpeg`/`ffprobe`, `rsvg-convert`, `node` and `python3`.
- Camtasia 2026.2.3 is at `/Applications/Camtasia.app`, for black-box
  reference only.
- Test projects:
  - `~/Documents/demo project.cmproj` (small; group, screen recording, cursor
    effects, mask, shader background).
  - `~/Documents/Moheshkali Dwip Vlog.cmproj` (large; 49 sources, stitched
    clips, 7 minutes). This is personal footage: never copy it into the repo.
- REA MCP server (`mcp__rea__*`, deferred: load with ToolSearch) and the
  `reverse-engineer-anything` skill.

## Commands

```sh
swift build
swift test
swift run tscproj info "<project.cmproj|.tscproj>"
swift run tscproj roundtrip "<project>" -o /tmp/out.tscproj
swift run tscproj strip-thumbnail "<file.tscproj>" [-o out]
Design/AppIcon/build-icon.sh
```

## Architecture

```
┌──────────────────────────── App (SwiftUI + AppKit) ────────────────────────────┐
│ MediaBin │ Canvas (MTKView) │ Timeline view │ Properties │ Recorder HUD │ Export │
└──────┬───────────┬──────────────────┬───────────────┬─────────────┬────────────┘
       │           │                  │               │             │
       ▼           ▼                  ▼               ▼             ▼
  TimelineEngine ─► RenderEngine ◄─ MediaEngine    Recorder      Exporter
  (edit commands,   (Metal graph:   (AVFoundation   (ScreenCapture (AVAssetWriter /
   undo, snapping,   transform,      + FFmpeg for    Kit, AVCapture, FFmpeg, presets,
   ripple, groups)   crop, effects,  tscc2; frame    cursor/click    GIF)
       │             callouts,       cache, audio    log)
       │             transitions,    decode, wave-
       │             cursor FX)      forms)
       ▼                  ▲               ▲
   TSCProjKit ────────────┴───────────────┘     Captions (whisper.cpp) ─► TSCProjKit
   (lossless project model, time, params)       AudioEngine (mix, gain, LUFS, FX)
```

### Modules

All modules are SwiftPM targets in this package. The app is a separate Xcode
project in `App/` that depends on the package.

| Module | Responsibility | Key Apple APIs |
|---|---|---|
| `TSCProjKit` ✅ | Project model and I/O, time maths, parameter evaluation | Foundation |
| `MediaEngine` | Open sources and decode video frames into `CVPixelBuffer`s (IOSurface-backed) and audio into PCM. Decode `tscc2` through libavcodec. Cache thumbnails and waveforms, and probe media. | AVFoundation, VideoToolbox, libavcodec (dynamically linked, LGPL) |
| `RenderEngine` | Evaluate the scene at time *t*: walk tracks bottom to top, resolve each clip's media time, then apply transform, crop, opacity, effects, transitions and callouts. Compose with Metal. Covers shader backgrounds (GLSL → MSL) and cursor rendering. | Metal, MetalKit, Core Image (prototypes only) |
| `AudioEngine` | Mix tracks, apply gain and volume keyframes, fades, loudness normalisation (LUFS target `targetLoudness`), noise removal and leveling | AVAudioEngine, Accelerate |
| `TimelineEngine` | Edit operations as reversible commands on `TSCProjKit`: split, trim, ripple, move, magnetic tracks, groups, stitch, speed, extend frame, markers. Owns the undo stack. | Foundation |
| `Recorder` | Screen, region or window capture; webcam; mic; system audio; cursor position and click log; keystrokes. Writes MP4 plus a sidecar cursor JSON. | ScreenCaptureKit, AVCapture, CGEvent tap (with permission) |
| `Exporter` | Produce MP4/MOV (H.264/HEVC/ProRes), GIF and audio-only files. Presets, progress, cancel. | AVAssetWriter, VideoToolbox |
| `Captions` | Speech-to-text (whisper.cpp), caption editing, dynamic captions, SRT/VTT import and export | whisper.cpp |
| `App` | Windows, panels, inspector, keyboard shortcuts, preferences, document model (`NSDocument` for `.cmproj` packages) | SwiftUI, AppKit |

### Core runtime design

- **Time.** Time is always integer ticks plus the project `Timebase`.
  - Convert to `CMTime` only at the AVFoundation boundary, where
    `CMTime(value: ticks, timescale: editRate)` is exact for 705600000.
  - Keep exact clip-speed maths in `Rational`.
- **Scene evaluation.** `RenderEngine.evaluate(project, at: ticks)` returns
  a `RenderPlan`: an ordered list of layers, each with a resolved source
  frame, a transform matrix, crop, opacity and an effect chain.
  - The function is pure and deterministic, so it can be unit-tested without a
    GPU.
  - GPU execution of a `RenderPlan` is a separate step.
- **Playback.**
  - A `CVDisplayLink`/`CADisplayLink` clock drives evaluation.
  - MediaEngine pre-rolls decoders ahead of the playhead and holds a small
    ring buffer of frames.
  - Audio is the master clock during playback.
- **Document.**
  - An `NSDocument` subclass reads and writes `.cmproj` packages, using
    `FileWrapper` for `media/` and `recordings/`.
  - Writes are atomic and keep a backup.
  - New projects use format `10.0` and `editRate` 705600000.
- **Concurrency.**
  - Rendering runs on its own serial executor or actor, and decode work runs on
    a task group.
  - UI state is `@MainActor @Observable`.
  - `TSCProjKit` classes are not `Sendable`. Mutate the project only on the
    main actor; the render side sees immutable snapshots, deep-copied with
    `JSON.copy()` or projected into value-type `RenderPlan`s.

## Milestones

Each milestone ends with green tests and a demo the user can run. Write tests
first wherever the behaviour can be specified.

### M1 — Media + read-only playback

- **MediaEngine**
  - Open every `sourceBin` entry in the demo and vlog projects: `.mp4`,
    `.mov`, `.trec` and images.
  - Decode `.trec` screen video (`tscc2`) through libavcodec.
  - Use AVFoundation for H.264, HEVC and AAC.
  - Provide frame-accurate seek and thumbnail generation.
- **RenderEngine v0**
  - Implement `evaluate`, plus a Metal compositor handling translation, scale,
    rotation, opacity, geometry crop and source crop.
  - Handle `UnifiedMedia`, `StitchedMedia` and `Group` (with nested time
    offsets), speed via `scalar`, and constant and keyframed parameters.
- **Minimal player**: an app window with a canvas and a play/pause/scrub bar
  that plays `demo project.cmproj` and the vlog.
- **Acceptance**
  - Golden-frame tests match the user's Camtasia reference export with
    SSIM ≥ 0.97 on frames without effects (see Testing).
  - Playback holds 60 fps at 1080p on Apple silicon.

### M2 — Editor shell

- **Layout**: a document window with media bin, canvas, multi-track timeline
  (zoom, scroll, playhead, track headers with mute, hide and lock) and a
  properties inspector.
- **Media**: import files by drag and drop, and add them to `sourceBin` with
  correct `sourceTracks` metadata via `ffprobe`-equivalent probing in
  MediaEngine.
- **Missing media**: relink missing media, which is the cross-device case
  covered by `ProjectBundle.missingMedia()`.
- **Undo/redo** for every edit.
- **Acceptance**: open a project, import a clip, arrange it, save, then reopen
  in both our app and Camtasia with the edits intact.

### M3 — Editing operations

- **Edit operations**: split at playhead, trim edges, ripple delete, move with
  snapping, and magnetic tracks.
- **Clip handling**: copy and paste (deep copy with id remapping above
  `Project.maxID`), group and ungroup, stitch and unstitch, detach audio,
  clip speed, extend frame, and markers.
- **Acceptance**:
  - Each operation is a command with a unit test that checks the resulting
    JSON.
  - Round-trip stays lossless.
  - Every operation is reproducible in Camtasia.

### M4 — Visual effects parity

Each effect gets a spec in `docs/specs/effects/<Name>.md` first, taken from
black-box reference renders, then a Metal shader and a golden test.

- **Priority group 1:** `RoundCorners`, `DropShadow`, `Border`,
  `ColorAdjustment`, `Mask`, `BlendModeEffect`, `MotionBlur`, `MediaMatte`,
  `Reflection`.
- **Then:** remove colour (chroma key), colourize, device frame, corner
  rounding, and `SourceEffect` shader backgrounds (GLSL → MSL translation).
- **Transitions:** fade, wipes (`RadialWipe` and others), cube, slide. Build
  the transition catalog spec first.
- **Animations**
  - Zoom-n-pan and custom animations (`animationTracks.visual`).
  - Behaviours (`GenericBehaviorEffect` with in, center and out phases).
  - The `eioe` easing curve, fitted from reference renders.
- **Acceptance**: golden SSIM ≥ 0.95 for each effect, measured against the
  user's Camtasia exports of the test projects.

### M5 — Annotations / callouts

- **Shapes**: render `Callout` shapes (rectangle, speech bubbles, arrows,
  lines, highlight, blur, spotlight, sketch motion), text with fonts, fills,
  strokes and tails, and `textAttributes`.
- **Editing**: on-canvas tools for moving, resizing, rotating and editing
  text.
- **Shape geometry**: our own vector drawings, matched to the reference look.
  Never extract TechSmith shape assets.

### M6 — Cursor & screen-recording effects

- **Spec first**: the `.trec` cursor and click data. This is the main static
  reverse-engineering task; it is needed so existing recordings keep their
  cursor data.
- **Cursor effects**: highlight, magnify, spotlight, click ripple and scaling
  (`LeftClickScaling`), smoothing, `CursorPhysics`, `CursorMotionBlur`,
  `CursorShadow`, `CursorColor`, hide cursor, custom cursor image.
- **Rendering pipeline**: the cursor is drawn as a separate layer from the
  cursor log, not taken from the screen pixels.

### M7 — Recorder

- **Capture**
  - ScreenCaptureKit for full screen, region or window.
  - Webcam, mic and system audio.
  - Cursor and click logging and keystroke logging (requires the user's
    consent and Accessibility permission).
  - A recording HUD with countdown, pause and hotkeys.
- **Output**
  - An MP4, with the cursor hidden in the pixels, plus `cursor.json`.
  - The recording is added to the current project under `recordings/<ts>/`.
- **Decision (later)**: whether to write `.trec`-compatible files so Camtasia
  can read our recordings. This is optional and depends on the M6 spec.

### M8 — Audio

- **Mixing**: track mixer, `gain` and `volume` keyframes, and fades.
- **Loudness**: normalisation to `targetLoudness`, using `integratedLUFS` from
  `sourceTracks`.
- **Effects**: noise removal (open model such as RNNoise or DeepFilterNet;
  never reuse TechSmith's VST), volume leveling, emphasize/ducking, pitch, and
  clip-speed audio.
- **Waveforms**: rendered in the timeline.

### M9 — Export

- **Formats**: MP4 (H.264/HEVC), MOV (ProRes) and GIF; audio-only (M4A, MP3
  via LAME, WAV).
- **Controls**: resolution and fps presets, bitrate, progress and cancel, and
  batch export.
- **Acceptance**: an export of the demo project is visually identical to the
  preview at the same frames, and audio stays in sync to within 1 frame.

### M10 — Captions & AI-assist

- **Captions**: whisper.cpp transcription (local, multilingual), a caption
  editor, dynamic captions (`transcription` keyframes and the
  `dynamic-caption-*` styles), and SRT/VTT import and export.
- **Optional**:
  - Filler-word removal.
  - Webcam background removal (Vision person segmentation).
  - Audio background removal using an open model.

### M11 — Polish & ship

- **Content and help**: themes, a library of our own original assets,
  templates, preferences, keyboard shortcut map and onboarding.
- **Distribution**: signing, notarization, an update mechanism (Sparkle is
  MIT-licensed), a website, and a contribution guide.
- **Quality**: crash reporting (opt-in), a performance pass, accessibility,
  localisation, and CI with GitHub Actions on macOS runners.

## Feature parity matrix

| Camtasia feature | Module | Milestone | Unknowns to resolve |
|---|---|---|---|
| Open/save `.cmproj`/`.tscproj` | TSCProjKit, App | M0 ✅ / M2 | — (Camtasia accepts our rewrite ✅) |
| Multi-track timeline, groups, stitch, speed | TimelineEngine | M3 | Snapping/magnetic rules (black-box) |
| Transform, crop, opacity, keyframes | RenderEngine | M1 | `eioe` curve; `animationTracks` ↔ keyframes |
| Visual effects | RenderEngine | M4 | Per-effect maths (reference renders) |
| Transitions | RenderEngine | M4 | Name catalog + params |
| Callouts / annotations | RenderEngine, App | M5 | Shape geometry, text layout |
| Cursor FX, `.trec` cursor data | MediaEngine, RenderEngine | M6 | `.trec` cursor stream format |
| Screen/webcam/mic recording | Recorder | M7 | — |
| Audio mix, leveling, noise removal | AudioEngine | M8 | Loudness algorithm match |
| Export MP4/GIF/audio | Exporter | M9 | — |
| Captions, dynamic captions | Captions, RenderEngine | M10 | Dynamic caption layout rules |
| Webcam/audio background removal | Captions/AI | M10 | — |
| Interactive quizzes, hotspots, Smart Player | — | out of scope | — |
| TechSmith cloud, Screencast, Knowmia sharing | — | out of scope | — |

## Testing strategy

- **Unit tests**: Swift Testing for every module. TimelineEngine commands are
  tested against expected JSON.
- **Round-trip tests**
  - Every fixture and every installed Camtasia sample must parse, serialise
    and parse again to a structurally equal tree.
  - The large vlog project is tested only on this machine, never vendored.
- **Golden frames**
  1. The user exports reference MP4s from Camtasia for the test projects. We
     own those outputs, so this is black-box observation.
  2. Store them outside the repo under
     `~/WorkDir/vibe_coding/camtasia_rea_refs/` and point to them with
     `REFS_DIR`.
  3. The harness renders frame *n* with RenderEngine and compares it with the
     same frame of the reference, measuring SSIM and PSNR.
  4. Tests skip when `REFS_DIR` is missing.
- **Effect test projects**: a small project per effect, each with one clip,
  one effect and keyframes, built with TSCProjKit so the user can open it in
  Camtasia and export it.
- **Performance tests**: decode and composite throughput at 1080p and 4K.

## Research backlog

Each item lists the question, the preferred method, and where the result goes.

1. ~~Camtasia accepts our rewritten project~~ ✅ confirmed 2026-10-19
   (demo project).
2. **`eioe` easing curve**: build a keyframed test project, have the user
   export it, then fit a curve to the per-frame positions →
   `docs/specs/animation.md`.
3. **`animationTracks.visual` semantics**: diff projects saved before and
   after one edit in Camtasia (user-assisted) → `docs/specs/animation.md`.
4. **`.trec` cursor and click data**: start with REA file-level inspection —
   `ffprobe` of all streams, MOV atoms and metadata. Use static REA on
   `TSCRecorderKit`/`RecorderKitShared` only for the stream layout →
   `docs/specs/trec.md`.
5. **Transition catalog**: list the transition resources in the app bundle by
   name only, then do reference renders → `docs/specs/transitions.md`.
6. **Effect parameter ranges and defaults**: read the project JSON and the
   inspector UI (REA `observe_native_ui`, with user approval) →
   `docs/specs/effects/*.md`.
7. **Callout shape catalog**: names come from `def.shape`, the look from
   reference renders → `docs/specs/callouts.md`.
8. **Dynamic caption layout rules**: reference renders →
   `docs/specs/captions.md`.

## Conventions

- **Swift 6 language mode.** No `@unchecked Sendable` without a comment that
  justifies it.
- **Public API:** document every public type in one or two lines, stating
  units (ticks or seconds, pixels or fractions).
- **No force-unwraps** on data that comes from project files. Project data is
  untrusted input, so use defaults that match Camtasia's defaults.
- **Tests:** use Swift Testing (`import Testing`). Fixtures go in
  `Tests/<Module>Tests/Fixtures`, and must be original or user-owned.
- **Commits:** imperative subject. One logical change per commit.
- **Specs:** use `docs/specs/<topic>.md` and tag every claim [obs], [inf] or
  [?]. Cite evidence IDs from `docs/ledger/EVIDENCE.md` where REA was used.

## Open decisions (ask the user)

- ~~App name~~ **Decided 2026-10-19: WizRec** (Devs Wizard brand). A web
  search found no app with this name. Still to do before a public launch:
  - a USPTO trademark search (class 9);
  - choose the GitHub location (for example a `devswizard/wizrec` repo);
  - set the bundle ID from a domain Devs Wizard owns (for example
    `com.devswizard.WizRec` if that domain is `devswizard.com`).
- ~~Licence~~ **Decided 2026-10-19: GPL-3.0-or-later** for the whole repo
  (`LICENSE`).
  - Every forked or redistributed version must stay open source.
  - It is compatible with FFmpeg (LGPL or GPL builds, so x264 is allowed),
    whisper.cpp (MIT) and Sparkle (MIT). Check the licence of every new
    dependency for GPL-3.0 compatibility before adding it.
  - The app cannot ship on the Mac App Store, because Apple's terms conflict
    with the GPL. Distribute as a notarized direct download instead.
- **Minimum macOS**: recommended 14+ for ScreenCaptureKit maturity and
  `@Observable`.
- **App project tooling**: a plain Xcode project, or XcodeGen/Tuist for a
  diff-friendly project file.

## Multi-agent work

Parallel development uses an agent team with a clean-room wall between the
reverse-engineering agents and the implementers. The roster, communication
protocol, REA usage and kickoff prompt are in **`docs/HANDOFF.md`**. Read it
before spawning agents.
