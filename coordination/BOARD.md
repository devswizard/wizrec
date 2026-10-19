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
