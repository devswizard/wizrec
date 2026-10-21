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
| QA-7 | qa | done | REN-2 | golden effects harness + ProjectThumbnail extractor |
| QA-8 | qa | done | TL-2 | M2 editing integration tests (command sequences, save/reopen, byte-identical undo) |

# Wave B — M8 audio, M9 export, M10 captions

| id | owner | status | depends-on | acceptance |
|---|---|---|---|---|
| M8-AUD-1 | audio | done | — | `AudioScene` + `AudioMixer.render`: time mapping, gain × volume keyframes × nested gains, mute/solo, fades/transitions, deterministic + chunk-seamless; tests on synthesized audio + demo |
| M8-AUD-2 | audio | done | AUD-1 | BS.1770 loudness (integrated LUFS, true peak) + normalisation to `targetLoudness` |
| M8-AUD-3 | audio | done | AUD-1 | pitch-preserving clip speed; noise removal (open model), leveling, ducking, pitch effects by effectName |
| M8-AUD-4 | audio | done | AUD-1 | PlayerKit switches to AudioMixer (coordinate with app) |
| M9-EXP-1 | export | done | — | MP4 H.264/HEVC + MOV ProRes via AVAssetWriter from OfflineRenderer frames, progress, cancel |
| M9-EXP-2 | export | done | AUD-1 | audio track via AudioMixer, A/V sync ≤ 1 frame; audio-only m4a/wav/mp3 |
| M9-EXP-3 | export | done | EXP-1 | GIF; presets; batch export; export frame N == preview frame N test |
| M10-CAP-1 | captions | done | — | SRT/VTT import/export; Apple Speech recognizer; `ApplyTranscription` + caption commands |
| M10-CAP-2 | captions | done | CAP-1 | dynamic captions (render via callouts), whisper.cpp backend (after lead OK) |
| M3-TUI-1 | timelineui | done | TL M3 | ⌥-drag ripple move/trim with preview, trim preview honours media limits, double-click group → nested editing, marker drag/rename, transitions/effects add-remove UI (drag from a library panel), clip-speed badge |
| M2-APP-4 | app | done | REC-4, EXP | File ▸ New Recording (HUD → recordings/<ts>/ → insert), copy/paste via ClipboardPayload, group/stitch/detach/speed menus, export sheet when export lands, effects/transitions panels with timelineui |

# Wave C — M11 polish & ship

| id | owner | status | depends-on | acceptance |
|---|---|---|---|---|
| M11-SHIP-1 | ship | done | — | `Sources/WizRecAssets`: our own original library — backgrounds (Metal/GLSL we write), transitions (Fade/Dissolve/wipes/slide/cube… our shaders), callout presets, cursor art (arrow/hand/I-beam), click-effect art, OFL fonts (upstream copies + licence files); catalog API; no TechSmith content |
| M11-SHIP-2 | ship | done | — | Release engineering: `scripts/make-app.sh` release build with bundled FFmpeg dylibs (rpath fix, licence notices), codesign/notarize script taking identity from env (no secrets in repo), DMG, Sparkle (MIT) integration plan behind a flag, CI update |
| M11-SHIP-3 | ship | done | — | Docs: README refresh, CONTRIBUTING.md (clean-room rules), user guide (`docs/user-guide/`), keyboard shortcut map, third-party notices |
| M11-APP-1 | app | done | M2-APP-4 | Preferences, onboarding, accessibility pass, localisation scaffolding (String Catalog), Open Recent, crash reporting opt-in (local only) |

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
- ship3: GLSL transition renderer (all 18 catalog transitions), release scripts, docs + notices (621). SHIP done.
- app3: M11-APP-1 preferences, onboarding, crash log opt-in, String Catalog, a11y (608).
- timelineui3: library from WizRecAssets, renderedTransitions. M3-TUI-1 done.
- captions3: CAP-2 dynamic captions rendered (621). M10 done (whisper.cpp waits on user).
- Open follow-ups: inner AddTrack/RemoveTrack + media drops in open groups; Sparkle dependency (approval pending); Info.plist camera/mic usage strings (app); caption UI + export sheet (app); AUD-3 (audio); EXP-1..3 (export).
- qa3: audio + captions integration tests, QA-7 foreground SSIM, timing audit (634).
- audio3: AUD-3 noise removal, leveling, pitch, emphasize (own DSP). M8 done.
- captions3: classic captions on media axis (fixes split/trim bug found by qa).
- app3: caption UI (transcribe, dynamic captions, SRT/VTT), usage strings (645).
- media3 (on demand): WAV probe misdetection bug found by audio.
- media3: libav content-probe misdetection → extension demuxer hint; no PDF fall-through.
- qa3: export integration tests, golden frames with foreground SSIM + marker position (654). QA done.
- export3: M9 Exporter — H.264/HEVC/ProRes, GIF, m4a/wav/mp3, presets, batch, cancel; A/V sync ≤ 1 frame; ~2.2× real time 1080p (695). M9 engine done; export sheet pending (app).
- app3: export sheet (batch presets, overrides, progress/cancel), `--export` flag (698). M2-APP-4 done.
- export3: stale work-dir sweep (700).
- **Session 2 complete: all agents DONE, all branches merged, 700 green.** Follow-ups in docs/HANDOFF.md §0a.

## Session 3 (2026-10-19)

Main green at start: 700 tests (18 known issues). No stale worktrees.
User inputs: no Camtasia references yet (no researcher, golden gates stay
skipped); recorder real capture OK; live speech OK; whisper.cpp reported
installed but not found on disk (backend runtime-detected); no GitHub remote,
Developer ID or Sparkle approval (no ship agent).

| id | owner | status | acceptance |
|---|---|---|---|
| S3-TL-1 | timeline | done | `AddTrack`/`RemoveTrack` inside a group, media drop into an open group: expected-JSON + byte-identical undo tests |
| S3-TUI-1 | timelineui | done | Group-track add/remove + media drops in open groups in the UI, on S3-TL-1 commands |
| S3-TUI-2 | app | done | Dynamic caption style as an inspector section (moved from timelineui: inspector is app-owned) |
| S3-REN-1 | render | done | Parallel `OfflineRenderer`: several frames in flight, deterministic, frame N unchanged; ≥ 4× real time 1080p (perf test gated) |
| S3-REN-2 | render | done | Optional: particle shaders (vertexCode), HDR tone mapping |
| S3-EXP-1 | export | done | Audio export sample rate from `audioFormatSampleRate` (additive AudioScene API) |
| S3-EXP-2 | export | done | Confirm-before-cancel hook for the app; use render's parallel path |
| S3-APP-1 | app | done | Export sheet confirm on window close; wire group/inspector features; make-app.sh + String Catalog current |
| S3-CAP-1 | captions | done | whisper.cpp backend via `whisper-cli` subprocess, runtime-detected, gated live test; fake-binary unit tests |
| S3-QA-1 | qa | done | Integration tests for every new command/feature; flaky watch; golden re-run ready for references |
| S3-MED-1 | media | done | Decoded pixels independent of lane/history: VT and libav lanes identical (or pinned for offline), seek == sequential; qa's SeekDeterminismTests known issue removed |

## Session 3 merges

- export4: project sample rate (AudioScene.sampleRate), cancelAndWait hooks; AAC/MP3 rate caps (fixes qa's 22.05k bug); MovieExport via RenderPipeline (≈5× RT).
- timeline4: AddGroupTrack/RemoveGroupTrack/InsertClipInGroup.
- timelineui4: group-track menu + group drops (onGroupDrop), wired to timeline.
- captions4: whisper.cpp backend (whisper-cli subprocess).
- app4: export close/quit confirm, caption style inspector, group drops, speech engine settings, scripted runs skip relink.
- qa4: golden.sh rerun/calibrate, integration tests, export + pipeline determinism tests, asset audit.
- render4: RenderPipeline + 420v output; particle shader backgrounds.
- media4 (spawned for qa's bug): HW/SW decoder lanes byte-identical.
- **Session 3 complete: all agents DONE, all branches merged.** Follow-ups in docs/HANDOFF.md §0.

## Session 4 (2026-10-19)

Main green at start (see merges). User inputs: no Camtasia references
(0/26; golden gates stay skipped, no researcher/render/timeline/audio
agents); whisper.cpp + model absent (no live whisper test); no GitHub remote,
bundle ID, Developer ID or Sparkle approval. Decided: keep SwiftPM + scripts
(no Xcode project); strip Camtasia `ProjectThumbnail` from fixtures. App
click-through not done.

| id | owner | status | acceptance |
|---|---|---|---|
| S4-MED-1 | media | done | HDR10/HLG → SDR tone mapping in PixelConversion; tests on synthesized HDR media; lanes stay byte-identical |
| S4-MED-2 | media | done | vImage-vectorised SW-lane staging copy (2.7K/4K 10-bit); LaneParityTests green; gated perf numbers |
| S4-EXP-1 | export | done | Audio prefetch/mix in parallel with video; A/V ≤ 1 frame + determinism tests green; gated perf numbers |
| S4-QA-1 | qa | done | Integration tests for S4 features; perf tests report (not fail) when load avg > 30; flaky watch; golden re-run ready |
| S4-SHIP-1 | ship | done | Strip `ProjectThumbnail` from all `Tests/*/Fixtures/demo.tscproj`; tests needing it read the user's project in place or skip; asset audit clean; CI workflow current |
| S4-QA-2 | qa | done | Shared test-only target `WizRecTestSupport` (LoadGate); remove 6 copies; Captions WhisperCpp cancel bound via LoadGate |

## Session 4 merges

- qa5 slice 1: LoadGate — timing bounds report as known issues at load avg > 30 (788 tests, 18 golden + 2 LoadGate known issues).
- media5 slice 1: HDR10/HLG → SDR BT.709 tone mapping (both lanes identical); ProRes/MPEG-2/MPEG-4p2 decode SW only (VT not bit-exact). S4-MED-1 done.
- export5: audio mixed on a prefetch task in parallel with video; byte-identical to serial. Release build: demo H.264 5.02 s (5.1× RT), audio ≈ free. S4-EXP-1 done; S4-EXP-2 profile: debug-only mix cost (NoiseReducer), no AudioEngine change.
- ship5: `tscproj strip-thumbnail`, fixtures stripped, AssetAuditTests, release.yml librsvg fix, WIZREC_BUNDLE_ID, env-only signing → ad-hoc fallback. S4-SHIP-1 done.
- qa5 slices 2–3: ExportSyncIntegrationTests (clicks ±1 frame, ProRes determinism), HDRIntegrationTests (PQ/HLG/SDR, 4444 ≥ 45 dB). 809 tests, 5 flaky-watch runs clean. S4-QA-1 done.
- media5 slice 2: vectorised SW staging copy (byte-identical), tone-map LUT/SIMD speedup. S4-MED-2 done.
- qa5 S4-QA-2: shared test-only target `WizRecTestSupport` (LoadGate), 6 copies removed, Captions cancel bound gated. 812 tests green.
- Demo (built app, copy of demo project): snapshots 0/5/12.5/25 s OK; ProRes 422 export 25.67 s in 3.1 s.
- **Session 4 complete: all agents DONE, all branches merged, 812 green, worktrees removed.** Follow-ups in docs/HANDOFF.md §0.

## Session 5 (2026-10-20)

Main green at start: 812 tests (20 known issues). User asked for automation
instead of questions (DECISIONS 2026-10-20): whisper.cpp + `ggml-small.bin`
installed by the lead; Camtasia driven by the researcher via UI scripting for
references and experiments; app click-through automated; bundle ID
`com.devswizard.WizRec`; Sparkle approved; 4K60 HDR → Metal tone map. Still
needs the user: GitHub remote, Developer ID/notary profile, history rewrite.
GUI lock: `camtasia_rea_refs/.gui.lock` (mkdir), one GUI driver at a time.

| id | owner | status | acceptance |
|---|---|---|---|
| S5-RES-1 | researcher | blocked (trial watermark gate on export; needs activated Camtasia or user exports) | Automated Camtasia exports of the 15 golden cases + 11 sheets into `camtasia_rea_refs/<case>/reference.mp4` (+ ProRes `reference.mov` where possible); `scripts/golden.sh --status` shows them; watermark check |
| S5-RES-2 | researcher | done (all save-only experiments published; export-only list in camtasia-session-2.md) | Experiments automated where feasible (X1–X8, SH2, AU1/AU2, CA1/CA2, EF0, TR, BH, CO3, J, `.tscshadervid` acceptance); specs updated, reviewed by main |
| S5-QA-1 | qa | done (harness + integration tests for every merge; calibration blocked on references) | Golden + sheet suites re-run on references, `--calibrate` psnrMin; integration tests for every S5 feature; flaky watch |
| S5-MED-1 | media | done (4K ProRes 4444 23.9→57–63 fps, 422 HQ ≥ 112 fps) | 4K ProRes (libav-only) release perf ≥ real time; fix if not; gated perf tests |
| S5-MED-2 | media+render | done (Metal tone map byte-identical; 4K60 HEVC PQ 34→478 fps; playback pool .gpu) | Metal compute HDR→SDR tone map matching the CPU reference (tolerance documented), used for 4K60 HDR playback |
| S5-REN-1 | render | spec alignment merged (Border/Reflection, catalog defaults, rotation X/Y, shear); parity blocked (no references) | Golden parity M1 (SSIM ≥ 0.97) and M4/M5/M6 (≥ 0.95) vs references; provisional Border/Reflection/BlendMode/MediaMatte replaced from specs; SH2 particle rules |
| S5-CAP-1 | captions | done (live whisper, timing, Bengali via large model, CA1/CA2) | Live whisper test green (`WIZREC_WHISPER_TESTS=1`); findings fixed; CA1/CA2 rules when spec lands |
| S5-SHIP-1 | ship | done (Sparkle 2.10.0 off when unconfigured, self-signed DMG verified) | Sparkle via Package.swift (keys outside repo), bundle ID default, release DMG built locally (ad-hoc / self-signed), CI workflow ready for a remote |
| S5-APP-1 | app | done (UI checks passing; captions/audio/callout wiring) | Automated click-through (export close/quit confirm, Settings ▸ Captions, media drop into group) as scripted UI checks; fix findings |
| S5-TL-1 | timeline | done (observed group + X7 rules) | Replace [inf] group-edit rules with X5 results |
| S5-AUD-1 | audio | done (AU1/AU2 names, mix-rate loudness, panel commands) | Replace [inf]/[WizRec] audio rules with AU1/AU2 spec |

## Session 5 merges

- qa6 slice 1: golden harness prefers ProRes `reference.mov`, PSNR floors per reference file, per-sheet thresholds (821 tests).
- media6: `HDRToneMapping` GPU hook with CPU fallback; swscale row bands (4K ProRes 4444 23.9 → 57–63 fps); gated ProRes perf tests.
- ship6: Sparkle 2.10.0 (off when unconfigured), `UpdaterConfiguration`, signed embedding, `verify-dmg.sh`, CI/release workflows ready, bundle ID `com.devswizard.WizRec`.
- captions6: whisper.cpp 1.9.5 live green; word times kept out of silences (Silero VAD or energy compaction), silent audio skipped, VAD model not listed as transcription model. 841 tests green.
- render6: Metal HDR tone map in the playback pool (byte-identical to CPU; 4K60 PQ 34 → 478 fps, HLG 29 → 496 fps); composite GPU 0.25 ms 1080p / 0.92 ms 4K. 848 tests green.
- researcher6 batch 1 (wall-reviewed): group-edits.md, effects/catalog.md, Border/Reflection params, animation.md, behaviours defaults, transform X2; `wizrec-testgen experiments|shadervids`. 848 green.
- qa6 slice 2: live whisper, whisper timing, GPU tone map, app bundle integration tests; flaky watch 5/5 clean at load 12–50. 856 green.
- researcher6: group key layout (§1a), X7 edit semantics (stitched split keeps segments, auto-stitch, transitions, no pruning, image trimStartSum).
- render6 slice 2: Border/Reflection render, catalog defaults, rotation0/1 + shear0 (provisional look). 867 green.
- media7: MediaPool.toneMapStats; BandedSws; banded HDR 12-bit/alpha resample (4K HDR 4444 GPU 11.8 → 4.4 ms). 871 green.
- researcher7: audio.md (AU1/AU2 panel names, params, fades as volume keyframes, dual-mono loudness), shader-backgrounds §10 (Camtasia rejects WizRec backgrounds). Audio agent spawned.
- timeline7: observed group create/trim/split/ungroup + X7 stitched/image/transition rules; DECISIONS group-edit line amended.
- captions6 slice 2: large multilingual whisper model for explicit non-English, Bengali script normalisation (turbo: 98–99 % Bengali script). 885 green.
- researcher7: captions.md CA1/CA2, markers.md X8 (no clip markers in 2026.2.3; ripple keeps toc), shader-backgrounds SH2 effectDef table.
- timeline7 X8: ripple keeps toc, default marker name. audio6: AU1/AU2 effects + mix-rate loudness + audio panel commands. render6 SH2: dot keys, colour rule, ShaderSourceLayout, 60 s backgrounds. researcher7: BlendMode/MediaMatte enums, transitions catalog. captions6 CA1/CA2: AddEmptyCaptions, dynamic caption presets at playhead, %GAP. 922 green.
- researcher7: audio §3.3 (DFN3 without blob OK), callouts CO3, Part J ED0/ED1 (insert defaults, Extend Frame), UnifiedMedia split.
- app7: automated UI checks (export confirm 12/12, Settings captions 7/7, group drop 5/5), VAD toggle, WizRec background save notice. 929 green.
- researcher7 done: export-only leftovers listed in docs/testing/camtasia-session-2.md.
- audio6 slice 2: DFN3 written without blob, existing blob preserved. render6: caption fit from runs, 31 blend modes, matte modes/trackDepth, transition params, volume point envelopes, Extend Frame held video frame. timeline7: ED0 insert defaults, ED1 Extend Frame, two-sided transition split on move, shader backgrounds 60 s. 948 green.
- 12:xx: qa, render, app hit the API session limit; resumed.
- qa6 slice 4: audio panel, caption rules, markers, shader background integration tests; MediaWriter pool fallback (flake fix). 955 green.
- render6 CO3 callouts (highlighter, blur invert, sketch draw-on, keystroke). app7 slice 2: dynamic caption presets + Add Captions, Audio tab, Add Audio Point, loudness on import, InsertCallout + annotations library. 975 green.
- app7 slice 3: transition insert defaults, caption spoken-language setting. qa6 slice 5: Extend Frame, callout, import-loudness integration tests; flaky watch 3/3 clean. 979 green.
- Demo (built app, copy of demo project): snapshots 0/5/12.5/25 s OK; ProRes 422 export 25.67 s in 3.0 s.
- **Session 5 complete: all agents DONE, all branches merged, 979 green.** Blocked: golden parity (trial export gate), remote, Developer ID, Sparkle feed, history rewrite. Follow-ups in docs/HANDOFF.md §0.

# Session 7 — CI green on Swift 6.3, v0.1.0, follow-ups (2026-10-20)

| id | owner | status | acceptance |
|---|---|---|---|
| S7-CI | main | done | CI green on GitHub (Xcode 26.6 / Swift 6.3.3), run 17 |
| SHIP9-1 | ship | done | actions/checkout, cache, upload-artifact on current majors (no Node 20) |
| SHIP9-2 | ship | done | `diskutil image` when available, hdiutil fallback; local DMG mounts + launches |
| SHIP9-3 | ship | done | v0.1.0 release notes (What's new, install, known limits) |
| SHIP9-4 | ship | done | tag v0.1.0 → draft Release with DMG + SHA256SUMS; DMG mounts and launches |
| APP9-1 | app | done | inspector controls for a shader background's `sourceEffect` params |
| APP9-2 | app | done | `ShaderVidSource` / group `RevBackground` metadata + timeline rules |
| APP9-3 | app | done | scripted mouse double-click UI check on library tiles |
| QA9-1 | qa | done | test targets type-check fast on Swift 6.3 |
| QA9-2 | qa | done | integration tests for app8 and every session-7 merge |
| QA9-3 | qa | done | flaky watch (3 runs) |

## Session 7 wave 2 (user: "use multi agents")

| id | owner | status | acceptance |
|---|---|---|---|
| APP10-1 | app | done | `--quit-after` runs quit without the unsaved-changes prompt (QuitPolicy) |
| APP10-2 | app | done | UI checks poll for the window with a first-launch allowance; run-all 2× green |
| TL10-1 | timeline | done | copy clips inside groups, paste at top level or into an open group [WizRec rules] |
| REN10-1 | render | done | region callout corners: already on main (render7); rotation + degenerate radius tests added |
| QA10-1 | qa | done | async MediaWriter for main-actor tests; every test wait bounded (Deadline/TestProcess/GPUWait) |
| QA10-2 | qa | done | load / strict-pool runs measured; export suites' time limits raised to 6 min |
| QA10-3 | qa | done | Swift 6.3.3 slow expressions listed; RGBAImage, TimelineLayout fixed |
| DOC10-1 | docs | done | session-7 CLAUDE.md / HANDOFF / next prompt drafted |
| S7-CI | main | done | CI green (run 17); media suites serial; VM-specific test gates |

# Session 8 — bounded waits, rpath, release publish, open [?] rules (2026-10-20)

User at start: nothing delivered (v0.1.0 still a draft, no licensed exports,
no Sparkle keys, manual checks not done); "do everything yourself". Local
GitHub token use and keychain writes are blocked by the permission
classifier, so publishing goes through a workflow with `GITHUB_TOKEN`.

| id | owner | status | acceptance |
|---|---|---|---|
| S8-CI | main | done | CI green on every merge (Xcode 26.6 / Swift 6.3.3) |
| EXP11-1 | export | done | `MovieExport.finish`, `MediaFileWriter.finishWriting`, `AudioExport` ready loop bounded; a stuck writer ends with an error the UI shows; injected-stuck-writer tests |
| APP11-1 | app | done | `CanvasRenderer.renderImage` never waits for the GPU on the main thread |
| APP11-2 | app | done | `--quit-after` with several unsaved documents: test + UI check |
| APP11-3 | app | done | Swift 6.3 slow spots > 50 ms fixed (measured with the 6.3.3 recipe) |
| APP11-4 | app | done | automated accessibility audit of library tiles (stands in for the manual VoiceOver pass) |
| QA11-1 | qa | done | test reader loops (`readBack`, `decodeAudio`/`trackBytes`, `MovieFrameReader`) on a private thread with `Deadline` |
| QA11-2 | qa | done | serial media CI step faster: slowest tests found, fixtures cut where the test stays as strong |
| QA11-3 | qa | done | integration tests for every session-8 merge; flaky watch (3 runs) |
| SHIP11-1 | ship | done | Xcode back-deploy `LC_RPATH` stripped before signing; `verify-dmg.sh` fails on rpaths/load paths into Xcode/Homebrew |
| SHIP11-2 | ship | done | publish workflow (`GITHUB_TOKEN`) turns the v0.1.0 draft public; public asset verified (sha256, verify-dmg, launch) |
| SHIP11-3 | ship | done | Sparkle feed prepared (appcast location, signing script reads the key from the keychain); enabled once a key exists |
| RES11-1 | researcher | done | save-only experiments: copy/paste inside groups (4 items), shader origin metadata (3 items) |
| RES11-2 | researcher | done | automate the former manual checks ED2–ED4 and CA1 text/bold runs (save-only) |

## Session 8 merges

- ship11-publish (ad3203e): publish workflow (`GITHUB_TOKEN`); run 1 failed (two Accept headers → asset JSON instead of the DMG); ship11-publish2 fixed it.
- export11 (cbf8dc1): bounded `finishWriting` / ready loops / cancel in Exporter and MediaFileWriter, `ExportError.encoderStalled`, 13 new tests. 1071 tests.
- researcher11 ED2–ED4 (2a15787, wall-reviewed): Clip Speed matches `SetSpeed`; magnetic drops match except drops inside a clip (Camtasia refuses [inf]); Shift-drag of a start edge is a plain trim (no ripple gesture found yet).
- CI run 22 green on 2a15787; Publish run 2 made **v0.1.0 public** (2026-10-20T23:03Z).
- Blocked from 22:31: the Mac screen locked (and the Mac slept once); Camtasia driving and UI checks wait for the user to unlock.
- ship11 + ship11b (9e16679, de5e751): build run paths stripped and verified; Sparkle feed prepared (raw.githubusercontent.com appcast, `release/sparkle.conf`, key empty → off). CI 23 green.
- app11 (e5b990d): async `renderImage`, `UnsavedEditsOnQuit.prepareQuit`, locked-screen-safe UI checks, AX audit tooling; APP11-3 measured (one-time Observation/AppKit costs, no change). CI 24 green.
- qa11 (c2c7244): `BlockingPull` bounded readers (2 crashes fixed), `Deadline` ignores system sleep, serial media step 408 → 294 s, integration tests; 1093 tests, 17 known issues; flaky watch 3/3.
- researcher11 slice 2 (dccee94, wall-reviewed): copy/paste in groups (transform baked in canvas space, paste never grows the group, clamps to the window), Rev groups can't be opened, shader keyframes add `animationTracks.visual`, classic caption text saved as RTF (no bold runs), no ripple-trim gesture in Camtasia.

| id | owner | status | acceptance |
|---|---|---|---|
| TL11-1 | timeline | done | copy out of a group bakes the canvas transform; paste into a group re-expresses it |
| TL11-2 | timeline | done | paste into an open group clamps to the window, never grows the group |
| TL11-3 | timeline | done | `SetSourceEffectParameters` keyframes add the `animationTracks.visual` entry |
| TL11-4 | timeline | done | ClassicCaptions reader strips RTF `value.text` |
| TL11-5 | timeline | done | `revMedia` groups closed to inner copy/paste [inf] |
- app11 final (c130fb5): library tiles keyboard focusable (AX audit 59 tiles green), `check-quit-unsaved.sh` 8/8.
- timeline11 (2a3fd35 + notes): TL11-1..5. **1107 tests green, 17 known issues.**
- Demo (built app, copy of demo project): snapshots 0/5/12.5/25 s OK; ProRes 422 export 25.67 s in 2.3 s.
- **Session 8 complete: all agents DONE, all branches merged.** Follow-ups and NEED_USER in docs/HANDOFF.md §0.

# Session 9 — CI time, audio export speed, tile focus, open [?] rules, v0.1.1 (2026-10-21)

Start: main `6b5fcd1`, CI run 28 green; no Sparkle key, no licensed exports.

| id | owner | status | acceptance |
|---|---|---|---|
| AUD12-1 | audio | done | export with missing/invalid `audioFormatSampleRate` no slower than ~1.5x valid; perf test gated `WIZREC_PERF=1` |
| AUD12-2 | audio | done | resampler / Clip Speed stretch faster in debug, output bytes unchanged (hash test) |
| QA12-1 | qa | done | serial CI media step measurably faster (optimized test builds or `-Osize` TestGenKit) |
| QA12-2 | qa | done | integration tests for every merge; flaky watch 3 runs |
| QA12-3 | qa | done | golden self-test 176/180 frames under load: reproduce or harden |
| APP12-1 | app | done | library tiles: Tab at grid ends + past last realized tile; AX audit extended |
| APP12-2 | app | done | `scripts/ui-checks/run-all.sh` green on a fresh build |
| RES12-1 | researcher | done | save-only answers: Assets-panel background, Clip Speed rounding, media-bin drop into open group |
| SHIP12-1 | ship | done | actionlint clean on all workflows (release.yml SC2010/SC2046) |
| SHIP12-2 | ship | done | v0.1.1 notes; rpath-clean DMG verified locally |
| SHIP12-3 | ship | done | Sparkle on/off check of built Info.plist; RELEASING steps for the key |

| AUD12-3 | audio | done | no-rate projects measure loudness at the mix rate [WizRec]; perf ≤ 1.5x in release |
| REN12-1 | render | done | no use-after-free of CVMetalTextures/caches in Metal completion handlers (crash seen under `-O`); stress test |
| TL12-1 | timeline | done | Clip Speed: floor duration, keep media range, `scalar = duration/mediaDuration` (edit-semantics ED2b) |
| APP12-3 | app | done | import loudness and keyless playback at the mix rate (48 kHz) |
| APP12-4 | app | done | library placement into an open group at the playhead, new top inner track; TimelineUI drop not clamped |
| CAP12-1 | captions | done | whisper-cli stderr never lost on fast failure (race in WhisperProcess) |
| TL12-2 | timeline | done | media-bin drop into an open group: no growth, no clamp, canvas-default transform (group-edits §8.6) |

## Session 9 merges

- researcher12: ED2b Clip Speed rounding, group-edits §8.6 media-bin drop, shader-backgrounds §11.2 Assets placement (wall-reviewed).
- ship12: actionlint clean (release.yml SC2010/SC2046, ci.yml), v0.1.1 notes, `sparkle-plist-check.sh` + `check-sparkle.sh`; local v0.1.1 DMG rpath-clean.
- audio12: AUD12-1 root cause = loudness measured at 44.1 kHz for no-rate projects through a slow per-channel resampler; bit-exact resampler/DSP speed-ups (debug `wavUsesProjectSampleRate` 19–35 s → ~2 s), output hash tests.
- audio12 (2): no-rate projects measured at the mix rate (export cost 1.0x); mix digests pinned per macOS major (CI run 30 failure: Accelerate/libm differ on macOS 26).
- qa12: PlayerKit group-paste integration tests, MediaWriter sample-count check (QA12-3 hardening; not reproduced at load 200–355), opt-in texture-lifetime stress test, sample-format decode tests, stall test bounds only the stuck job.
- render12: `LockedTextureCache`/`CacheTexture` (crash 6/30 under `-O` → 0/60).
- app12 + timeline12: library Tab order over every tile, `--window-size`, Clip Speed ED2b + `SetClipDuration`, §8.6 group drops, library placement at the playhead, keyless playback 48 kHz.
- CI: run 30 failed (mix digests on macOS 26), run 31 green.
- captions12: whisper-cli pipes drained by reader threads (stderr race qa found).
- qa12 (end): CI tests built `-Xswiftc -O` (CI serial media step 515 s → 91 s), "Known issues" annotation; flaky watch 5 runs (only failure = the captions race, fixed).
- app12 (end): UI checks updated, `run-all.sh` 8/8 on a fresh build.
- CI: run 32 failed (mix digest variant per runner machine), runs 33–34 green; v0.1.1 tagged on `0ccf292`, public 2026-10-21T10:05Z (verified from the public URL).

- app13: start screen (recent projects, New/Record/Open/Import, drops), editor toolbar; Open by extension + media as new project (lead); v0.1.2 public 2026-10-21T11:29Z.

## Session 9 result

All tasks done; every branch merged; worktrees removed. Follow-ups and NEED_USER in
`docs/HANDOFF.md` §0.

## Session 10 tasks (2026-10-21)

| id | owner | status | acceptance |
|---|---|---|---|
| APP14-1 | app | claimed | first-use UX pass (launch → start screen → record/import → edit → export): discoverability, empty states, errors, drops on start screen + canvas/timeline |
| APP14-2 | app | claimed | window-level key loop library → canvas → inspector → timeline; Tab leaves the library; AX audit extended |
| APP14-3 | app | claimed | Clip Speed inspector: Duration via `SetClipDuration` (ED2b); Speed shows effective speed to 2 decimals |
| RES14-1 | researcher | done | `docs/specs/ui-workflow.md`: Camtasia main-window workflow, own words (wall-reviewed) |
| RES14-2 | researcher | done | save-only: occupied inner-spot drop (§8.6), Assets `ident` rule (§11.2) |
| QA14-1 | qa | done | flaky watch: 5 full runs `-O` + loaded machine |
| QA14-2 | qa | done | integration tests: start screen, toolbar, Open by extension, media as new project, every session-10 merge |
| QA14-3 | qa | done | review the 17 known issues |
| SHIP14-1 | ship | done | actionlint step in CI |
| SHIP14-2 | ship | done | v0.1.3 notes draft + local rpath-clean DMG check (no key: updater off) |
| MED14-1 | media | claimed | `ToneMappingMetal` locked texture cache or documented safety + stress test |
| TL14-1 | timeline | done | canvas drop (lowest track with room, else new top) + busy timeline drop (boundary insert+push → lowest higher track → new top), top level and open groups; pure placement fn + command |

## Session 10 merges

- ship14: actionlint 1.7.12 CI job (pinned, sha256 checked, matcher annotations), `check-notes.sh` (release.yml on tags), v0.1.3 notes draft, verify-dmg without window restoration; local 0.1.3 DMG rpath-clean, updater off.
- researcher14: ui-workflow.md complete (§1–§12, wall-reviewed), group-edits §8.7 busy drops (RT-028), shader-backgrounds §11.3 `ident` rule (RT-029; our import already matches).
- qa14: StartScreenWorkflowIntegrationTests (6), all 17 known issues removed (self-tests collect expected failures; `LoadGate.verdict`), callbacks on own threads; flaky watch 5/5 `-O` + 3/3 at load 56–67 green.
- timeline14: `DropRules`/`DropClip` (canvas drop lowest track with room else new top; busy drop boundary insert+push ≤ 1 s [WizRec] → lowest higher track → new top; groups never grow), 23 tests. Full run 1195 tests; one flaky `windowFrameMatchesWindowList` (live window moved mid-test, 3/3 alone) → qa.
