You are the LEAD of the WizRec multi-agent team (free, open-source GPL-3.0 macOS
screen recorder & editor by Devs Wizard that opens/saves Camtasia .cmproj projects).
Repo: https://github.com/devswizard/wizrec (public).

I explicitly opt in to multi-agent orchestration: use the Agent tool to spawn
background agents (subagent_type general-purpose, isolation "worktree",
run_in_background true), let them talk to each other with SendMessage, and use a
workflow if useful. I want automated solutions: do everything yourself, decide
sensible defaults, and only ask me what truly needs me.

WHERE SESSION 9 ENDED (2026-10-21)
- main is green on GitHub (CI runs 33–34) and locally: 1148 tests,
  17 known issues (15 golden-harness + 2 LoadGate). CI builds tests with
  `-Xswiftc -O` (serial media step ~91 s).
- v0.1.0 and v0.1.1 are PUBLIC (publish.yml with the workflow's
  GITHUB_TOKEN). v0.1.1 = tag on `0ccf292`, rpath-clean DMG.
- Sparkle feed prepared (release/appcast.xml via raw.githubusercontent.com,
  release/sparkle.conf) but OFF: no key yet.
- No open agent branches or worktrees; the old `worktree-agent-*` branches
  are deleted.
- Full story: docs/HANDOFF.md §0 (session-9 snapshot, follow-ups, NEED_USER).

GOAL (session 10), in priority order:
1. Keep CI green (runner: Xcode 26.6 / Swift 6.3.3; local 6.4). Check runs on
   the Actions HTML page `https://github.com/devswizard/wizrec/actions/workflows/ci.yml`
   (no quota); the API (`…/actions/runs`, `/check-runs/<job>/annotations`) has
   60 requests/hour unauthenticated and agents share it — poll ≥ 2 min apart.
   Annotations: "Test issues", "Failed tests", "Known issues", "Slowest
   tests", and `sample` stacks on a hang. `OutputHashTests` mix digests vary
   per CI machine: a new variant shows in "Known issues" — pin it there.
2. If I put a Sparkle public key into release/sparkle.conf: ship builds and
   checks the updater is on (`scripts/release/check-sparkle.sh`,
   `WIZREC_EXPECT_UPDATER=on`), then v0.1.2 (notes in
   docs/release-notes-template.md; tag → Release draft → `release/publish`
   line `v0.1.2` → public) and `scripts/release/update-appcast.sh v0.1.2` only
   if sign_update can reach the key. Without a key, ship a release only for
   user-visible changes worth it.
3. Pending work below (no user input needed), with agents.
4. Only if I delivered licensed Camtasia reference exports: golden parity
   M1/M4/M5/M6 and the "Still needs a licensed export" list at the end of
   docs/testing/camtasia-session-2.md. Never use the trial's watermarked
   exports or saved thumbnails as references.

PENDING WORK → AGENTS (branches `agent/<name>13`, all from main)
- app (owns Sources/WizRecApp/**, Sources/PlayerKit/**, Sources/TimelineUI/**,
  scripts/ui-checks/**): APP13-1 window-level key loop (library sidebar →
  canvas → inspector → timeline, Tab leaves the library panel; AX audit
  extended); APP13-2 Clip Speed inspector: Duration field through
  TimelineEngine `SetClipDuration` (ED2b), Speed field shows the effective
  speed to 2 decimals; run scripts/ui-checks/run-all.sh at the end.
- qa (owns Tests/**, TestGenKit, WizRecTestSupport, the ci.yml test steps):
  QA13-1 flaky watch under `-O` (5 full runs) and on loaded machines;
  QA13-2 integration tests for every merge; QA13-3 `inheritedStderrDoesNotHang`
  took 6.3 s on a loaded CI runner — make the bound meaningful there (or
  explain); QA13-4 review the 17 known issues: still needed?
- ship (owns .github/** except qa's test steps, scripts/release/**,
  docs/RELEASING.md): SHIP13-1 actionlint step in CI; goal 2 when a key exists.
- media (owns Sources/MediaEngine/**): MED13-1 `ToneMappingMetal` to the
  RenderEngine-style locked texture cache if it can release wrappers off the
  caller thread (else document why it is safe), with a stress test.
- researcher (owns docs/specs/**, docs/ledger/**, docs/testing/**; the only
  agent that may drive Camtasia): RES13-1 list the remaining [?] in
  docs/specs answerable by save-only experiments (e.g. why a drop onto an
  occupied inner spot adds nothing, the Assets `ident` rule) and answer the
  ones that matter for interoperability. You review at the wall.
- timeline: only if RES13-1 changes a rule.
- render / captions / audio: only with licensed exports (goal 4) or a
  finding from qa.

READ FIRST, in order:
1. CLAUDE.md (hard rules, architecture, milestones, current state)
2. docs/HANDOFF.md — §0 session-9 snapshot + follow-ups + NEED_USER, §3
   user's pending items, §4 team setup (toolchains), §5 clean-room wall,
   §6 lessons
3. coordination/AGENT_BRIEF.md, BOARD.md, CONTRACTS.md, DECISIONS.md

STEP 0 (you alone): CHECK, don't ask, wherever you can.
- `git status` / `git log origin/main..main`; `git log origin/main` must show
  no AI co-author lines; `.git/hooks/pre-push` must exist (it refuses them).
- `swift --version` must be Xcode's 6.4 (`swiftly use` → `xcode (default)`).
- `scripts/golden.sh --status`; latest CI run (HTML page); `git tag`;
  `releases/tags/v0.1.1` is public; `release/sparkle.conf` public key set?;
  `git worktree list`; screen unlocked
  (`ioreg -n Root -d1 | grep CGSSessionScreenIsLocked`).
- Already decided (never ask): SwiftPM + scripts; bundle ID
  com.devswizard.WizRec; no Apple Developer account → ad-hoc DMGs, never
  notarized; publishing via publish.yml; Sparkle feed on raw.githubusercontent;
  no AI attribution anywhere on GitHub; never push local `worktree-agent-*`
  branches.
- The permission classifier blocks reading the keychain GitHub token and
  keychain writes (`generate_keys`): never try; use workflows with
  GITHUB_TOKEN instead, and leave key creation to me.
- Ask me ONCE, batched, only what you can't check: usually nothing (Sparkle
  key = `release/sparkle.conf`; licensed exports = `scripts/golden.sh --status`).

STEP 1 (you alone):
- `swift build && swift test` on main: expect the §0 test count; sum the
  "Test run with N tests" lines across runners.
- CI-compiler build: `DEVELOPER_DIR=/Library/Developer/CommandLineTools
  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swiftly run
  swift build --build-tests --scratch-path <tmp> +6.3.3` (~60 s clean).
- Remove ~/WorkDir/vibe_coding/camtasia_rea_refs/.gui.lock if left behind.

STEP 2: spawn the agents above in ONE message (up to 6; CI stays with you);
spawn an owner agent for any product bug a test finding uncovers.
Each prompt: "Read coordination/AGENT_BRIEF.md first", its name,
`git switch -c agent/<name>13 main`, its tasks, "commit small and often; never
push; no AI attribution lines; before REVIEW: full swift test + the 6.3.3
build; don't end your turn while your own background work runs; no
background polling loops". Record addresses in coordination/ROSTER.md, tasks
in BOARD.md. Merge each slice as soon as it is green (speed matters).

RULES: clean room (only the researcher may use REA or drive Camtasia; you
review every spec before publishing; implementers never read
docs/ledger/EVIDENCE.md); nothing licensing-related (never touch the trial
watermark or export gate); no TechSmith assets in the repo; user projects
read-only for agents (tests on temp copies); projects only via
TSCProjKit/TimelineEngine; Swift 6 strict concurrency and **Swift 6.3
compatible**; tests for every public behaviour; `@MainActor` tests never wait
synchronously on AVFoundation/VideoToolbox/Metal (use the async MediaWriter
and WizRecTestSupport `Deadline`/`TestProcess`/`GPUWait`); every test wait is
bounded; timing tests gated by WIZREC_PERF=1; new media-heavy test targets go
into CI's serial step (`.github/workflows/ci.yml` filter); VM-only skips via
`TestEnvironment.isVirtualMachine` with a reason; permission-bound tests never
run by default; GUI lock `camtasia_rea_refs/.gui.lock` (mkdir) for any GUI
driving. Only you merge into main (`git merge --no-ff`, full `swift test`
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
