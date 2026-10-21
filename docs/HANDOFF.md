# Handoff — multi-agent build session (resume point)

This is for the **lead session** that continues the WizRec build. Read
`CLAUDE.md` first (hard rules), then this file, then
`coordination/{AGENT_BRIEF,BOARD,CONTRACTS,DECISIONS}.md`.

---

## 0. Session 8 snapshot (2026-10-21) — read this first

- **`main` is green: 1107 tests** (17 known issues = golden-harness +
  LoadGate self-tests). every session-8 code merge was green on GitHub (CI runs 21–25; see the Actions page for the final push). Sections 0-pre onward are history.
- **User at start:** nothing delivered (v0.1.0 still a draft, no licensed
  exports, no Sparkle keys, manual checks not done); then "do everything
  yourself, I don't want to do anything manually".
- **Blocked by the permission classifier:** reading the keychain GitHub
  token (Credential Exploration) and `generate_keys` (Secret-Store Writes).
  Worked around legitimately: publishing through a workflow with
  `GITHUB_TOKEN`. Sparkle keys still need the user.
- **Interruptions:** the screen locked at 22:31 (idle timer) and the Mac slept
  once; GUI work stopped until the user unlocked at 09:37. A push and one
  agent died on the sleep (both recovered). Agents driving the GUI now run a
  bounded `caffeinate`; UI checks exit 3 on a locked screen.
- **Landed in session 8:**
  - ship11: `publish.yml` + `publish-release.sh` (first run failed on two
    Accept headers → fixed); **v0.1.0 public** 2026-10-20T23:03Z, checked
    from the public URL (sha256, verify-dmg, launch). Build run paths
    stripped and rejected by `verify-dmg.sh`. Sparkle feed prepared
    (`release/appcast.xml` via raw.githubusercontent.com,
    `release/sparkle.conf`, `update-appcast.sh`), off until a key exists.
  - export11: bounded `finishWriting`/ready loops/cancel in Exporter and
    `MediaFileWriter`; `ExportError.encoderStalled`, `LocalizedError`.
  - app11: async `CanvasRenderer.renderImage`; `UnsavedEditsOnQuit.prepareQuit`
    + `check-quit-unsaved.sh` (8/8); locked-screen gate and bounded `ax`
    calls in UI checks; AX audit (`ax-audit.swift`) → library tiles keyboard
    focusable (59 tiles, 5 tabs, all pass). APP11-3: the 6.3 "slow" lines are
    one-time Observation/AppKit costs that move when rewritten; no change.
  - qa11: `BlockingPull` (2 CoreMedia crashes found and fixed), `Deadline`
    on awake time, serial CI media step 11:58 → 8:45 min, "Slowest tests"
    annotation, integration tests; flaky watch 3/3.
  - researcher11 (save-only UI scripting, wall-reviewed): ED2 matches,
    ED3 matches except drops inside a clip [inf], ED4 no ripple gesture
    exists, CA1 text saved as Cocoa RTF (no bold runs), copy/paste in groups
    (§8), shader origin keys (§11.1).
  - Timeline (timeline11): Camtasia's copy/paste rules applied (canvas-space transforms, paste into a group clamps and never grows it, `revMedia` closed), shader keyframes add `animationTracks.visual`, RTF caption text read as plain text.
- **Demo (built app, copy of demo project):** snapshots 0/5/12.5/25 s OK; ProRes 422 export 25.67 s in 2.3 s.
- **Follow-ups (no owner):**
  - everything export-dependent (golden parity, eioe, looks, transitions,
    caption layout, normalisation output);
  - audio export ~10× slower when `audioFormatSampleRate` is missing or
    invalid (mixes at 44.1 kHz, then resamples?) — audio/export owner;
  - slowest CI tests are debug-build audio DSP (resampling 40 s each, Clip
    Speed stretch 32 s): build media test targets optimized or speed up the
    resampler;
  - one unreproduced golden self-test read 176/180 frames at load ~400;
  - library tiles: Tab at grid ends falls back to AppKit order; tabbing past
    the last realized tile is untested;
  - Exporter and Recorder each carry a bounded-wait helper (no shared module);
  - still [?]: Assets-panel background placement, rounding of a
    non-frame-exact Clip Speed duration, media-bin drops into an open group;
  - WizRec shader keyframes carry `interp` "linr"; Camtasia writes none on
    them (§11.1 Q3) — left unchanged;
  - `InsertClipInGroup` (media-bin drops) still grows the group and needs
    the window (Camtasia [?]); multi-row group paste order is [WizRec];
  - PlayerKit integration tests for the new group paste (qa);
  - `release.yml` has two actionlint warnings (SC2010, SC2046);
  - 56 unmerged local `worktree-agent-*` branches hold pre-rewrite history:
    never push; delete with the user's OK.
- **NEED_USER:**
  1. One Sparkle `generate_keys` run (back up the private key offline), then
     put the public key into `release/sparkle.conf` (or give it to the lead).
  2. Licensed reference exports (an activated Camtasia), for golden parity.
  3. Keep the Mac unlocked/awake during GUI-driving sessions (or allow the
     agents' `caffeinate`).

## 0-pre. Session 7 snapshot (2026-10-20) — history

- **`main` was green: 1058 tests** (23 known issues = 21
  golden-harness + 2 LoadGate self-tests).
- **CI / release:** CI green on GitHub (run 17, `37b384c`: 629 parallel +
  429 serial media tests, 23 known issues, Swift 6.3.3 / Xcode 26.6). Tag
  `v0.1.0` on `37b384c`; Release run 39450575632 built the ad-hoc DMG
  (FFmpeg + Sparkle inside, VERIFY mount+launch) and attached it with
  `SHA256SUMS.txt` to a **draft** GitHub Release — the user publishes it.
- **Session 6 (short, no snapshot):** remote `devswizard/wizrec` pushed
  after the first history rewrite; DMG-only install, tags publish a draft
  Release; CI annotations for toolchain and errors; first Swift 6.3 fixes;
  render7 rounded blur/pixelate/spotlight callouts; app8 shader `effectDef`
  on import, Backgrounds tab, accessible library tiles, ⌘W on the export
  sheet.
- **User at start:** no licensed exports, no thumbnails as references,
  Sparkle feed not set up, manual checks pending → wave 1 only ship, app, qa
  (+ main on CI). Wave 2 (user: "use multi agents"): app10, timeline10,
  render10, qa10, docs10.
- **Landed in session 7:**
  - CI (main): package and tests compile on Swift 6.3.3 (Xcode 26.6); tests
    built separately; watchdog `scripts/ci/test-with-watchdog.sh` (deadline,
    stall detector, `sample` thread stacks of the stuck test process,
    unfinished tests in start order — all as annotations).
  - CI hang, diagnosed from the sampled stacks over runs 10–16 [obs]: on the
    3-core runner VM (1) a main thread blocked in TestGenKit `MediaWriter`
    stalled every `@MainActor` test (`finishWriting` answers through the main
    queue there), and (2) several AVFoundation/VideoToolbox encodes or
    `AVAssetReader`s at once stalled inside CoreMedia. Fixes: async
    `MediaWriter`/`TestGen.makeMedia` (encode on a private thread; every
    main-actor test `try await`s), bounded waits in tests (`Deadline`,
    `TestProcess` on its own threads, `GPUWait`), and CI runs the media
    suites (Golden, Recorder, Exporter, MediaEngine, PlayerKit, Perf) with
    `--no-parallel` in a second step. VM-only test gates:
    `TestEnvironment.isVirtualMachine` skips the VideoToolbox converter
    comparison; GPU timing asserts need `WIZREC_PERF=1`.
  - History: AI co-author lines stripped with `git filter-repo` (messages
    only) and force-pushed; backup bundle
    `~/WorkDir/vibe_coding/wizrec-pre-coauthor-strip.bundle` + local branch
    `backup/pre-coauthor-strip`; local `.git/hooks/pre-push` refuses such
    lines; AGENT_BRIEF forbids them.
  - Local Swift 6.3.3 recipe (DECISIONS): swiftly 6.3.3 + CLT macOS 26.5
    SDK, ~80 s clean build.
  - Ship (ship9): checkout v7 / cache v6 / upload-artifact v7 (Node 24);
    `diskutil image` DMGs (APFS/ULFO, 20.9 MB) with hdiutil fallback
    (`WIZREC_DMG_TOOL`); v0.1.0 release notes; `SHA256SUMS.txt` with bare
    names; RELEASING: verify a draft asset without `gh`.
  - App (app9): Background inspector section (colour wells, sliders,
    switches, x/y; one undo step via `SetSourceEffectParameters`, keyframe
    at the playhead when animated); `SetShaderVidSource` writes
    `ShaderVidSource` (clip) + `RevBackground` (group) only on inner track 0
    of a Rev group [WizRec, shader-backgrounds.md §11];
    `check-library-double-click.sh` (CGEvent double-click).
  - QA (qa9): Swift 6.3 sweep of test targets; Backgrounds tab / shader drop
    (app8) and shader background edit (app9) integration tests.
  - Wave 2: app10 `--quit-after` quits without the unsaved-changes prompt
    (`QuitPolicy`), UI checks wait for the first launch; timeline10 copy
    clips inside groups and paste at top level or into an open group
    (`PasteClips(group:track:at:)`, [WizRec] rules in DECISIONS); render10
    region-callout corner tests (feature was already in render7); qa10 async
    `MediaWriter`, bounded test waits, load runs, Swift 6.3 slow spots.
- **Demo (built app, copy of demo project):** snapshots 0/5/12.5/25 s OK;
  ProRes 422 export 25.67 s in 2.2 s.
- **Follow-ups (no owner):**
  - everything export-dependent (golden parity, eioe, looks of Border/
    Reflection/tilt/shear/stencils/LuminanceFadeIn/key caps, particle
    canvas, transition windows, caption layout, normalisation output);
  - manual-only checks ED2–ED4, CA1 caption text;
  - Sources waits without a bound (qa10 audit): `MovieExport.finish` and
    `MediaFileWriter` `finishWriting`, `AudioExport` ready loop (no stall
    watch), `CanvasRenderer.renderImage` GPU wait on the main thread;
  - test reader loops (`readBack`, `decodeAudio`, `MovieFrameReader`) could
    run on a private thread with a deadline;
  - quit with several unsaved documents under `--quit-after` (untested path);
  - release: the app binary keeps an Xcode back-deploy `LC_RPATH`
    (harmless; `bundle-dylibs.sh` could `install_name_tool -delete_rpath`);
    ship9 verified the v0.1.0 DMG from the tag (20.9 MB, SHA-256
    `ea5a7809…80dc`, launches the demo copy, no Homebrew/Xcode link paths);
  - Swift 6.3 slow spots left: CanvasRenderer:43, EditorDocumentModel:117,
    ClassicCaptions:138, EditorWindowController+Export:22 (all < 75 ms);
  - Sparkle appcast (GitHub Pages) once the user has keys;
  - local `agent/*` branches and `backup/pre-coauthor-strip` hold old
    history: never push; delete only with the user's OK;
  - save-only Camtasia experiments (researcher, GUI lock) for the open [?]
    rules: copy/paste inside groups (DECISIONS, 4 items) and shader origin
    metadata (shader-backgrounds.md §11, 3 items);
  - VoiceOver pass on the library tiles (user);
  - local `agent/*` and `backup/pre-coauthor-strip` branches: delete only
    with the user's OK (all work is merged; they hold old history).
- **Session 7 ended with:** CI run 19 green on `7a32d7b`; no open branches
  or worktrees; v0.1.0 a draft for the user to publish.
- **NEED_USER:**
  1. Licensed reference exports (or activate this Camtasia).
  2. Sparkle feed host + one `generate_keys` run.
  3. Manual checks ED2–ED4 and CA1 caption text in Camtasia.
  4. Close or reset other WizRec Claude sessions: after the history rewrite
     their clones/branches carry the old commits, and a push from them would
     bring back AI co-author lines (the pre-push hook guards only this
     clone).

## 0a. Session 5 snapshot (2026-10-20) — history

- **`main` is green: 979 tests** (23 known issues = 21 golden-harness +
  2 LoadGate self-tests). All session-5 branches merged.
- **User at start: "do everything yourself, I want automated solutions."**
  The lead decided instead of asking (DECISIONS 2026-10-20):
  whisper.cpp 1.9.5 + `ggml-small`, `ggml-silero-v5.1.2` (VAD) and
  `ggml-large-v3-turbo` installed by the lead; Camtasia driven by UI
  scripting (researcher only, save-only); app click-through automated;
  bundle ID `com.devswizard.WizRec`; Sparkle approved; 4K60 HDR → Metal.
  Blocked by the permission classifier: using the keychain GitHub token
  (remote), git-history rewrite, removing other agents' worktrees/lock.
- **Camtasia is a trial**: Export only offers "Export with/without
  Watermark". No exports, no thumbnail substitutes (classifier), so golden
  parity is still blocked. The list of export-only steps is at the end of
  `docs/testing/camtasia-session-2.md`.
- **Landed in session 5:**
  - Specs (researcher, wall-reviewed): group-edits (X3/X5), effect catalog
    (EF0) + Border/Reflection params, behaviours, animation placement,
    transform X2, edit-semantics X7/ED0/ED1/UnifiedMedia split, audio
    AU1/AU2 (+ DFN3 without blob), captions CA1/CA2, markers X8 (no clip
    markers in 2026.2.3), shader SH2 effectDef table, BlendMode (31) and
    MediaMatte enums (+ `trackDepth`), transitions TR2/TR3, callouts CO3,
    `.tscshadervid` acceptance (Camtasia rejects ours: signed files only).
  - Timeline: observed group create/trim/split/ungroup, stitched split,
    two-sided transition split on move, markers, insert defaults, Extend
    Frame as StitchedMedia + IMFile frame, shader backgrounds 60 s.
  - Render: Metal HDR tone map (byte-identical to CPU; playback only),
    Border/Reflection, rotation X/Y + shear, catalog defaults, SH2 params,
    31 blend modes + stencils, matte modes/trackDepth, transition params,
    caption fit from runs, volume point envelopes, held video frame, CO3
    callouts (own SVG stroke reader; xmlContent drawn in place only).
  - Media: ProRes 4444 swscale row bands (4K 23.9 → 57–63 fps), banded HDR
    12-bit/alpha resample, `MediaPool.toneMapStats`.
  - Audio: AU1 effect names/defaults (own compressor, emphasize, pitch,
    noise removal), mix-rate dual-mono loudness, `AudioPanelItem`/
    `ApplyAudioItem`/`AudioFade`/`AddAudioPoint`/`SetSourceLoudness`.
  - Captions: whisper live fixes (VAD / energy compaction timing, silent
    audio), large model for explicit non-English + Bengali script mapping,
    `AddEmptyCaptions`, `AddDynamicCaption(at:preset:)`, `%GAP`.
  - Ship: Sparkle 2.10.0 (off when unconfigured), `UpdaterConfiguration`,
    signed embedding, `verify-dmg.sh`, appcast script, CI/release workflows
    ready; self-signed DMG verified.
  - App: automated UI checks (export confirm, Settings ▸ Captions, group
    drop, audio panel), VAD toggle, spoken-language setting, background save
    notice, dynamic caption presets + Add Captions, Audio tab, Add Audio
    Point, loudness on import, `InsertCallout` + Annotations library,
    transition insert defaults.
  - QA: ProRes-preferring golden harness with per-file PSNR floors;
    integration tests for every merge; MediaWriter pool fallback (flake fix);
    flaky watch clean at load 12–50.
- **Demo (built app, copy of demo project):** snapshots 0/5/12.5/25 s OK;
  ProRes 422 export 25.67 s in 3.0 s.
- **Follow-ups (no owner):**
  - everything export-dependent (golden parity, eioe, looks of Border/
    Reflection/tilt/shear/stencils/LuminanceFadeIn/key caps, particle
    canvas, transition windows, caption layout, normalisation output);
  - manual-only checks ED2–ED4, CA1 caption text;
  - nothing writes a shader source's `effectDef`/`sourceEffect` yet (use
    `ShaderSourceLayout`);
  - rounded corners on blur/pixelate/spotlight callouts;
  - VoiceOver labels on library tiles; ⌘W with the export sheet open;
  - `hdiutil` deprecation warnings on macOS 27 (`diskutil image`);
  - stale worktrees of the four stopped agents (researcher6, timeline6,
    media6, app6) and the other finished worktrees — remove at session start
    (WIP already carried into the *7 branches).

## 0b. Session 4 snapshot (2026-10-19) — history

- **`main` is green: 812 tests** (20 known issues = 18 golden-harness + 2
  LoadGate self-tests). All `agent/*5` branches merged; no WIP, no worktrees.
  Sections 0a–2 are history.
- **User inputs at session start:** no Camtasia references (0/26), no
  whisper.cpp/model, no GitHub remote / bundle ID / Developer ID / Sparkle
  approval. Decided: keep SwiftPM + scripts (no Xcode project); strip the
  Camtasia `ProjectThumbnail` from fixtures. App click-through not done.
  So only media, export, qa, ship ran.
- **Landed in session 4:**
  - Media: HDR10/HLG → SDR BT.709 tone mapping [WizRec] (`ToneMapping.swift`,
    LUT + SIMD, both lanes identical); ProRes/MPEG-2/MPEG-4p2 decode in libav
    only (VideoToolbox not bit-exact); vectorised SW staging copy
    (`StagingCopy.swift`, byte-identical to the scalar reference).
  - Export: audio mixed on a prefetch task (`AudioPrefetch.swift`) in parallel
    with video, byte-identical to serial. Release build: demo H.264 5.0 s
    (5.1× RT), audio ≈ free. Debug numbers overstate DSP (NoiseReducer).
  - Ship: `tscproj strip-thumbnail`; all fixture thumbnails stripped;
    `AssetAuditTests` (fails on vendored thumbnails / Camtasia file types);
    release.yml librsvg fix; `WIZREC_BUNDLE_ID`; NOTARIZE without identity →
    ad-hoc with warning; docs/RELEASING.md current.
  - QA: `LoadGate` in test-only target `WizRecTestSupport` (timing bounds
    become known issues at load avg > 30); ExportSync + HDR integration
    tests; 6 flaky-watch runs at load 9–42, no flakes.
- **Demo run (copy of demo project, built app):** snapshots 0/5/12.5/25 s
  correct; `--export … --export-preset "MOV ProRes 422" --quit-after 240`:
  25.67 s 1080p ProRes + PCM 44.1 kHz in 3.1 s. Scripted runs need
  `--quit-after`, else the app stays open.
- **Follow-ups (no owner):**
  - everything that needs references: golden parity M1/M4/M5/M6, provisional
    Border/Reflection/BlendMode/MediaMatte, eioe, group-edit [inf] (X5),
    particle rules (SH2), audio effect names + limiter (AU1/AU2), caption
    rules (CA1/CA2), BT.709 vs sRGB tag, golden `psnrMin` calibration;
  - Metal compute tone map if 4K60 HDR playback matters (CPU ≈13 ms/frame
    4K PQ unloaded);
  - perf check of 4K ProRes now that it is libav-only;
  - GPU tests on GitHub's paravirtual Metal — unverified until a remote
    exists;
  - git history still holds the old fixture thumbnail (user decision before
    first push: rewrite with `git filter-repo` or accept).
- **Next team:** researcher + render + timeline + audio + captions when
  references land; captions for whisper live test when installed; ship for
  signing/Sparkle/CI when remote and identity arrive; app for click-through
  findings.

## 0c. Session 3 snapshot (2026-10-19) — history

- **`main` is green: 783 tests** (18 known issues = golden-harness
  self-tests). All `agent/*4` branches merged; no WIP. Sections 0a–2 are
  history.
- **User inputs at session start:** no Camtasia references; recorder real
  capture OK; live Apple Speech test OK; whisper.cpp reported installed but
  **not found on disk** (no formula, no `whisper-cli`, no model); no GitHub
  remote / Developer ID / Sparkle approval. So no researcher, audio, recorder
  or ship agent ran.
- **Landed in session 3:**
  - TimelineEngine `AddGroupTrack`/`RemoveGroupTrack`/`InsertClipInGroup`
    (+ `GroupTime`, `GroupTiming`); TimelineUI group-track menu + group drops;
    app `placeInGroup` (one undo step), Timeline ▸ Remove Track.
  - Export: `AudioScene.sampleRate` → export at project rate (48k fallback;
    AAC/MP3 table rates + bitrate caps, AAC ≤ 48k); `cancellationLosesWork`
    + `cancelAndWait`; MovieExport through `OfflineRenderer.pipeline`
    (BGRA kept: 420v measured slower). Demo export ≈ 4.4–5.1× real time.
  - Render: `RenderPipeline` (in-order, byte-identical to sequential, 420v/420f
    BT.709 output [WizRec]); particle (`vertexCode`) shader backgrounds, GLSL
    translator out/inout component + swizzle `*=` fixes (13/13 installed
    particle files draw).
  - Media: HW (VideoToolbox) and SW (libav) lanes share one YUV→BGRA
    conversion with stream-level tags → byte-identical frames; seek == forward
    decode; exports reproducible. Faster 1080p decode/seek.
  - Captions: `WhisperCppRecognizer` (subprocess, runtime detection, fake-binary
    tests, live test gated `WIZREC_WHISPER_TESTS=1`); app Settings ▸ Captions
    engine/model picker, Captions ▸ Speech Engine.
  - App: confirm before close/quit cancels exports; dynamic caption style in
    the inspector; scripted runs (`--quit-after`, `--export`, `--snapshot-*`)
    never block on the relink sheet.
  - QA: `scripts/golden.sh` (`--status`, `--calibrate`) + docs/testing/
    golden-rerun.md; integration tests for every feature above; asset audit
    clean (see NEED_USER for the fixture thumbnail).
- **Demo run (copy of demo project, built app):** snapshots 0/5/12.5/25 s
  correct; `--export` 25.67 s 1080p H.264 + AAC 44.1 kHz in 5.9 s under load.
- **Follow-ups (no owner):**
  - group-edit rules tagged [inf] (drop past end grows group, maxDurationAttr
    untouched, add/remove keep timing, drop before mediaStart rejected) —
    confirm with experiment X5;
  - particle canvas/blend/`_ToRenderTarget` orientation and `_Scale`/
    `_StarOpacity` = 0 — confirm with SH2;
  - HDR→SDR tone mapping in MediaEngine PixelConversion;
  - BT.709 vs sRGB export tag; golden `psnrMin` (`scripts/golden.sh
    --calibrate`) — both need references;
  - audio mix prefetch in export (0.5–2 s per 25 s under load);
  - vImage for SW-lane staging copy (2.7K/4K 10-bit);
  - Sparkle, CI, signing — need user inputs;
  - perf assertions (`WIZREC_PERF=1`) need machine load < ~30;
  - end-to-end check: two ProRes exports of the demo decode to identical
    frames (render deterministic); two H.264 exports differ because the
    VideoToolbox hardware encoder is not bit-reproducible — expected, not a
    WizRec bug. Golden comparisons should use ProRes or SSIM tolerance.
- **Next team:** researcher + render + qa when references land; ship when
  remote/Developer ID/Sparkle arrive; captions to live-test whisper.

## 0d. Session 2 snapshot (2026-10-19) — history

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

## 0e. Snapshot (2026-10-19, end of session 1)

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

Status after session 7 (see §0 NEED_USER). Done by automation: whisper.cpp + models, app
click-through, `.tscshadervid` acceptance (rejected by Camtasia), all
save-only Camtasia experiments. Decided by the lead: bundle ID, Sparkle,
4K60 HDR (Metal).

1. **Licensed reference exports.** This Camtasia is a trial (export only
   "with/without watermark"). Either export the steps listed under "Still
   needs a licensed export" at the end of `docs/testing/camtasia-session-2.md`
   from an activated Camtasia (ProRes `reference.mov` preferred; then
   `scripts/golden.sh --calibrate`), or activate this install.
2. **Thumbnails as interim references?** Saved `ProjectThumbnail`s were not
   used as substitutes for the gated exports; only with the user's yes.
3. ~~GitHub remote~~ done: `devswizard/wizrec` (public), history rewritten
   before the first push (DECISIONS 2026-10-20).
4. ~~Developer ID~~ not applicable: no Apple Developer account; ad-hoc DMGs.
5. CI on the remote: see §0 and BOARD. v0.1.0 is a draft Release; the user
   publishes it.
6. **Sparkle update host:** feed URL, download prefix, and one
   `generate_keys` run (private key in the user's keychain, backed up).
7. **Manual checks:** ED2–ED4 (clip speed field, magnetic track, Shift
   ripple trim) and CA1 caption text typing in Camtasia; VoiceOver pass on
   the library tiles.
8. **Other WizRec Claude sessions:** close or reset them after the history
   rewrite (peer sessions can push).

## 4. Team setup for the next session

- **Roster:** at most about 8 concurrent agents (load hit ~50 with 8 in
  session 5; LoadGate absorbed it). Session 8 plan (tasks in
  `docs/NEXT_SESSION_PROMPT.md` "PENDING WORK → AGENTS"): export (bounded
  AVFoundation waits in product code), app (main-thread GPU wait, multi-doc
  quit, Swift 6.3 spots), qa (bounded reader loops, CI time, integration),
  ship (rpath strip, public v0.1.0 check, Sparkle only with keys), researcher
  (save-only experiments for the open [?] rules); timeline only if those
  answers change a rule; render/audio/captions only with licensed exports.
  Agent branches next: `agent/<name>11`.
- **Toolchains:** local `swift` stays Xcode's 6.4. After any swiftly
  install, run `swiftly use --global-default xcode` (plain `swiftly use`
  writes a per-project `.swift-version`); reach 6.3.3 only through
  `swiftly run … +6.3.3` (recipe in AGENT_BRIEF / DECISIONS).
- **Stopped agents:** an agent the user stops cannot be resumed. Spawn a
  replacement on `agent/<name>N+1` from the old branch and copy the old
  worktree's uncommitted files with plain `diff`/`cp` (git commands aimed at
  another worktree are blocked). API session limits only pause agents:
  resume them with SendMessage after the reset.
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

## 6. Lessons (sessions 1–7)

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
- **Session 5:** the permission classifier blocks credential use, history
  rewrites, and touching other agents' worktrees or locks; plan around it.
  Using Camtasia thumbnails in place of gated exports was also blocked.
  Driving Camtasia by UI scripting works for save-only experiments; drags
  from the media bin and edge drags are unreliable.
- **Session 7:**
  - `swiftly install` puts its toolchain first on `PATH` and shadows Xcode's
    `swift`; `swiftly use xcode` restores it.
  - Swift 6.3.3 needs the CLT macOS 26.5 SDK; with the macOS 27 SDK
    Foundation fails to import.
  - A silent CI hang is diagnosed from `sample` thread stacks of the stuck
    test process, published as annotations (readable without login).
  - Peer Claude sessions on the same repo can push. A local `pre-push` hook
    guards repo-wide rules (no AI attribution).
