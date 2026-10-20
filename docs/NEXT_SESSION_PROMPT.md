You are the LEAD of the WizRec multi-agent team (free, open-source GPL-3.0 macOS
screen recorder & editor by Devs Wizard that opens/saves Camtasia .cmproj projects).
Repo: https://github.com/devswizard/wizrec (public).

I explicitly opt in to multi-agent orchestration: use the Agent tool to spawn
background agents (subagent_type general-purpose, isolation "worktree",
run_in_background true), let them talk to each other with SendMessage, and use a
workflow if useful. I want automated solutions: decide sensible defaults yourself
and only ask me what truly needs me.

GOAL (session 7), in priority order:
1. CI green on GitHub (runner: Xcode 26.6 / Swift 6.3.3, older than local
   Swift 6.4). Failures so far were Swift-6.3-only: slow type-checks ("unable
   to type-check this expression in reasonable time"), CGFloat→Double in tuple
   returns, ambiguous Data.withUnsafeBytes. CI publishes the toolchain and the
   build/test errors as annotations, readable without login:
   `curl -s https://api.github.com/repos/devswizard/wizrec/actions/runs?per_page=1`
   → job id → `/check-runs/<job>/annotations`. Fix every error, push, repeat
   until green. Locally, `-Xfrontend -warn-long-expression-type-checking=40`
   finds candidates (6.3 can be 20–50× slower than 6.4 on the same line).
2. First release v0.1.0: after CI is green, push tag `v0.1.0`; the Release
   workflow builds the ad-hoc signed DMG (FFmpeg + Sparkle inside; users need
   no Xcode/Homebrew) and attaches it to a DRAFT GitHub Release. Verify the
   run; fill "What's new" from BOARD; tell me to publish (I publish).
3. Follow-ups (no user input needed): inspector controls for a shader
   background's `sourceEffect` params; write `metadata.ShaderVidSource` and the
   group `RevBackground` like Camtasia (docs/specs/shader-backgrounds.md);
   scripted mouse double-click check on library tiles; Node 20 deprecation in
   workflows (actions/checkout, actions/cache → current majors);
   `hdiutil` → `diskutil image` on macOS 27 in release scripts.
4. Only if I delivered licensed Camtasia reference exports: golden parity
   M1/M4/M5/M6 and every look/timing question in "Still needs a licensed
   export" at the end of docs/testing/camtasia-session-2.md.

READ FIRST, in order:
1. CLAUDE.md (hard rules, architecture, milestones, current state)
2. docs/HANDOFF.md — §0 session-5 snapshot + follow-ups, §3 user's pending
   items, §4 team setup, §5 clean-room wall, §6 lessons
3. coordination/AGENT_BRIEF.md, BOARD.md, CONTRACTS.md, DECISIONS.md

STEP 0 (you alone): CHECK, don't ask, wherever you can.
- `git status` / `git log origin/main..main`: if local main is ahead (e.g. the
  app8 merge: shader effectDef on import, Backgrounds tab, accessible library
  tiles, ⌘W on the export sheet), push it.
- `scripts/golden.sh --status` (reference exports under
  ~/WorkDir/vibe_coding/camtasia_rea_refs/); the latest CI run's result and
  annotations; `git worktree list`.
- Already decided (never ask): SwiftPM + scripts; bundle ID
  com.devswizard.WizRec; no Apple Developer account → ad-hoc DMGs, never
  notarized (README documents right-click ▸ Open); Sparkle wired, off until a
  feed exists; Metal tone map for playback; history already rewritten — never
  push local `agent/*` branches (they carry the old pre-rewrite history).
- Ask me ONCE, batched, only: licensed reference exports delivered? saved
  Camtasia thumbnails OK as interim references? Sparkle feed host (e.g. GitHub
  Pages appcast) + `generate_keys` done? Manual checks ED2–ED4 / CA1 text done?

STEP 1 (you alone):
- `swift build && swift test` on main: expect 996 tests, 23 known issues
  (21 golden-harness + 2 LoadGate self-tests); sum the "Test run with N tests"
  lines across runners.
- Remove stale worktrees after checking each is clean and merged (the stopped
  session-5 agents' worktrees researcher6/timeline6/media6/app6 hold only WIP
  already carried into *7 branches; qa6/render6 may be locked — unlock first);
  `git worktree prune`; keep branches. Remove
  ~/WorkDir/vibe_coding/camtasia_rea_refs/.gui.lock if left behind.

STEP 2: spawn up to 6 agents in one message (CI fixing stays with you). Each
prompt: "Read coordination/AGENT_BRIEF.md first", its name,
`git switch -c agent/<name>9 main`, its tasks, "commit small and often; never
push". Record addresses in coordination/ROSTER.md, tasks in BOARD.md.
- ship: release v0.1.0 (after you report CI green), workflow Node 20 bumps,
  `diskutil image`, verify the draft Release DMG mounts and launches
  (`--quit-after 5`); Sparkle appcast on GitHub Pages only if I said yes.
- app: shader-background inspector controls, ShaderVidSource/RevBackground
  metadata (with timeline rules), mouse double-click UI check.
- qa: integration tests for every merge; flaky watch; and the moment
  references exist, `scripts/golden.sh` then `--calibrate`.
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
`main` and tags. Don't push while a CI run is in progress unless it's the fix
for that run (concurrency cancels the older run).

REPORT after each merge or CI run: one line per agent (landed / in progress /
blocked) + CI status. Demo in the built app (scripts/make-app.sh) on a COPY
of ~/Documents/demo project.cmproj (--snapshot-dir/--snapshot-at, `--export
<file> --export-preset "MOV ProRes 422"`, always `--quit-after <s>`).
At the end: update CLAUDE.md "Current state", docs/HANDOFF.md (new §0
snapshot), BOARD.md, ROSTER.md, DECISIONS.md, rewrite this file, remove
finished worktrees, push main, and give me the remaining NEED_USER list.
