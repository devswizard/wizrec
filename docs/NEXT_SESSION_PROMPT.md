You are the LEAD of the WizRec multi-agent team (free, open-source GPL-3.0 macOS
screen recorder & editor by Devs Wizard that opens/saves Camtasia .cmproj projects).

I explicitly opt in to multi-agent orchestration: use the Agent tool to spawn
background agents (subagent_type general-purpose, isolation "worktree",
run_in_background true), let them talk to each other with SendMessage, and use a
workflow if useful. Goal (session 3): close every remaining phase against its
acceptance criteria — M1/M4/M5/M6 golden parity, M4 effects still provisional,
M7 real capture, M8/M10 rules tagged [inf]/[WizRec], M11 release — plus the code
follow-ups. Sessions 1 and 2 built and merged all code; nothing is WIP.

READ FIRST, in order:
1. CLAUDE.md (hard rules, architecture, milestones, current state)
2. docs/HANDOFF.md — §0a session-2 snapshot + follow-ups, §3 user's pending
   items, §4 team setup, §5 clean-room wall, §6 lessons
3. coordination/AGENT_BRIEF.md, BOARD.md, CONTRACTS.md, DECISIONS.md

STEP 0 (you alone): ask me ONCE, in one batched question, which of these I have
delivered since session 2, then plan around the answer (never nag again):
- Camtasia session 1 and/or 2 reference exports (docs/testing/), in
  ~/WorkDir/vibe_coding/camtasia_rea_refs/ (REFS_DIR)
- recorder permission check output (`swift run wizrec-record …`, HANDOFF §3)
- live speech test result; whisper.cpp + ggml model installed?
- GitHub remote URL, bundle ID, Developer ID / notary profile, Sparkle OK?

STEP 1 (you alone):
- `git status` on main must be clean; `swift build && swift test`
  (expect 700 tests, 18 known issues = golden-harness self-tests).
- `git worktree list`: remove any stale worktree after checking it is clean;
  `git worktree prune`. Keep branches.

STEP 2: spawn up to 8 agents in one message. Each prompt: "Read
coordination/AGENT_BRIEF.md first", its name, `git switch -c agent/<name>4 main`,
its tasks below, "commit small and often". Then send every agent a ROSTER
message (name → SendMessage address = returned agent ID) and record it in
coordination/ROSTER.md.

Always spawn (no user input needed):
- timeline: inner AddTrack/RemoveTrack + media drops inside open groups
  (TimelineEngine commands with expected-JSON + byte-identical undo tests);
  then hand UI hooks to timelineui.
- timelineui: group-track/media-drop UI on top of timeline's commands; dynamic
  caption style as an inspector section (coordinate with app).
- render: export speed — parallel OfflineRenderer (several frames in flight,
  deterministic output, frame N unchanged), target ≥ 4× real time 1080p;
  optional particle shaders (vertexCode), HDR tone mapping.
- export: audio sample rate from the project's audioFormatSampleRate (needs an
  additive AudioScene API — coordinate with main); confirm-before-cancel hook
  for the app; colour tagging (BT.709 vs sRGB) once references exist.
- app: export sheet confirm on window close; wire the new group/inspector
  features; keep make-app.sh + String Catalog current.
- qa: re-run all golden/sheet tests whenever references land; set psnrMin from
  real data; integration tests for every new command; watch flaky list.

Spawn only if I delivered the input (STEP 0):
- researcher (only agent allowed REA; talks only to main): turn session 1/2
  results into spec updates — eioe easing fit, animationTracks, Border/
  Reflection/BlendMode/MediaMatte, callouts, cursor effects, audio effect names
  + limiter (AU1/AU2), caption rules (CA1/CA2). I review every spec at the
  clean-room wall before publishing; then route to render/audio/captions.
- audio / captions: replace [inf]/[WizRec] rules with the published specs;
  whisper.cpp backend if installed (MIT; add via Package.swift with your OK).
- recorder: fix anything my real-capture output shows.
- ship: real signing/notarization config from env, CI on the GitHub remote,
  Sparkle integration if approved, release DMG.

RULES: clean room (only the researcher may use REA; specs reviewed by you
before publishing; implementers never read docs/ledger/EVIDENCE.md), nothing
licensing-related, no TechSmith assets in the repo, user projects read-only for
agents (tests on temp copies), projects only via TSCProjKit/TimelineEngine,
Swift 6 strict concurrency, tests for every public behaviour, timing tests gated
by WIZREC_PERF=1, permission-bound tests (capture, speech) never run by default.
At most ~8 concurrent agents (machine load). Only you merge into main
(`git merge --no-ff`, full `swift test` green first; resolve Package.swift
conflicts by keeping both sides), edit BOARD.md and talk to me; approve every
API_CHANGE; batch everything that needs me into one NEED_USER.

REPORT after each merge: one line per agent (landed / in progress / blocked).
When a milestone's acceptance is met, demo it in the built app
(scripts/make-app.sh) on a COPY of ~/Documents/demo project.cmproj (use
--snapshot-dir/--snapshot-at for frames, --export for M9). At the end: update
CLAUDE.md "Current state", docs/HANDOFF.md (new §0 snapshot), BOARD.md, ROSTER.md,
remove finished worktrees, and give me the remaining NEED_USER list.
