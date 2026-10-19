# Board — M1: read-only playback

Goal: the WizRec window opens `~/Documents/demo project.cmproj` and plays and
scrubs it correctly at 1080p / 60 fps. Only the lead edits this file.

Status: `todo` · `claimed` · `review` · `done` · `blocked`

## Owners and paths

| Agent | Branch | Owns |
|---|---|---|
| media | `agent/media` | `Sources/MediaEngine/**`, `Tests/MediaEngineTests/**` |
| render | `agent/render` | `Sources/RenderEngine/**`, `Tests/RenderEngineTests/**` |
| timeline | `agent/timeline` | `Sources/TimelineEngine/**`, `Tests/TimelineEngineTests/**`, additive TSCProjKit mutation helpers |
| qa | `agent/qa` | `Tests/GoldenTests/**`, test-project generator, `.github/workflows/**`, perf tests |
| format | `agent/format` | `docs/FORMAT.md`, `docs/specs/**` (never `Sources/`) |
| app (wave 2) | `agent/app` | `Sources/WizRecApp/**`, `scripts/**` app bundling |

## Tasks

| id | owner | status | depends-on | acceptance |
|---|---|---|---|---|
| M1-MED-1 | media | done | — | `probe` + `source(for:)` for mp4/mov/m4a/wav/png/jpg/`.trec`/`.tscshadervid`; tests on synthesized media |
| M1-MED-2 | media | done | MED-1 | `.trec` tscc2 decode via libavcodec, VFR hold rule, frame-accurate seek; demo-project test (skips if absent) |
| M1-MED-3 | media | done | MED-1 | AVFoundation h264/hevc decode, frame-accurate seek, test: seek(n) == sequential(n) |
| M1-MED-4 | media | done | MED-2,3 | `MediaPool` LRU frame cache (PTS-snapped keys) + `prefetch`; perf test 1080p ≥ 120 fps decode |
| M1-MED-5 | media | done | MED-1 | `audio(stream:range:format:)` PCM + resample; `thumbnail` |
| M1-REN-1 | render | done | — | `SceneModel` + `evaluate`: transform, crops, opacity, keyframes; UnifiedMedia, StitchedMedia, Group, scalar; unit tests on hand-built JSON + demo fixture |
| M1-REN-2 | render | done | REN-1 | `audioSegments(in:)` with nested scalars and gains |
| M1-REN-3 | render | done | REN-1 | `Compositor`: transform, crops, opacity, offscreen groups, shader fallback; GPU tests on synthetic frames (pixel probes) |
| M1-REN-4 | render | done | REN-3, MED-4 | `OfflineRenderer.image`; renders demo frame 0/mid/end to PNG |
| M1-TL-1 | timeline | done | — | `UndoStack` tests (perform/undo/redo/limit/redo-clear) |
| M1-TL-2 | timeline | done | TL-1 | `SplitClip`, `TrimClip`, `MoveClip` with expected-JSON tests; undo restores byte-identical serialisation; id allocation above `maxID` |
| M1-QA-1 | qa | done | — | Golden harness: SSIM + PSNR, frame extraction from reference MP4, skips without `REFS_DIR` |
| M1-QA-2 | qa | done | — | Generator for small effect-free test projects (built with TSCProjKit) + list of exports needed from the user |
| M1-QA-3 | qa | done | — | `.github/workflows/ci.yml` macOS runner: brew ffmpeg, `swift build`, `swift test` |
| M1-QA-4 | qa | done | REN-4 | Perf tests: decode + composite throughput 1080p/4K |
| M1-FMT-1 | format | done | — | `docs/specs/time-mapping.md`: groups, stitched, scalar, keyframe time base, `mediaStart` floats/rationals |
| M1-FMT-2 | format | done | — | `docs/specs/transform.md`: coordinate system, y direction, scale vs `default-scale`, crop edge order, rotation units |
| M1-FMT-3 | format | done | — | `docs/specs/media-streams.md`: `trackNumber` ↔ stream, stream time origin, `sourceTracks.range`, VFR in `.trec` |
| M1-APP-1 | app | done | MED-4, REN-3 | Player window: open `.cmproj`, canvas, play/pause/scrub, 60 fps at 1080p, audio clock |

## M1 result (2026-10-19)

All M1 tasks done and merged. Demo plays at 30 fps (audio clock), vlog at
60 fps. Pending on the user: `docs/testing/camtasia-session-1.md`.

## Backlog from M1 agents (for M2+ planning)

| Item | From | Target |
|---|---|---|
| Async `VTDecompressionSession` decode (several frames in flight) for high-speed long-GOP HEVC; meanwhile a player policy to drop distinct frames when speed × fps > decode rate | media, app | M2 |
| Separate `MediaPool` (or thumbnail decoder) for media-bin/filmstrip thumbnails | media | M2 |
| Min/max peak API for timeline waveforms | media | M2/M8 |
| Show `MediaPool.cacheStats` in the player overlay | app | M2 |
| Open Recent menu; audio-device change handling; pitch-preserving speed | app | M2/M8 |
| Shader time uniform in `LayerContent` for real `.tscshadervid` rendering | render | M4 |
| Pool offscreen group textures if profiling shows a need | render | M4 |
| Apply timeline-level `gain` in `AudioSegment` | render | M8 |
| Ripple, magnetic tracks, edge/playhead snapping, group/ungroup, stitch/unstitch, copy/paste, nested moves, locked tracks, clip speed | timeline | M3 |
| Resolve crop order, rotation sign, group composition/time, `trimStartSum`, edit semantics from X1–X7 | format | after user session |
| Fit `eioe` curve with `wizrec-testgen track-marker` on reference exports | qa, format | after user session |
| Run CI once a GitHub remote exists; check Metal-less runners skip GPU tests | qa | when repo is published |

# Wave A — M2 editor shell, M3 edits, M4 effects, M7 recorder (2026-10-19)

| Agent | Branch | Owns |
|---|---|---|
| app | `agent/app2` | `Sources/WizRecApp/**`, `Sources/PlayerKit/**`, `scripts/**` |
| timelineui | `agent/timelineui` | `Sources/TimelineUI/**`, `Tests/TimelineUITests/**` |
| timeline | `agent/timeline2` | `Sources/TimelineEngine/**`, TSCProjKit write path (`BundleWriting.swift` + additive helpers) |
| media | `agent/media2` | `Sources/MediaEngine/**` |
| render | `agent/render2` | `Sources/RenderEngine/**` |
| researcher | `agent/researcher` | `docs/specs/**`, `docs/FORMAT.md`, `docs/ledger/**` (RE side) |
| recorder | `agent/recorder` | `Sources/Recorder/**`, `Tests/RecorderTests/**`, `docs/specs/cursor-log.md` |

| id | owner | status | depends-on | acceptance |
|---|---|---|---|---|
| M2-TL-1 | timeline | done | — | `ProjectBundle.create/importFile/saveWithBackup`; new project opens in our app; round-trip tests |
| M2-TL-2 | timeline | done | TL-1 | `ContractM2` commands, expected-JSON + byte-identical revert tests |
| M3-TL-1 | timeline | done | TL-2 | ripple, magnetic, snapping helper, copy/paste, group/ungroup, stitch/unstitch, detach audio, speed, extend frame, markers, effects/transitions add/remove |
| M2-MED-1 | media | done | — | `StreamInfo` timescale/length/bitDepth; peaks API; filmstrip thumbnails on own pool |
| M2-MED-2 | media | done | — | high-speed playback throughput (async VT) + nearest-frame policy |
| M2-TUI-1 | timelineui | done | — | ruler, tracks, headers, clips, playhead, zoom/scroll; view tests on hand-built projects |
| M2-TUI-2 | timelineui | done | TL-2 | select/move/trim/split/delete/ripple, track flags, snapping, thumbnails + waveforms |
| M2-APP-1 | app | done | TUI-1 | editor window: media bin, canvas, timeline, inspector; undo/redo menus |
| M2-APP-2 | app | done | TL-1 | new/open/save/save-as (backup), import (drag-drop + menu), relink missing media |
| M2-APP-3 | app | done | — | inspector edits via `SetParameter`; cacheStats in overlay; high-speed frame policy |
| M4-RES-1 | researcher | done | — | specs: effects group 1 (`RoundCorners`, `DropShadow`, `Border`, `ColorAdjustment`, `Mask`, `BlendModeEffect`, `MotionBlur`, `MediaMatte`, `Reflection`) |
| M4-RES-2 | researcher | done | — | specs: transitions catalog, behaviours, `.tscshadervid` uniforms, markers |
| M5-RES-1 | researcher | done | — | spec: callouts (shapes, text, fills, strokes, tails) |
| M6-RES-1 | researcher | done | — | specs: `.trec` cursor/click stream (`docs/specs/trec.md`), cursor effects |
| M4-REN-1 | render | done | — | effect pipeline (offscreen + passes), shader backgrounds for real, transition framework + fade |
| M4-REN-2 | render | claimed (Border/Reflection/BlendMode enums wait on EF0–EF9) | RES-1 | group-1 effects from published specs, golden-ready |
| M5-REN-1 | render | done | M5-RES-1 | callout rendering (own vector shapes, text) |
| M6-REN-1 | render | done | M6-RES-1 | cursor layer + cursor effects |
| M7-REC-1 | recorder | done | — | ScreenCaptureKit display/window/region → MP4, pause/resume, countdown |
| M7-REC-2 | recorder | done | REC-1 | mic, system audio, camera |
| M7-REC-3 | recorder | done | REC-1 | cursor/click log + cursor images, `docs/specs/cursor-log.md`; keystrokes behind consent |
| M7-REC-4 | recorder | done | REC-1 | HUD window controller (countdown, timer, pause/stop, hotkeys) for the app to present |
| QA-5 | qa | done | RES-1 | EF1–EF9 effect test projects (+ CO1/CO2) in camtasia_rea_refs/effects/ |
| QA-6 | qa | done | — | `docs/testing/camtasia-session-2.md` |
| QA-7 | qa | claimed | REN-2 | golden effects harness + ProjectThumbnail extractor |
| QA-8 | qa | done | TL-2 | M2 editing integration tests (command sequences, save/reopen, byte-identical undo) |

# Wave B — M8 audio, M9 export, M10 captions

| id | owner | status | depends-on | acceptance |
|---|---|---|---|---|
| M8-AUD-1 | audio | done | — | `AudioScene` + `AudioMixer.render`: time mapping, gain × volume keyframes × nested gains, mute/solo, fades/transitions, deterministic + chunk-seamless; tests on synthesized audio + demo |
| M8-AUD-2 | audio | done | AUD-1 | BS.1770 loudness (integrated LUFS, true peak) + normalisation to `targetLoudness` |
| M8-AUD-3 | audio | claimed | AUD-1 | pitch-preserving clip speed; noise removal (open model), leveling, ducking, pitch effects by effectName |
| M8-AUD-4 | audio | done | AUD-1 | PlayerKit switches to AudioMixer (coordinate with app) |
| M9-EXP-1 | export | claimed | — | MP4 H.264/HEVC + MOV ProRes via AVAssetWriter from OfflineRenderer frames, progress, cancel |
| M9-EXP-2 | export | claimed | AUD-1 | audio track via AudioMixer, A/V sync ≤ 1 frame; audio-only m4a/wav/mp3 |
| M9-EXP-3 | export | claimed | EXP-1 | GIF; presets; batch export; export frame N == preview frame N test |
| M10-CAP-1 | captions | done | — | SRT/VTT import/export; Apple Speech recognizer; `ApplyTranscription` + caption commands |
| M10-CAP-2 | captions | claimed | CAP-1 | dynamic captions (render via callouts), whisper.cpp backend (after lead OK) |
| M3-TUI-1 | timelineui | claimed | TL M3 | ⌥-drag ripple move/trim with preview, trim preview honours media limits, double-click group → nested editing, marker drag/rename, transitions/effects add-remove UI (drag from a library panel), clip-speed badge |
| M2-APP-4 | app | claimed | REC-4, EXP | File ▸ New Recording (HUD → recordings/<ts>/ → insert), copy/paste via ClipboardPayload, group/stitch/detach/speed menus, export sheet when export lands, effects/transitions panels with timelineui |

# Wave C — M11 polish & ship

| id | owner | status | depends-on | acceptance |
|---|---|---|---|---|
| M11-SHIP-1 | ship | claimed | — | `Sources/WizRecAssets`: our own original library — backgrounds (Metal/GLSL we write), transitions (Fade/Dissolve/wipes/slide/cube… our shaders), callout presets, cursor art (arrow/hand/I-beam), click-effect art, OFL fonts (upstream copies + licence files); catalog API; no TechSmith content |
| M11-SHIP-2 | ship | claimed | — | Release engineering: `scripts/make-app.sh` release build with bundled FFmpeg dylibs (rpath fix, licence notices), codesign/notarize script taking identity from env (no secrets in repo), DMG, Sparkle (MIT) integration plan behind a flag, CI update |
| M11-SHIP-3 | ship | claimed | — | Docs: README refresh, CONTRIBUTING.md (clean-room rules), user guide (`docs/user-guide/`), keyboard shortcut map, third-party notices |
| M11-APP-1 | app | todo | M2-APP-4 | Preferences, onboarding, accessibility pass, localisation scaffolding (String Catalog), Open Recent, crash reporting opt-in (local only) |

# Session 2 (2026-10-19) — resume of waves B and C

Main green at start: 486 tests (40 golden, 1 known issue). Stale session-1
worktrees removed; branches kept.

| Agent | Branch | From | Claimed |
|---|---|---|---|
| audio | `agent/audio3` | `agent/audio` b51f2c3 | M8-AUD-1..4 |
| export | `agent/export3` | `agent/export` 5109ba8 (+452bd37) | M9-EXP-1..3 |
| captions | `agent/captions3` | `agent/captions` 59b4eb6 | M10-CAP-1..2 |
| timelineui | `agent/timelineui3` | `agent/timelineui` 9430f6c | M3-TUI-1 rest |
| app | `agent/app3` | `agent/app2` 45b8b3a | M2-APP-4, AUD-4 app side, export sheet, M11-APP-1 |
| ship | `agent/ship3` | `agent/ship` dec60fa | M11-SHIP-1..3 |
| qa | `agent/qa3` | `main` | QA-7, QA-8, wave-B integration, timing audit |

## Session 2 merges

- timelineui3-perf: TimelineUI timing asserts gated (486 green).
- app3 slice 1: library panel (search, double-click effects, a11y), Open Recent, M key (490 green). M2-APP-4 remaining: export sheet.
- audio3 slice 1: AUD-1 AudioMixer + AUD-2 BS.1770 loudness/normalisation (512 green).
- Decision: MP3 via libmp3lame.
- timelineui3: nested group editing (520); apply effect/transition, Remove Effect, speed badge, trim limits, no-op skips (595).
- qa3: QA-8 editing integration tests (527).
- app3: AUD-4 playback through AudioMixer, basic mix removed (526).
- captions3: CAP-1 commands, SRT/VTT, TranscriptionBackend + Apple Speech (gated) (587 with ship).
- ship3 slice 1: WizRecAssets catalog, own shaders/art, 4 OFL fonts.
