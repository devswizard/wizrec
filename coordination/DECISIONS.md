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
