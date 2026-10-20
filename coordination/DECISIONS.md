# Decisions

Dated log. Newest last.

- **2026-10-19 · Name:** WizRec, a Devs Wizard product. (User.)
- **2026-10-19 · Licence:** GPL-3.0-or-later for the whole repo. (User.)
- **2026-10-19 · Minimum macOS:** 14 (`Package.swift`), for ScreenCaptureKit
  maturity and `@Observable`.
- **2026-10-19 · FFmpeg:** dynamically linked through the `CFFmpeg` system
  library target (pkg-config, Homebrew `ffmpeg`, libavcodec 63). Homebrew's
  build enables GPL parts; that is compatible with our GPL-3.0 licence. Bundling
  the dylibs into the app is an M11 task.
- **2026-10-19 · Contracts in code:** each module's `Contract.swift` holds its
  frozen public API with compiling stubs, so dependents build in parallel.
  `coordination/CONTRACTS.md` adds semantics.
- **2026-10-19 · Frame format:** decoded video is 32BGRA IOSurface-backed
  `CVPixelBuffer`s in M1. YUV paths may come later as an optimisation.
- **2026-10-19 · Metal shaders:** compiled at runtime from Swift source strings,
  so `swift build`/CI need no Metal toolchain.
- **2026-10-19 · App tooling (M1):** the app is the SwiftPM executable target
  `WizRecApp`, wrapped into `WizRec.app` by a script (Info.plist with the
  `.cmproj` document type). No Xcode project yet: no XcodeGen/Tuist installed,
  no `.pbxproj` merge conflicts between agents, and CI builds with `swift build`.
  Deviates from CLAUDE.md ("Xcode project in `App/`"); revisit before M11
  signing. *Flagged to the user.*
- **2026-10-19 · Shader backgrounds in M1:** `.tscshadervid` sources draw a
  four-colour gradient fallback from `Color0..3`. Real GLSL→MSL is M4.
- **2026-10-19 · Effects in M1:** evaluated into the plan, not drawn. Golden
  tests at SSIM ≥ 0.97 run on effect-free test projects that `qa` generates and
  the user exports from Camtasia. The demo project carries effects on every
  clip, so it is a visual smoke test in M1, not a golden one.
- **2026-10-19 · `format` agent scope:** black-box methods 1–2 of CLAUDE.md
  rule 4 only (the user's project/media files, ffprobe, the user's reference
  exports). No REA tools and no running Camtasia without explicit user
  approval routed through the lead.
- **2026-10-19 · `scalar` direction corrected:** `mediaDuration × scalar =
  duration` (scalar = 1/speed), so media time is
  `mediaStart + (t − start) / scalar`. Found independently by `qa` and
  `timeline` from the user's vlog (both non-unit scalars match exactly; the M0
  assumption matched neither). Fixed in `Clip.mediaTime`, its test, FORMAT.md
  and CONTRACTS.md.
- **2026-10-19 · One demux/decode path:** MediaEngine uses libavformat for every
  container and libavcodec for every codec (VideoToolbox hwaccel for
  h264/hevc/prores), instead of AVAssetReader for movies. One path gives exact
  container stream order, exact PTS and one frame rule for all media.
  (`media`, approved by lead.)
- **2026-10-19 · Seek target revised:** ≤ 50 ms mean holds for ≤ 1080p h264;
  long-GOP all-reference HEVC ≥ 1.5K gets ≤ 150 ms mean (bounded by decoding
  up to one GOP). Playback uses a VideoToolbox lane, scrubbing a software lane.
- **2026-10-19 · `MediaPool.cacheStats` approved** (additive API_CHANGE, for the
  player's performance overlay).
- **2026-10-19 · Build everything (user: "complete all build with multi
  agents"):** M2–M11 run in waves. Wave A = M2 editor shell, M3 edit ops,
  M4 effects start, M7 recorder, research specs. Wave B = M8 audio, M9 export,
  M10 captions. Wave C = M11 polish. Items needing the user (Camtasia checks,
  reference exports, GitHub remote, signing identity, permissions) are batched.
- **2026-10-19 · Saves keep a backup** (`project.tscproj.wizrec-backup`), no
  autosave into bundles in M2.
- **2026-10-19 · Research scope (agent "researcher"):** methods 1–2 first
  (user projects, Camtasia sample projects read in place, their
  `ProjectThumbnail` renders, ffprobe). Static REA permitted only for the
  `.trec` cursor/click stream layout (CLAUDE.md rule 4.4) with ledger entries.
  No runtime observation of Camtasia (needs user approval, not given). Nothing
  licensing-related, ever.
- **2026-10-19 · Built-in transitions and backgrounds are our own.** Camtasia's
  `.tsceffect` transitions and `.tscshadervid` backgrounds are TechSmith
  assets: WizRec renders one only from the user's copy when a project
  references it, and never ships or copies them. WizRec's own catalog is
  written from scratch.
- **2026-10-19 · MP3 export via libmp3lame (approved):** Exporter links
  `CFFmpeg` and uses avcodec `libmp3lame` + avformat `mp3` muxer. LAME is
  LGPL-2.0+, GPL-3.0 compatible; Homebrew FFmpeg already links it, so no new
  install. M11 bundling ships `libmp3lame.dylib` and its notice. (export,
  approved by lead.)
- **2026-10-19 · whisper.cpp via subprocess (session 3):** the whisper backend
  runs the `whisper-cli` executable found at runtime (Settings path, PATH,
  Homebrew dirs) with a ggml model from `~/Library/Application Support/WizRec/
  models/`. No link-time or Package.swift dependency; absent binary/model →
  backend unavailable, UI degrades. (Lead.)
- **2026-10-19 · Export audio rate:** exports use the project's
  `audioFormatSampleRate` (48 kHz fallback); AAC/MP3 map to their table rates
  (AAC ≤ 48 kHz), PCM keeps the exact rate. (export, approved.)
- **2026-10-19 · Export frames stay BGRA:** RenderPipeline can write 420v/420f
  (BT.709 [WizRec]) but end-to-end it measured slower; MovieExport keeps BGRA.
- **2026-10-19 · Deterministic decode:** VideoToolbox and libav lanes share one
  YUV→BGRA conversion with stream-level tags, so a decoded frame depends only
  on (source, frame). Exceptions documented in VideoDecoder.swift (12-bit /
  alpha formats). (media, approved.)
- **2026-10-19 · Group-edit rules [inf]** (amended 2026-10-20): superseded
  by `docs/specs/group-edits.md` §1–6 and edit-semantics X7 ([obs]: group =
  members' bounding box, re-centred; `maxDurationAttr` 0; trim-start trims
  inner clips; split copies inner content whole; ungroup cuts to the window
  and composes the transform). Still [inf] (drags not automated): a drop past
  a group's end grows it (and enclosing groups); drops before `mediaStart`
  rejected; adding/removing inner tracks keeps group timing; a group keeps
  ≥ 1 track. (timeline, approved.)
- **2026-10-19 · Build tooling (session 4, user):** keep SwiftPM + scripts
  (`scripts/make-app.sh`, release scripts); no Xcode project.
- **2026-10-19 · Fixture thumbnail (session 4, user):** strip the Camtasia
  `metadata.ProjectThumbnail` from vendored `demo.tscproj` fixtures before
  going public; tests that need it read the user's own project in place and
  skip when absent.
- **2026-10-19 · SW-only decode for ProRes/MPEG-2/MPEG-4 Part 2 (session 4):**
  VideoToolbox and libav reconstruct these codecs differently (IDCT not
  bit-exact by spec), so lanes could never match; they decode in libav only.
  HW lane: H.264/HEVC/VP9/AV1. (media, approved.)
- **2026-10-19 · HDR → SDR [WizRec] (session 4):** HDR10/HLG sources detected
  from stream `color_trc`, tone-mapped to SDR BT.709 (203 cd/m² = 1.0, max-RGB
  soft shoulder). Curve documented in `ToneMapping.swift`. (media, approved.)
- **2026-10-19 · Perf numbers come from release builds** (`swift test -c
  release -Xswiftc -enable-testing`); debug overstates DSP cost. (export.)
- **2026-10-19 · Test-only support target (session 4):** `WizRecTestSupport`
  (Tests/WizRecTestSupport) holds shared test helpers (`LoadGate`); test
  targets only, never a product dependency. (qa, approved.)
- **2026-10-20 · Session 5: automate the user's pending items (user: "do
  everything yourself, I want automated solutions").** The lead decides
  instead of asking:
  - **Camtasia runtime use approved for automation.** The researcher (only)
    may drive the user's installed Camtasia through AppleScript / System
    Events UI scripting to produce reference exports (session 1 Part A,
    session 2 sheets), experiment saves (X1–X8, SH, TR, BH, EF0, CO3, CA, AU,
    J) and the `.tscshadervid` acceptance check. Black-box only: outputs
    (exports, saved projects, thumbnails), no binary analysis beyond the
    existing `.trec` permission, nothing licensing-related. If an export
    carries a trial watermark, stop and report; never work around it.
    Projects are opened from copies under `camtasia_rea_refs/`; the user's
    `~/Documents` projects are never opened in Camtasia.
  - **GUI lock.** Only one agent drives the GUI at a time: take
    `mkdir ~/WorkDir/vibe_coding/camtasia_rea_refs/.gui.lock` (atomic; retry
    if it exists), write your name into `.gui.lock/owner`, `rm -r` it when
    done. Hold it per task, not per session.
  - **App click-through is automated** (UI scripting of `build/WizRec.app`
    plus its scripted flags) by the app agent under the GUI lock.
  - **whisper.cpp 1.9.5 + `ggml-small.bin`** installed by the lead (brew,
    Hugging Face `ggerganov/whisper.cpp`); live test runs.
  - **Bundle ID `com.devswizard.WizRec`** (Devs Wizard domain) is the default.
  - **Sparkle (MIT) approved**, keys stay out of the repo (keychain / env).
  - **4K60 HDR playback matters:** Metal compute tone map (render + media);
    the CPU path stays the reference and both lanes stay identical.
  - **Git history not rewritten.** The rewrite (`git filter-repo` dropping
    the one historical blob with the fixture `ProjectThumbnail`) is
    destructive and stays a user decision before the first push.
  - **Still needs the user:** GitHub remote (lead may not use stored
    credentials), Developer ID + notary profile (only a self-signed "WizRec
    Dev" identity exists → ad-hoc/self-signed builds).
- **2026-10-20 · Trial export gate (session 5):** the installed Camtasia
  offers only "Export with/without Watermark" on export (trial). No exports
  are made; saved `ProjectThumbnail`s are not used as substitute golden
  references without the user's ruling. Researcher continues with save-only
  format experiments (JSON diffs) and the `.tscshadervid` acceptance check.
- **2026-10-20 · GPU tone map (session 5):** `HDRToneMapping.gpu` (Metal,
  CPU LUTs) is used only for playback; export, thumbnails and golden tests
  use `.cpu`, the reference. Tolerance ≤ 1 code per channel and ≥ 99.9 %
  exact (measured: byte-identical). Per-frame fallback to CPU on error.
- **2026-10-20 · ProRes 4444 swscale in row bands** (byte-identical to one
  pass; `WIZREC_SWS_BANDS=0` disables). (media, approved.)
- **2026-10-20 · Signing without Developer ID:** self-signed/ad-hoc builds
  skip hardened runtime (no Team ID → library validation would reject the
  bundled dylibs); `WIZREC_HARDENED=1` forces it. Developer ID builds use it.
- **2026-10-20 · whisper.cpp timing:** Silero `--vad` when a
  `ggml-silero-*.bin` model is installed (`captions.whisper.vad`, default on),
  else own energy speech detection with silence compaction and time remap;
  silent audio is never sent to whisper. (captions, approved.)
- **2026-10-20 · WizRec backgrounds in Camtasia (session 5):** Camtasia
  rejects WizRec `.tscshadervid` files (it only accepts vendor-signed ones;
  shader-backgrounds.md §10). We never copy or forge a signature. WizRec
  warns on save when a project uses a WizRec background; the rest of the
  project still opens in Camtasia.
