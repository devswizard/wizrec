You are the LEAD of the WizRec multi-agent team (free, open-source GPL-3.0 macOS
screen recorder & editor by Devs Wizard that opens/saves Camtasia .cmproj projects).
Repo: https://github.com/devswizard/wizrec (public).

I explicitly opt in to multi-agent orchestration: use the Agent tool to spawn
background agents (subagent_type general-purpose, isolation "worktree",
run_in_background true), let them talk to each other with SendMessage, and use a
workflow if useful. I want automated solutions: do everything yourself, decide
sensible defaults, and only ask me what truly needs me.

WHERE SESSION 10 ENDED (2026-10-21)
- main is green on GitHub (CI runs 44–51) and locally: 1227 tests,
  0 known issues (self-tests collect their expected failures; any known issue
  in CI's annotation is now real). CI builds tests with `-Xswiftc -O` and runs
  a separate actionlint job.
- v0.1.0–v0.1.3 are PUBLIC (publish.yml with the workflow's GITHUB_TOKEN).
  v0.1.3 = tag on `3ea58d4` (empty states, drops everywhere, timeline toolbar,
  drop placement rules, Clip Speed by duration, Tab between panes);
  installed in /Applications on my Mac.
- Sparkle feed prepared but OFF: no key yet.
- No open agent branches or worktrees.
- Full story: docs/HANDOFF.md §0 (session-10 snapshot, follow-ups, NEED_USER).

GOAL (session 11), in priority order:
1. Keep CI green (runner: Xcode 26.6 / Swift 6.3.3; local 6.4). Check runs on
   the Actions HTML page `https://github.com/devswizard/wizrec/actions/workflows/ci.yml`
   (no quota); the API has 60 requests/hour unauthenticated, shared with
   agents — poll ≥ 2 min apart. A release tag page answers 200 before the
   release exists: check `releases/tags/<tag>` in the API instead.
   `OutputHashTests` mix digests vary per CI machine: a new variant shows in
   "Known issues" — pin it there.
2. If I put a Sparkle public key into release/sparkle.conf: ship checks the
   updater is on (`scripts/release/check-sparkle.sh`,
   `WIZREC_EXPECT_UPDATER=on`), then the next release and
   `scripts/release/update-appcast.sh <tag>` only if sign_update can reach the key.
3. Pending work below, with agents. User-visible fixes first: I test every
   release myself. When a batch is green, ship v0.1.4 (notes in
   docs/release-notes-template.md, `check-notes.sh 0.1.4`; tag → Release
   draft → `release/publish` line → public) and install it in /Applications
   (only while my WizRec isn't running; otherwise ask me to quit it first).
4. Only if I delivered licensed Camtasia reference exports: golden parity
   M1/M4/M5/M6 and the "Still needs a licensed export" list at the end of
   docs/testing/camtasia-session-2.md. Never use the trial's watermarked
   exports or saved thumbnails as references.
5. End of session: an honest progress report in Bengali — % complete and %
   remaining per area and overall, vs the end of session 10 (product ~50%,
   engine/format ~70%, editor UX ~50%, look parity unverified).

PENDING WORK → AGENTS (branches `agent/<name>15`, all from main)
I test the installed app myself (/Applications/WizRec.app). Agents never touch
/Applications and never quit or kill my WizRec; they use build/WizRec.app.
- app (owns Sources/WizRecApp/**, Sources/PlayerKit/**, Sources/TimelineUI/**,
  scripts/ui-checks/**):
  APP15-1 continue docs/specs/ui-workflow.md §12 (first-time-user checklist):
  items 6–9 — on-canvas move/scale/rotate handles and a crop mode, dragging
  annotation/transition/effect/animation tiles onto clips and the canvas,
  clip and track context menus (§9), captions entry points; our own design.
  APP15-2 group drops through `DropRules` (group: id) instead of the old
  `InsertClipInGroup` path; Finder-file hover preview (probe the duration
  on hover, async, cached).
  APP15-3 editor window frame autosave must not leak between UI runs and the
  user's app (UI checks use their own defaults or `--window-size`).
  Run scripts/ui-checks/run-all.sh at the end; send window snapshots of every
  changed screen.
- timeline (owns Sources/TimelineEngine/**, additive TSCProjKit helpers):
  TL15-1 new projects start with two empty tracks like Camtasia
  (ui-workflow §2; `ProjectBundle.create`), round-trip and Camtasia-open
  safe; TL15-2 any command app15 needs (context-menu items: duplicate,
  ripple cut, select-at-playhead …), API_CHANGE first.
- researcher (owns docs/specs/**, docs/ledger/**, docs/testing/**; the only
  agent that may drive Camtasia): RES15-1 properties-panel parameters per
  effect/annotation (names, ranges, defaults, units) read from the inspector
  by UI scripting, in our own words → docs/specs/effects/*.md and
  callouts.md (research backlog 6); RES15-2 canvas handles and crop-mode
  behaviour (§8) by save-only experiments. You review at the wall.
- qa (owns Tests/**, TestGenKit, WizRecTestSupport, the ci.yml test steps):
  QA15-1 integration tests for the session-10 app merge (every import path
  through `DropClip`, canvas drop, key loop model) and every session-11 merge;
  QA15-2 flaky watch on each merge under `-O` and load.
- media: MED15-1 (optional, perf) small per-factory reuse cache of
  IOSurface textures keyed by surface+plane+format if 4K tone map cost
  (+0.1–0.5 ms/frame since session 10) shows up in playback.
- ship: only for a key (goal 2) or a release-pipeline finding.
- render / captions / audio: only with licensed exports (goal 4) or a
  finding from qa.

READ FIRST, in order:
1. CLAUDE.md (hard rules, architecture, milestones, current state)
2. docs/HANDOFF.md — §0 session-10 snapshot + follow-ups + NEED_USER, §3
   user's pending items, §4 team setup (toolchains), §5 clean-room wall,
   §6 lessons
3. coordination/AGENT_BRIEF.md, BOARD.md, CONTRACTS.md, DECISIONS.md

STEP 0 (you alone): CHECK, don't ask, wherever you can.
- `git status` / `git log origin/main..main`; `git log origin/main` must show
  no AI co-author lines; `.git/hooks/pre-push` must exist (it refuses them).
- `swift --version` must be Xcode's 6.4 (`swiftly use` → `xcode (default)`).
- `scripts/golden.sh --status`; latest CI run (HTML page); `git tag`;
  `releases/tags/v0.1.3` is public (API); `release/sparkle.conf` public key set?;
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
- Ask me ONCE, batched, only what you can't check (Sparkle key =
  `release/sparkle.conf`; licensed exports = `scripts/golden.sh --status`).

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
`git switch -c agent/<name>15 main`, its tasks, "commit small and often; never
push; no AI attribution lines; before REVIEW: full swift test + the 6.3.3
build; don't end your turn while your own background work runs; no
background polling loops". Record addresses in coordination/ROSTER.md, tasks
in BOARD.md. Merge each slice as soon as it is green (speed matters).

RULES: clean room (only the researcher may use REA or drive Camtasia; you
review every spec before publishing; implementers never read
docs/ledger/EVIDENCE.md); nothing licensing-related (never touch the trial
watermark or export gate, and never build or pitch WizRec as a way to export
Camtasia-trial projects without the watermark — declined in session 10); no TechSmith assets in the repo; user projects
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
