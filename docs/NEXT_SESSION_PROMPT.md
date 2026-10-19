You are the LEAD of the WizRec multi-agent team (free, open-source GPL-3.0 macOS
screen recorder & editor by Devs Wizard that opens/saves Camtasia .cmproj projects).

I explicitly opt in to multi-agent orchestration: use the Agent tool to spawn
background agents (subagent_type general-purpose, isolation "worktree",
run_in_background true), let them talk to each other with SendMessage, and use a
workflow if useful. Goal (session 5): close what sessions 1–4 could not —
M1/M4/M5/M6 golden parity, M4 effects still provisional, [inf]/[WizRec] rules
(group edits, particle shaders, audio effects, captions), whisper.cpp live,
M11 release — plus the session-4 follow-ups. All code through session 4 is
merged; nothing is WIP, no worktrees.

READ FIRST, in order:
1. CLAUDE.md (hard rules, architecture, milestones, current state)
2. docs/HANDOFF.md — §0 session-4 snapshot + follow-ups, §3 user's pending
   items, §4 team setup, §5 clean-room wall, §6 lessons
3. coordination/AGENT_BRIEF.md, BOARD.md, CONTRACTS.md, DECISIONS.md

STEP 0 (you alone): first CHECK what you can yourself, then ask me ONCE, in one
batched question, only about what you could not verify. Plan around the answer;
never nag again.
- Check yourself: exported MP4/MOV files (not just the generated .cmproj test
  projects) in ~/WorkDir/vibe_coding/camtasia_rea_refs/ (REFS_DIR), run
  `scripts/golden.sh --status`; `which whisper-cli` + `brew list whisper.cpp`
  + ggml-*.bin in ~/Library/Application Support/WizRec/models/;
  `git remote -v`.
- Already decided (do not ask): SwiftPM + scripts (no Xcode project); fixture
  thumbnails stripped.
- Ask: Camtasia session 1 and/or 2 delivered (incl. experiments X5 group edits,
  SH2 particles, AU1/AU2, CA1/CA2)? GitHub remote URL? bundle ID? Developer ID
  + notarytool keychain profile name (env only, never committed)? Sparkle OK?
  Rewrite git history to drop the old fixture ProjectThumbnail before the first
  push (git filter-repo), or accept? App click-through done (export close/quit
  confirm, Settings ▸ Captions, media drop into a group)? Camtasia accepts our
  own .tscshadervid backgrounds? Does 4K60 HDR playback matter (Metal tone map)?

STEP 1 (you alone):
- `git status` on main must be clean; `swift build && swift test`
  (expect 812 tests, 20 known issues = 18 golden-harness + 2 LoadGate
  self-tests; sum "Test run with N tests" lines across runners).
- `git worktree list`: remove any stale worktree after checking it is clean and
  merged; `git worktree prune`. Keep branches.

STEP 2: spawn up to 8 agents in one message. Each prompt: "Read
coordination/AGENT_BRIEF.md first", its name, `git switch -c agent/<name>6 main`,
its tasks below, "commit small and often". Then send every agent a ROSTER
message (name → SendMessage address = returned agent ID) and record it in
coordination/ROSTER.md. Add the tasks to BOARD.md.

Always spawn (no user input needed):
- qa: integration tests for every new feature; re-run golden + sheet suites
  (`scripts/golden.sh`, then `--calibrate` for psnrMin) the moment references
  exist; flaky watch (LoadGate in WizRecTestSupport handles load > 30).
- media: perf check of 4K ProRes (now libav-only) with release builds; fix if
  it misses real time.

Spawn only if I delivered the input (STEP 0):
- researcher (only agent allowed REA; talks only to main): turn session 1/2
  results into spec updates — eioe easing fit, animationTracks, Border/
  Reflection/BlendMode/MediaMatte, callouts, cursor effects, audio effect names
  + limiter (AU1/AU2), caption rules (CA1/CA2), group-edit rules (X5),
  particle canvas/blend/_ToRenderTarget/_Scale/_StarOpacity (SH2), BT.709 vs
  sRGB export tag. I review every spec at the clean-room wall before
  publishing; then route to render/timeline/audio/captions/export.
- render: golden parity M1/M4/M5/M6 against references (SSIM ≥ 0.97 effect-free,
  ≥ 0.95 effects); replace provisional Border/Reflection/BlendMode/MediaMatte;
  particle rules from SH2. Metal compute tone map if I said 4K60 HDR matters
  (coordinate with media; lanes must stay identical).
- timeline: replace [inf] group-edit rules with X5 results (DECISIONS.md).
- audio / captions: replace [inf]/[WizRec] rules with the published specs;
  captions also runs the live whisper test if whisper.cpp + model exist
  (`WIZREC_WHISPER_TESTS=1 swift test --filter liveWhisper`) and fixes findings.
- ship: real signing/notarization from env (`WIZREC_SIGN_IDENTITY`,
  `WIZREC_NOTARY_PROFILE`, `WIZREC_BUNDLE_ID`), push + CI on the GitHub remote
  (verify GPU tests on the paravirtual Metal runner), Sparkle if approved (via
  Package.swift with your OK), release DMG, history rewrite if I said so (you
  run it, after a backup, before any push).
- app: fix anything my click-through reports.

RULES: clean room (only the researcher may use REA; specs reviewed by you
before publishing; implementers never read docs/ledger/EVIDENCE.md), nothing
licensing-related, no TechSmith assets in the repo (AssetAuditTests enforces
part of this), user projects read-only for agents (tests on temp copies),
projects only via TSCProjKit/TimelineEngine, Swift 6 strict concurrency, tests
for every public behaviour, timing tests gated by WIZREC_PERF=1 and measured in
release (`swift test -c release -Xswiftc -enable-testing`), permission-bound
tests (capture, speech, whisper live) never run by default. At most ~8
concurrent agents (perf numbers only meaningful at load < ~30). Only you merge
into main (`git merge --no-ff`, full `swift test` green first; resolve
Package.swift conflicts by keeping both sides), edit BOARD.md and talk to me;
approve every API_CHANGE; batch everything that needs me into one NEED_USER.
Determinism: compare frames on ProRes exports (the VideoToolbox H.264 encoder
is not bit-reproducible).

REPORT after each merge: one line per agent (landed / in progress / blocked).
When a milestone's acceptance is met, demo it in the built app
(scripts/make-app.sh) on a COPY of ~/Documents/demo project.cmproj (use
--snapshot-dir/--snapshot-at for frames, `--export <file> --export-preset
"MOV ProRes 422"` for M9; always add `--quit-after <s>` or the app stays open).
At the end: update CLAUDE.md "Current state", docs/HANDOFF.md (new §0 snapshot,
older ones become history), BOARD.md, ROSTER.md, DECISIONS.md, rewrite
docs/NEXT_SESSION_PROMPT.md for the next session, remove finished worktrees,
and give me the remaining NEED_USER list.
