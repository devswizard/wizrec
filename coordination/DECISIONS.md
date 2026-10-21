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
- **2026-10-20 · Audio aligned to audio.md AU1/AU2 (session 5).** WizRec
  choices where the spec is silent: Emphasize ducks other tracks to
  1 − `emphasizeAmount`; WinCompression release is linear at 20 dB per
  release time; Pitch `effectBlend` is a linear wet/dry mix; normalisation
  keeps the peak cap until AU2 output can be compared. (audio, approved.)
- **2026-10-20 · MediaMatte `trackDepth` [WizRec]:** missing → only the
  track directly below; explicit → that many tracks (10002 = all below).
- **2026-10-20 · Whisper model choice:** explicit non-English language
  prefers an installed multilingual large model (large-v3-turbo first);
  English/auto keep small; a Settings choice wins. `-l bn` output is mapped
  to Bengali script. (captions, approved.)
- **2026-10-20 · Remote and history (user):** GitHub remote
  `https://github.com/devswizard/wizrec` (public). History rewritten before
  the first push with `git filter-repo` (fresh clone; the one blob holding
  the fixture `ProjectThumbnail` stripped; HEAD tree unchanged). Backup:
  `~/WorkDir/vibe_coding/wizrec-pre-rewrite.bundle`. Commit hashes quoted in
  docs before this point refer to the old history; local `agent/*` branches
  still carry the old history and are never pushed.
- **2026-10-20 · No Apple Developer account (user):** releases are ad-hoc
  signed, never notarized; README documents the Gatekeeper "Open" step.
  Developer ID is no longer a pending item.
- **2026-10-20 · No AI attribution on GitHub (user, session 7):** no
  `Co-Authored-By: Claude…` or "Generated with…" lines in commits, merges,
  tags, PRs or release notes. History rewritten with `git filter-repo`
  (messages only; every tree, date and author unchanged) and force-pushed
  (`7c6dc50`). Backup: `~/WorkDir/vibe_coding/wizrec-pre-coauthor-strip.bundle`
  and local branch `backup/pre-coauthor-strip`. A local `.git/hooks/pre-push`
  refuses pushes that carry such lines.
- **2026-10-20 · Shader background origin metadata [WizRec] (app, approved):**
  `ShaderVidSource` (clip) and `RevBackground` (group) are written only when a
  library background lands on inner track 0 of a `revMedia` group; never for
  top-level placements, plain groups or imports. `RevBackground` is kept when
  the clip is moved or deleted; `sourceEffect` keyframes add nothing to
  `animationTracks.visual`. All three are [?] in shader-backgrounds.md §11.
- **2026-10-20 · Local Swift 6.3 check (session 7):** swiftly 6.3.3 with the
  Command Line Tools' macOS 26.5 SDK reproduces the CI compiler
  (`DEVELOPER_DIR=/Library/Developer/CommandLineTools
  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swiftly run
  swift build --build-tests --scratch-path <tmp> +6.3.3`; ~80 s clean). The
  macOS 27 SDK does not work with 6.3.3 (Foundation fails to import).
- **2026-10-20 · Copy/paste inside groups [WizRec] (timeline, approved; superseded by 2026-10-21 "Copy/paste with groups"):**
  a copy must come from one container (top level, or the inner tracks of one
  group); a nested clip keeps its own duration and `scalar` (the group's
  speed/transform is not baked in); paste into an open group maps the playhead
  to inner time, must land inside the group's visible window, puts overlaps on
  a new inner track and grows the group; group keys (`RevBackground`,
  `RevLook`) never travel with a nested clip, `ShaderVidSource` does, and a
  pasted background sets no `RevBackground`. Open for a save-only researcher
  experiment: what Camtasia does in each case.
- **2026-10-20 · CI test layout (session 7):** GitHub's 3-core macOS VMs stall
  when several AVFoundation/VideoToolbox sessions run at once, so CI runs the
  media suites (Golden, Recorder, Exporter, MediaEngine, PlayerKit, Perf)
  `--no-parallel` in a second step and the rest in parallel; `@MainActor`
  tests never wait synchronously on AVFoundation (async `MediaWriter`);
  every test wait is bounded; VM-only gates via
  `TestEnvironment.isVirtualMachine`; GPU timing asserts need
  `WIZREC_PERF=1`. First green run: 17 (`37b384c`).
- **2026-10-20 · v0.1.0 (session 7):** tag on the CI-green commit `37b384c`;
  the Release workflow attached the ad-hoc DMG to a draft Release. The user
  publishes it.
- **2026-10-21 · Publishing without a personal token (session 8, user: "do everything yourself"):**
  local use of the keychain GitHub token and keychain writes are blocked by the permission
  classifier, so drafts are published by `.github/workflows/publish.yml` with the workflow's
  own `GITHUB_TOKEN`. A push to main that changes `release/publish` (first line = tag)
  triggers it. `scripts/release/publish-release.sh` checks the tag, AI-attribution-free notes,
  `SHA256SUMS.txt` and `verify-dmg.sh` before flipping draft → public; idempotent. v0.1.0 went
  public this way (run 2, 2026-10-20T23:03Z).
- **2026-10-21 · Release builds strip build-machine run paths (session 8):** `bundle-dylibs.sh`
  deletes `LC_RPATH`s into Xcode/CLT/toolchains/Homebrew/`/usr/local` before signing (bounded,
  fails loudly); `verify-dmg.sh` rejects any such load or run path in every Mach-O.
  `allow-build-rpaths` on the `release/publish` line (or `WIZREC_ALLOW_BUILD_RPATHS=1`)
  downgrades this to a warning, for v0.1.0 only.
- **2026-10-21 · Sparkle feed host (session 8):** `release/appcast.xml` on main, served from
  raw.githubusercontent.com (no settings change, no web host, history in git). Feed URL and
  public key live in `release/sparkle.conf`; the key is empty, so the updater stays off until
  the user runs `generate_keys` once (private key in the keychain, backed up offline) and
  commits the public key. `scripts/release/update-appcast.sh <tag>` signs each release with
  `sign_update` (key read by Sparkle from the keychain, never by our scripts).
- **2026-10-21 · Bounded AVFoundation waits in product code (session 8):** export and
  recording never hang on a stuck `AVAssetWriter`: `finishWriting` 60 s, no-progress stall
  30 s, cancel 10 s (Dispatch timers, so a starved cooperative pool can't stop them).
  `ExportError.encoderStalled(seconds:)`; `ExportError` is a `LocalizedError`.
- **2026-10-21 · Test time limits use awake time (session 8):** `Deadline` measures
  `systemUptime` and sleeps on `SuspendingClock`, so a Mac sleeping through a test no longer
  trips a bound. Test readers pull samples on a private thread (`BlockingPull`); cancel never
  overlaps `copyNextSampleBuffer` (that crashes CoreMedia).
- **2026-10-21 · GUI automation and the screen lock (session 8):** UI checks and Camtasia
  driving need an unlocked console session; `scripts/ui-checks/lib.sh` `gui_lock` exits 3 on
  a locked screen; agents driving the GUI run a bounded `caffeinate -d -i -u -t …` and kill it
  when done.
- **2026-10-21 · Camtasia rules from session 8 experiments (researcher, wall-reviewed):**
  copy out of a group bakes the canvas-space transform, paste into a group re-expresses it;
  paste into an open group clamps to the visible window and never grows the group; `revMedia`
  groups cannot be opened (WizRec refuses inner copy/paste [inf]); shader keyframes add an
  `animationTracks.visual` window; classic caption `value.text` may be Cocoa RTF (readers
  strip it; writers keep plain strings; no bold runs). Kept as WizRec-only: `RippleTrim`
  (Camtasia has no ripple-trim gesture) and midpoint insert for a magnetic drop inside a
  clip (Camtasia's refusal is [inf]). Still [?]: Assets-panel background placement, rounding
  of a non-frame-exact Clip Speed duration, media-bin drops into an open group.
- **2026-10-21 · Copy/paste with groups (timeline11, from group-edits.md §8):** one container
  per copy [obs]; nested clips keep `duration`/`mediaStart`/`scalar` [obs]; transforms travel
  in canvas space: clipboard payload v2 `"space"` = the enclosing groups' constant
  position/scale, re-expressed relative to the paste target, changed keys in long form [obs].
  Only constant group position/scale compose; group rotation/crop/opacity/effects/animated
  geometry are not carried [WizRec; rotation ?]. v1 payloads keep their transforms. Paste into
  an open group (`PasteClips(_:group:at:)`) clamps to the window, takes the lowest free inner
  track or a new top one, never grows the group [obs]; multi-row payloads keep row order
  [WizRec]. Rev media (`groupType` "revMedia") is closed: no copy out, no paste in [inf].
  Group keys never travel with nested clips, `ShaderVidSource` does [obs]. `InsertClipInGroup`
  (media-bin drops): superseded by the session 9 entry below.
- **2026-10-21 · Shader keyframes (amends "Shader background origin metadata"):**
  `SetSourceEffectParameters` keyframes add or reuse `animationTracks.visual`
  `{endTime, duration}` [obs §11.1 Q3]; `AnimationSync` keeps both entry shapes.
- **2026-10-21 · Classic caption text:** readers convert `{\rtf` text to plain
  (`ClassicCaptions.plainText`, attributes ignored, raw fallback); writers write plain
  strings [obs CA1].
- **2026-10-21 · [WizRec] keeps:** midpoint insert for a magnetic drop inside a clip
  (Camtasia's refusal is only [inf], UI-level); `RippleTrim` as a WizRec-only command
  (Camtasia has no ripple-trim gesture, ED4).
- **2026-10-21 · Media-bin drops into an open group (session 9, group-edits §8.6, RT-025):**
  `InsertClipInGroup` follows Camtasia [obs]: no growth of the group or any enclosing group;
  no clamp (negative or past-the-end inner start kept, the clip is hidden); track == inner
  track count adds a new top inner track; an occupied spot on a non-magnetic inner track is
  refused; the canvas-default transform is re-expressed through the enclosing groups in long
  form. Supersedes the 2026-10-19 group-edit rule "a drop past a group's end grows it; drops
  before mediaStart rejected". A library double-click into an open group places the item at
  the playhead mapped into the group, on a new top inner track [WizRec, mirrors §8.6 and §11.2].
- **2026-10-21 · Clip Speed rounding (session 9, edit-semantics ED2b, RT-024):** `SetClipSpeed`
  and the new `SetClipDuration` floor `duration` to a whole frame, keep `mediaStart` and
  `mediaDuration`, and write `scalar = duration / mediaDuration` as a reduced rational [obs].
- **2026-10-21 · Loudness rate for projects without a sample rate (session 9):** sources are
  measured at the mixer's own rate when `audioFormatSampleRate` is missing or invalid
  [WizRec; Camtasia always writes the key]; otherwise at the project rate (audio.md §2.1).
  Removes the 10× export slowdown of such projects.
- **2026-10-21 · Assets-panel backgrounds (session 9, shader-backgrounds §11.2, RT-026):**
  no `ShaderVidSource` outside Rev, so WizRec's rule stands.
- **2026-10-21 · CI test builds optimized (session 9, qa12):** test builds use
  `-Xswiftc -O` (debug config, `-enable-testing`), serial media step 324 s → 89 s locally;
  enabled after the RenderEngine texture-lifetime crash it exposed is fixed (render12).
- **2026-10-21 · Library background into an open Rev group (session 9, app12):** it goes on a
  new top inner track at the playhead like any other drop (§8.6), so it writes no
  `ShaderVidSource`/`RevBackground`; those stay limited to `SetShaderVidSource` on inner track 0
  [WizRec]. Revisit only if a save shows Camtasia putting it on track 0.
- **2026-10-21 · Audio hash tests (session 9):** mix digests have one variant per CI machine type
  (Accelerate/libm last bits); `OutputHashTests` accepts each observed variant, an unknown one
  fails locally and is a known issue on CI (printed in the "Known issues" annotation, then
  pinned). Decode digests are exact everywhere.
- **2026-10-21 · CI known-issues annotation (session 9, qa12):** each test step prints a
  "Known issues" notice listing every `withKnownIssue` (readable without login).
- **2026-10-21 · Start screen after the last close (session 10, user):** closing the last
  project shows the start screen even when "Show start screen at launch" is off (kept).
- **2026-10-21 · actionlint in CI (session 10, ship14):** separate ubuntu job, actionlint
  1.7.12 release binary pinned by SHA-256 (checked against the release's checksums file by
  the lead); release.yml checks the notes (`check-notes.sh`) on tags before building.
- **2026-10-21 · Shared texture cache (session 10, media14):** `LockedTextureCache` /
  `CacheTexture` move from RenderEngine to MediaEngine (public) so `MetalToneMapper` uses the
  same locked pattern; RenderEngine's copy is deleted.
- **2026-10-21 · New projects have two empty tracks (session 11, timeline15, ui-workflow §2):**
  `ProjectBundle.create`/`ProjectTemplate.newProject` default `trackCount` 2; each track has the
  shape of Camtasia's saved empty track (`trackIndex`, `medias: []`, `parameters: {}` + a
  `trackAttributes` entry). A busy drop on track 0 of a fresh project uses track 1 first.
- **2026-10-21 · Drops with a group open (session 11, app15, QA16-F1):** timeline drops into an
  open group go through `DropClip(group:)` (§8.7), never refuse with "would overlap". Canvas
  drops and media-bin double-clicks with a group open go into it by the canvas rule (lowest
  inner track with room at the playhead, else a new top inner track) [WizRec; Camtasia [?]].
  Rev keys only when a background really lands on inner track 0.
- **2026-10-21 · Animation presets (session 11, timeline15, animation.md §1–§2):** `AddAnimation`
  writes a 1 s segment ending at the playhead's media time. [WizRec] where unobserved: 1 s on
  the media axis when `scalar` ≠ 1; Tilt translation ±canvasWidth/4; Tilt Right scale
  (canvasWidth/2)/mediaWidth (fits the one 2.4 observation; 0.5 without a media size); Full
  Opacity starts from 0 only when the parameter has no keyframes; a keyframe at the same
  `endTime` has its value replaced.
- **2026-10-21 · Track and selection commands (session 11, timeline15):** `MoveTrack` carries
  `trackAttributes`; `RenameTrack` "" = default numbered name; `SplitAllTracks` skips locked
  tracks and clips that only touch the playhead at an edge; `TimelineSelection.clips(at:)`
  includes locked tracks unless `unlockedOnly` [WizRec until observed].
- **2026-10-21 · Duplicate and Ripple Cut (session 11, app15):** composed in the app as one
  `CompoundCommand` each ("Duplicate": paste right after the selection on its track, else a
  new top track, group paste rule inside groups, clipboard untouched; "Ripple Cut": copy +
  ripple `DeleteClips`) [WizRec until Camtasia's Duplicate placement is observed].
- **2026-10-21 · Generated caption grouping (session 11, app15):** ≤ 8 words, ≤ 4 s, a break
  at a pause ≥ 0.7 s or a sentence end [WizRec].
- **2026-10-21 · UI-check window layout (session 11, app15):** UI checks launch with
  `--ephemeral-layout`; the editor frame, split positions, toolbar configuration and Settings
  frame are then neither read nor written, so runs never leak into the user's app.
- **2026-10-21 · No IOSurface texture reuse cache (session 11, media15):** measured 21–28 µs
  per 4K frame for texture creation (CPU encode +0.04–0.11 ms/frame, GPU ±0.05 ms); below the
  0.3 ms threshold. A surface-ID cache would hand out textures over recycled pool surfaces;
  today's design is safe because `CacheTexture` retains its `CVPixelBuffer`.
