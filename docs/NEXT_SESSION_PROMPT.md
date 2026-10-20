You are the LEAD of the WizRec multi-agent team (free, open-source GPL-3.0 macOS
screen recorder & editor by Devs Wizard that opens/saves Camtasia .cmproj projects).
Repo: https://github.com/devswizard/wizrec (public).

I explicitly opt in to multi-agent orchestration: use the Agent tool to spawn
background agents (subagent_type general-purpose, isolation "worktree",
run_in_background true), let them talk to each other with SendMessage, and use a
workflow if useful. I want automated solutions: decide sensible defaults yourself
and only ask me what truly needs me.

GOAL (session 8), in priority order:
1. CI green on GitHub, if it is not yet (runner: Xcode 26.6 / Swift 6.3.3;
   local is 6.4). Read the latest run's annotations without login:
   `curl -s https://api.github.com/repos/devswizard/wizrec/actions/runs?per_page=1`
   → job id → `/check-runs/<job>/annotations`. The test watchdog
   (`scripts/ci/test-with-watchdog.sh`) reports failed tests, unfinished tests
   in start order and `sample` thread stacks of a hung test process. Session
   7's hang was TestGenKit `MediaWriter` `finishWriting` on the 3-core VM
   (fixed: one encode at a time + timeouts); if a hang returns, start from the
   stacks. Reproduce compile errors locally with the 6.3.3 recipe
   (AGENT_BRIEF / DECISIONS).
2. v0.1.0: if the tag is not pushed yet, push `v0.1.0` once CI is green. Check
   the Release run and the DRAFT Release: DMG + SHA256SUMS attached, checksum
   matches, DMG mounts and launches (`--quit-after 5`), per docs/RELEASING.md
   (download without `gh`). Tell me when it is ready; I publish. If it is
   already published, verify the public asset the same way.
3. Follow-ups (no user input needed), from docs/HANDOFF.md §0: re-measure
   test time with serialised `MediaWriter` encodes (relax only with the
   watchdog green on the runner); GPU tests on GitHub's paravirtual Metal;
   wave-2 leftovers (app10/timeline10/render10/qa10) listed in BOARD;
   remove finished worktrees.
4. Only if I delivered licensed Camtasia reference exports: golden parity
   M1/M4/M5/M6 and every look/timing question in "Still needs a licensed
   export" at the end of docs/testing/camtasia-session-2.md. Never use the
   trial's watermarked exports or saved thumbnails as references.

READ FIRST, in order:
1. CLAUDE.md (hard rules, architecture, milestones, current state)
2. docs/HANDOFF.md — §0 session-7 snapshot + follow-ups + NEED_USER, §3
   user's pending items, §4 team setup (toolchains), §5 clean-room wall,
   §6 lessons
3. coordination/AGENT_BRIEF.md, BOARD.md, CONTRACTS.md, DECISIONS.md

STEP 0 (you alone): CHECK, don't ask, wherever you can.
- `git status` / `git log origin/main..main`: push main if it is ahead and
  CI is idle. `git log origin/main` must show no AI co-author lines; the
  local `.git/hooks/pre-push` must exist (it refuses such lines).
- `swift --version` must be Xcode's 6.4; if swiftly shadows it, run
  `swiftly use xcode`.
- `scripts/golden.sh --status` (reference exports under
  ~/WorkDir/vibe_coding/camtasia_rea_refs/); the latest CI run and Release
  run with annotations; `git tag`, the draft/published Release;
  `git worktree list`.
- Already decided (never ask): SwiftPM + scripts; bundle ID
  com.devswizard.WizRec; no Apple Developer account → ad-hoc DMGs, never
  notarized (README documents right-click ▸ Open); Sparkle wired, off until a
  feed exists; Metal tone map for playback; no AI attribution anywhere on
  GitHub; history already rewritten — never push local `agent/*` or
  `backup/*` branches (they carry old history).
- Ask me ONCE, batched, only: licensed reference exports delivered? Sparkle
  feed host (e.g. GitHub Pages appcast) + `generate_keys` done? Manual checks
  ED2–ED4 / CA1 text done? Other WizRec Claude sessions closed or reset?

STEP 1 (you alone):
- `swift build && swift test` on main: expect 1029 tests or more, 23 known
  issues (21 golden-harness + 2 LoadGate self-tests); sum the "Test run with
  N tests" lines across runners.
- Remove finished worktrees after checking each is clean and merged
  (session-7 agents: ship9, app9, qa9, app10, timeline10, render10, qa10,
  docs10); `git worktree prune`; keep branches. Remove
  ~/WorkDir/vibe_coding/camtasia_rea_refs/.gui.lock if left behind.

STEP 2: spawn up to 6 agents in one message (CI fixing stays with you). Each
prompt: "Read coordination/AGENT_BRIEF.md first", its name,
`git switch -c agent/<name>11 main`, its tasks, "commit small and often; never
push; no AI attribution lines". Record addresses in coordination/ROSTER.md,
tasks in BOARD.md.
- ship: v0.1.0 draft/public asset check; Sparkle appcast on GitHub Pages only
  if I said yes (keys never in the repo).
- qa: integration tests for every merge; flaky watch; CI test-time check of
  the serialised MediaWriter; the moment references exist,
  `scripts/golden.sh` then `--calibrate`.
- app / timeline / render: only for BOARD leftovers from wave 2.
- researcher + render (+ audio/captions): ONLY if I delivered licensed
  exports — specs from the exports (wall-reviewed by you), then parity.

RULES: clean room (only the researcher may use REA or drive Camtasia; you
review every spec before publishing; implementers never read
docs/ledger/EVIDENCE.md); nothing licensing-related (never touch the trial
watermark or export gate); no TechSmith assets in the repo; user projects
read-only for agents (tests on temp copies); projects only via
TSCProjKit/TimelineEngine; Swift 6 strict concurrency and **Swift 6.3
compatible** (the CI toolchain); tests for every public behaviour; timing
tests gated by WIZREC_PERF=1, measured in release; permission-bound tests
never run by default; GUI lock `camtasia_rea_refs/.gui.lock` (mkdir) for any
GUI driving. Only you merge into main (`git merge --no-ff`, full `swift test`
green first; Package.swift conflicts: keep both sides), push main, edit
BOARD.md and talk to me; approve every API_CHANGE; batch NEED_USER. Push only
`main` and tags. No `Co-Authored-By`/"Generated with" lines in commits,
merges, tags, PRs or release notes. Don't push while a CI run is in progress
unless it's the fix for that run (concurrency cancels the older run).

REPORT after each merge or CI run: one line per agent (landed / in progress /
blocked) + CI status. Demo in the built app (scripts/make-app.sh) on a COPY
of ~/Documents/demo project.cmproj (--snapshot-dir/--snapshot-at, `--export
<file> --export-preset "MOV ProRes 422"`, always `--quit-after <s>`).
At the end: update CLAUDE.md "Current state", docs/HANDOFF.md (new §0
snapshot), BOARD.md, ROSTER.md, DECISIONS.md, rewrite this file, remove
finished worktrees, push main, and give me the remaining NEED_USER list.
