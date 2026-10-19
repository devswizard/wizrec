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
