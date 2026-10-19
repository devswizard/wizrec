# Handoff — multi-agent build session (resume point)

This is for the **lead session** that continues the WizRec build. Read
`CLAUDE.md` first (hard rules), then this file, then
`coordination/{AGENT_BRIEF,BOARD,CONTRACTS,DECISIONS}.md`.

---

## 0a. Session 2 snapshot (2026-10-19) — read this first

- **`main` is green: 700 tests** (18 known issues, all deliberate golden-harness
  self-tests). Every session-2 branch (`agent/*3`, `agent/media3`) is merged;
  no WIP. All session-2 worktrees removed. Sections 0–2 below describe
  session 1 and are history.
- **Landed in session 2:** M8 audio (mixer, BS.1770 loudness, NR/leveling/
  pitch/emphasize as own DSP, player plays through AudioMixer); M9 export
  (H.264/HEVC/ProRes/GIF/m4a/wav/mp3 via libmp3lame, presets, batch, cancel,
  A/V ≤ 1 frame, export sheet ⌘E, `--export` flag); M10 captions (commands,
  SRT/VTT, Apple Speech backend, dynamic captions rendered, Captions menu);
  M3 timeline UI (nested group editing, library apply, Remove Effect, speed
  badge, trim limits); M11 (WizRecAssets: 18 GLSL transitions now rendered,
  9 backgrounds, presets, cursors, 4 OFL fonts; release scripts bundling 16
  dylibs, ad-hoc DMG; README/CONTRIBUTING/user guide/notices; Settings,
  onboarding, opt-in local crash logs, String Catalog, a11y); QA-7/QA-8 and
  audio/captions/export integration tests; MediaEngine extension-hint fix.
- **Demos run (copies of the demo project):** playback 30 fps, audio clock,
  0 underruns; export 25.67 s 1080p H.264+AAC in 4.8 s.
- **Follow-ups (no owner yet):**
  - inner AddTrack/RemoveTrack and media drops inside open groups (TimelineEngine);
  - render-side parallelism for export > 2.2× real time;
  - audio export sample rate from `audioFormatSampleRate` (AudioScene);
  - BT.709 tag vs sRGB pixels — check against reference exports;
  - Sparkle integration (MIT; plan in docs/RELEASING.md; needs approval);
  - effect names/params for leveling/pitch/emphasize, limiter decision,
    caption rules tagged [WizRec] — all wait on AU1/AU2/CA1/CA2;
  - golden `psnrMin` once real references exist;
  - export sheet: confirm before cancelling on window close;
  - dynamic caption style in the inspector (now a sheet).
- **Next team:** spawn render + researcher (and qa) when the user delivers
  Camtasia sessions 1/2; spawn timeline for the group-track follow-up.
- **Waiting on the user:** section 3 below, plus: live speech test
  (`WIZREC_SPEECH_TESTS=1 swift test --filter AppleSpeechLiveTests` from a
  terminal with Speech permission, or Captions ▸ Transcribe in the app);
  confirm Camtasia accepts our own `.tscshadervid` backgrounds; Sparkle OK.

## 0. Snapshot (2026-10-19, end of session 1)

- The previous session ended when the API usage limit was hit. Every agent
  stopped mid-task.
- **`main` is green**: 486 tests, including 40 golden tests with 1 expected
  known issue. The golden suite prints its summary in a different format.
- **The user asked to build everything (M2–M11) with a multi-agent team.**
  Plan in `coordination/DECISIONS.md` ("Build everything").
- **Done and merged:**
  - **M0, M1:** lossless project library; read-only playback.
  - **M2:** the editor shell.
  - **M3:** the editing engine.
  - **M7:** the recorder.
  - **Specs:** all research specs.
  - **Rendering (most of M4–M6):** effects, real shader backgrounds,
    transitions, callouts, `.trec` cursor and cursor effects, motion blur,
    behaviours as fades.
  - **Media:** fast VideoToolbox decode.
  - **QA:** the session-2 checklist and effect/callout/cursor/audio test
    sheets.
- **In flight, as WIP branches (section 2):** audio (M8), export (M9),
  captions (M10), the timeline UI's nested group editing, the app's library
  panel, and ship (M11 assets).
- Every interrupted worktree's uncommitted work was committed as
  `WIP: interrupted by API rate limit (unreviewed, may not build)`. Nothing is
  lost.

## 1. What exists (module map)

| Module | State | Notes |
|---|---|---|
| `TSCProjKit` | ✅ | Lossless JSON. `ProjectBundle.create/importFile/saveWithBackup/saveAs`. `Clip.parameters` is read-only; writers use `editableParameters`. `scalar = 1/speed`. |
| `MediaEngine` | ✅ | libav demux; VideoToolbox decode with 8 frames in flight; two decode lanes per stream; LRU cache; ordered prefetch; `peaks`, `thumbnails`, `FramePolicy`; deterministic `audio()`; PDF; `sourceTracks` metadata exact. |
| `RenderEngine` | ✅ mostly | `SceneModel`/`evaluate` and the Metal compositor, plus: <br>• effects: RoundCorners, Mask, DropShadow, ColorAdjustment, BlendMode, MediaMatte, MotionBlur <br>• shader backgrounds (own GLSL→MSL; bit-exact vs Camtasia's thumbnail) and transitions <br>• callouts (own geometry + Core Text) <br>• cursor from WizRec `cursor.json` and `.trec` TSCM, plus cursor effects <br>• `OfflineRenderer` <br>Border/Reflection and the BlendMode/MediaMatte enums are provisional until EF0–EF9. |
| `TimelineEngine` | ✅ | `UndoStack` and every M2/M3 command. Each has expected-JSON tests and byte-identical revert. Includes nested moves and `SetGroupTrackFlag`. |
| `TimelineUI` | ✅ M2; M3 partly | View, gestures, ripple ⌥-drag, markers, library drops. WIP: nested group editing. |
| `PlayerKit` + `WizRecApp` | ✅ M2; M2-APP-4 partly | Editor, read-write document, import, relink, inspector, New Recording, copy/paste, Clip menu. WIP: library panel. |
| `Recorder` | ✅ | ScreenCaptureKit, AVCapture, `cursor.json` v1, HUD, `wizrec-record` CLI. **Never run for real**: Screen Recording permission is not granted yet. |
| `AudioEngine` | WIP | `AudioScene`/`AudioMixer`, BS.1770 loudness, stretch, effects. Uncommitted at the stop; now on the WIP commit. |
| `Exporter` | WIP | `ExportSession`, movie/audio/GIF export, presets. Plus a merged-ready commit `452bd37` (`OfflineRenderer.render(at:into:)`). |
| `Captions` (+ `CaptionLayout`) | WIP | SRT/VTT, CaptionLayout target, transcription, classic and dynamic captions. |
| `WizRecAssets` | WIP | Ship's own asset library, just started. |
| `TestGenKit` / `wizrec-testgen` | ✅ | 15 golden cases; EF1–EF9, CO1–CO2, CE3 and AU2 sheets. |

## 2. Resume table: one row per interrupted agent

All branches below sit in old worktrees under `.claude/worktrees/`. Every
worktree is now **clean** (all work committed). Recommended start:

1. Verify each is clean with `git -C <wt> status --porcelain`.
2. Remove the old worktrees with `git worktree remove <path>`, and
   `git worktree prune`. Keep the branches.
3. Have each new agent create its working branch from the old tip:
   `git switch -c agent/<name>3 agent/<old-branch>`. A branch can't be checked
   out in two worktrees at once.

| Agent | Old branch | Tip | State at stop | Next steps |
|---|---|---|---|---|
| audio | `agent/audio` | WIP `b51f2c3` | AUD-1/2/3 code written, never reviewed: `AudioScene`, `Mixer`, `LoudnessMeter`, `LoudnessGain`, `Stretch`, `Effects`, tests. Was writing the LoudnessGain/Effects files. | Get it building, finish AUD-1..3 (rules in `docs/specs/audio.md`: per-clip gain capped by peak), then AUD-4 (PlayerKit plays through AudioMixer, coordinate with app). |
| export | `agent/export` | WIP `5109ba8` (+ `452bd37`) | EXP-1..3 code written, unreviewed: `Session`, `MovieExport`, `AudioExport`, `AudioFeed`, `GIFEncoder/GIFExport`, `Presets`, `FrameTiming`, tests. Package.swift edited. | Build, test, REVIEW; merge `452bd37` first (approved API). Audio needs AudioMixer, so after audio lands. |
| captions | `agent/captions` | WIP `59b4eb6` (+ `e779b6f`) | CAP-1 partly: SRT/VTT, CaptionLayout target, `Transcription`, `ClassicCaptions` (`AMFile.parameters.captions`, captions.md), `DynamicCaptions`, `Swap`. Approved: RenderEngine may depend on `CaptionLayout`. | Finish CAP-1 (Apple Speech gated by `WIZREC_SPEECH_TESTS`, `ApplyTranscription`, `AddCaptions`), then CAP-2 (dynamic captions in render via `CalloutContent.dynamicCaption`). whisper.cpp only if the user installs it. |
| timelineui | `agent/timelineui` | WIP `9430f6c` | M3-TUI-1 slice 4 in progress: nested group editing (`GroupEditingTests` + edits in 9 files). | Finish nested editing (double-click opens, breadcrumb, Esc), gate timing asserts in `PerformanceTests` behind `WIZREC_PERF=1` (one flaked under load), source the library from WizRecAssets + `Compositor.renderedEffects`. |
| app | `agent/app2` | WIP `45b8b3a` | M2-APP-4: library panel (`LibraryView.swift`, menu and window edits, `make-app.sh` edit). | Finish the library panel, then the export sheet (after export lands), then M11-APP-1 (preferences, onboarding, accessibility, String Catalog, Open Recent, opt-in local crash logs). |
| ship | `agent/ship` | WIP `dec60fa` | SHIP-1 just started: `Sources/WizRecAssets/` (parameter/colour model). Font download was **approved** (4 OFL families from `raw.githubusercontent.com/google/fonts/main/ofl/…`: Montserrat[wght], Lato Regular/Bold, Bebas Neue, Caveat[wght]; record SHA-256 in THIRD_PARTY_NOTICES). | SHIP-1 (own backgrounds, transitions, cursor art, callout presets, fonts, catalog), SHIP-2 (bundled FFmpeg dylibs, sign/notarize script with env-only identity, DMG, Sparkle plan, CI), SHIP-3 (README, CONTRIBUTING, user guide, shortcut map, notices). |
| qa | `agent/qa2` | merged | QA-5/6 done, plus the sheets. | QA-7 (golden effects harness vs user references: partly done in `SheetHarnessTests`), QA-8 (M2/M3 editing integration tests: command chains, save/reopen, byte-identical undo). |
| render | `agent/render2` | merged | M4–M6 render done except items waiting on experiments. | Wait on user references (EF0–EF9, CO, CE). Optional: particle shaders (vertexCode) instead of the fallback, HDR tone mapping, perf pass. Dynamic captions with captions. |
| researcher | `agent/researcher` | merged | All specs delivered; idle. | Turn experiment results into spec updates when the user delivers sessions 1 and 2. |
| timeline, media, recorder | merged | merged | Done. | Spawn only on demand (bugs, API requests). |

## 3. Waiting on the user (one batched ask; never nag)

1. **Recorder real-capture check** (about 3 min).
   - Grant Screen & System Audio Recording to the app that runs `swift`.
   - Run `swift run wizrec-record --list`.
   - Run `swift run wizrec-record /tmp/wizrec-rec1 --seconds 6 --pause-at 2 --pause-for 2 --mic --system-audio`.
   - Check the result and paste the output.
   - Then try File ▸ New Recording in `build/WizRec.app`.
2. **Camtasia session 1**: `docs/testing/camtasia-session-1.md`. It has 15
   reference exports and experiments X1–X8. Nothing done yet.
3. **Camtasia session 2**: `docs/testing/camtasia-session-2.md`, written by
   qa. It covers:
   - shader (SH), transitions (TR), behaviours (BH);
   - effects (EF0–EF9), callouts (CO), captions (CA);
   - cursor (TM, CE) and audio (AU);
   - checks of the edit behaviour.
4. **Optional:** `brew install whisper.cpp` plus one ggml model in
   `~/Library/Application Support/WizRec/models/`. `ggml-small.bin` is good for
   Bengali. MIT-licensed.
5. **Decisions still open:**
   - the GitHub repo/remote (CI can't run without one);
   - the real bundle ID (currently `com.devswizard.WizRec`);
   - an Apple Developer ID, for signed/notarized releases;
   - Xcode project vs the current SwiftPM + script setup.

## 4. Team setup for the next session

- **Roster:** at most about 8 concurrent agents. The machine load hit a load
  average of about 30 with 9 agents, and timing tests flaked. Start with:
  audio, export, captions, timelineui, app, ship, qa. Bring in render and
  researcher when user references arrive.
- **Spawning:**
  - Use `Agent` with `subagent_type: general-purpose`, `isolation: worktree`
    and `run_in_background: true`.
  - Every prompt starts with "Read `coordination/AGENT_BRIEF.md` first", then
    gives the agent's name, its branch (from section 2) and its tasks.
  - Keep prompts short; the brief carries the rules.
- **Names vs addresses:**
  - In session 1 the `Agent` tool had no name field, so agents were addressed
    by their returned agent ID.
  - After spawning, the lead sends every agent a **ROSTER** message (name → ID)
    and records it in `coordination/ROSTER.md`.
  - If the harness supports named teammates, use names instead.
- **Talking to each other:**
  - Implementers may message each other directly about interfaces
    (`API_CHANGE`, requests), with main in copy.
  - The researcher talks only to main (clean-room wall).
- **Lead duties:**
  - Review and merge (`git merge --no-ff`, full `swift test` green first).
  - Approve API changes.
  - Publish specs after the wall review.
  - Keep `BOARD.md` current.
  - Report to the user after each merge: one line per agent.
  - Batch every `NEED_USER`.
- **Rate limits:** tell agents to **commit small and often** (WIP commits are
  fine on their branch), so a cut-off loses nothing.

## 5. Clean-room wall (mandatory)

- The researcher is the only agent allowed REA tools or Camtasia binary
  analysis.
  - So far **none was needed**; the ledger at `docs/ledger/EVIDENCE.md` says
    so.
  - Static REA is pre-approved only for the `.trec` cursor stream, which is
    now solved at file level.
  - Runtime observation needs explicit user approval.
- Specs describe behaviour in our own words. The lead reviews every spec
  before publishing: no code, no transcribed pseudocode, no symbol dumps.
- Implementers never use REA, never open Camtasia binaries or bundle assets,
  and never read the ledger.
- TechSmith assets are never copied:
  - Transitions (`.tsceffect`), backgrounds (`.tscshadervid`), callout art,
    cursors and fonts render only from the user's own copy when a project
    references them.
  - WizRec ships its own originals (WizRecAssets).
- Nothing licensing-related, ever.

## 6. Lessons from session 1

- **The format had surprises:** `scalar = 1/speed`; keyframes run on media
  time; video size comes from `sourceTracks[trackNumber].trackRect`.
  - Implementers found them by checking real files.
  - Ask agents to verify against the user's projects early.
- **`metadata.ProjectThumbnail` is a Camtasia render** of the canvas at the
  saved playhead. It is the best black-box reference.
  - Sample projects don't have one; the user's do.
  - Experiments are designed as "edit → save" so each save yields a reference.
- **`Package.swift` conflicts** happen when agents add targets in parallel. The
  lead resolves them by keeping both sides.
- **Perf/timing tests** must be gated (`WIZREC_PERF=1`).
- **Never run real capture, speech or other permission-bound tests**
  without the user.
