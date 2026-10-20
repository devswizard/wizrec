You are the LEAD of the WizRec multi-agent team (free, open-source GPL-3.0 macOS
screen recorder & editor by Devs Wizard that opens/saves Camtasia .cmproj projects).

I explicitly opt in to multi-agent orchestration: use the Agent tool to spawn
background agents (subagent_type general-purpose, isolation "worktree",
run_in_background true), let them talk to each other with SendMessage, and use a
workflow if useful. Goal (session 6): golden parity M1/M4/M5/M6 and every
look/timing question that needs Camtasia exports (if I delivered them), M11
release (remote, signing, Sparkle feed) if I delivered those inputs, plus the
session-5 follow-ups. All code through session 5 is merged.

READ FIRST, in order:
1. CLAUDE.md (hard rules, architecture, milestones, current state)
2. docs/HANDOFF.md — §0 session-5 snapshot + follow-ups, §3 user's pending
   items, §4 team setup, §5 clean-room wall, §6 lessons
3. coordination/AGENT_BRIEF.md, BOARD.md, CONTRACTS.md, DECISIONS.md

STEP 0 (you alone): CHECK what you can yourself first; decide sensibly where a
default exists; ask me ONCE, in one batched question, only about what you
could not verify or decide. Never nag again.
- Check yourself: `scripts/golden.sh --status` (reference.mov/.mp4 under
  ~/WorkDir/vibe_coding/camtasia_rea_refs/); whether the Camtasia export still
  shows the "with/without watermark" choice is NOT yours to test (only the
  researcher drives Camtasia); `git remote -v`; `security find-identity -v
  -p codesigning` (a "Developer ID Application" identity?); whisper models in
  ~/Library/Application Support/WizRec/models/ (small, silero VAD,
  large-v3-turbo are installed).
- Already decided (do not ask): SwiftPM + scripts; bundle ID
  com.devswizard.WizRec; Sparkle approved (off until feed/key); Metal tone map
  for playback; save-only Camtasia automation by the researcher.
- Ask only what is still open (HANDOFF §3): licensed reference exports
  delivered? thumbnails OK as interim references? GitHub remote URL (you may
  not use stored credentials yourself)? git-history rewrite or accept?
  Developer ID + notary profile name (env only)? Sparkle feed host +
  generate_keys done? Manual checks ED2–ED4 / CA1 text / VoiceOver done?

STEP 1 (you alone):
- `git status` on main must be clean; `swift build && swift test` (expect
  979 tests, 23 known issues = 21 golden-harness + 2 LoadGate self-tests; sum
  the "Test run with N tests" lines across runners).
- `git worktree list`: session-5 worktrees are all merged; remove each after
  checking it is clean (the four stopped agents' worktrees — researcher6,
  timeline6, media6, app6 — hold only WIP already carried into the *7
  branches); `git worktree prune`. Keep branches. Remove
  ~/WorkDir/vibe_coding/camtasia_rea_refs/.gui.lock if left behind.

STEP 2: spawn up to 8 agents in one message. Each prompt: "Read
coordination/AGENT_BRIEF.md first", its name, `git switch -c agent/<name>8 main`,
its tasks, "commit small and often". Send every agent a ROSTER message and
record it in coordination/ROSTER.md. Add the tasks to BOARD.md.

Always spawn:
- qa: integration tests for every merge; the moment references exist run
  `scripts/golden.sh`, then `--calibrate` and paste the printed psnrMin
  entries; flaky watch.
- app: follow-ups — write a shader source's `effectDef`/`sourceEffect` on
  import/library placement via `ShaderSourceLayout` (with timeline), ⌘W with
  the export sheet open, VoiceOver labels on library tiles (NSView-backed
  tile if needed), rounded corners for blur/pixelate/spotlight callouts (with
  render).

Spawn only if I delivered the input:
- researcher (only agent allowed REA/Camtasia; talks only to main): turn the
  licensed exports into spec updates — eioe fit, Border/Reflection/tilt/
  shear/stencil/LuminanceFadeIn looks, transition windows, particle canvas
  (SH1/SH2), behaviour timing, caption layout, normalisation output (AU2),
  BT.709 vs sRGB tag, key-cap styles. I review every spec at the wall.
- render: golden parity (SSIM ≥ 0.97 effect-free, ≥ 0.95 effects) against
  the references; replace provisional looks from the new specs.
- audio / captions: normalisation output and caption layout from specs.
- ship: push + CI on the remote (verify GPU tests on the paravirtual Metal
  runner), Developer ID signing + notarization from env, Sparkle feed +
  appcast, release DMG; history rewrite only if I said so (you run it, after a
  backup bundle, before any push).

RULES: clean room (only the researcher may use REA or drive Camtasia; specs
reviewed by you before publishing; implementers never read
docs/ledger/EVIDENCE.md), nothing licensing-related (never touch the trial
watermark or the export gate), no TechSmith assets in the repo, user projects
read-only for agents (tests on temp copies), projects only via
TSCProjKit/TimelineEngine, Swift 6 strict concurrency, tests for every public
behaviour, timing tests gated by WIZREC_PERF=1 and measured in release,
permission-bound tests never run by default. GUI lock
`camtasia_rea_refs/.gui.lock` (mkdir) for any agent driving the GUI. At most
~8 concurrent agents. Only you merge into main (`git merge --no-ff`, full
`swift test` green first; Package.swift conflicts: keep both sides), edit
BOARD.md and talk to me; approve every API_CHANGE; batch NEED_USER.
Determinism: compare frames on ProRes exports.

REPORT after each merge: one line per agent (landed / in progress / blocked).
Demo milestones in the built app (scripts/make-app.sh) on a COPY of
~/Documents/demo project.cmproj (--snapshot-dir/--snapshot-at, `--export
<file> --export-preset "MOV ProRes 422"`, always `--quit-after <s>`).
At the end: update CLAUDE.md "Current state", docs/HANDOFF.md (new §0
snapshot), BOARD.md, ROSTER.md, DECISIONS.md, rewrite this file, remove
finished worktrees, and give me the remaining NEED_USER list.
