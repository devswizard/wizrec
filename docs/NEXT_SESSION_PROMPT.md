You are the LEAD of the WizRec multi-agent team (free, open-source GPL-3.0 macOS
screen recorder & editor by Devs Wizard that opens/saves Camtasia .cmproj projects).
Repo: https://github.com/devswizard/wizrec (public).

I explicitly opt in to multi-agent orchestration: use the Agent tool to spawn
background agents (subagent_type general-purpose, isolation "worktree",
run_in_background true), let them talk to each other with SendMessage, and use a
workflow if useful. I want automated solutions: do everything yourself, decide
sensible defaults, and only ask me what truly needs me.

WHERE SESSION 8 ENDED (2026-10-21)
- main `b49023c` is green on GitHub (CI run 28) and locally: 1107 tests,
  17 known issues (15 golden-harness + 2 LoadGate).
- v0.1.0 is PUBLIC (published by .github/workflows/publish.yml with the
  workflow's GITHUB_TOKEN; checked from the public URL).
- Sparkle feed prepared (release/appcast.xml via raw.githubusercontent.com,
  release/sparkle.conf) but OFF: no key yet.
- No open agent branches or worktrees; every session-8 agent is merged.
- Full story: docs/HANDOFF.md §0 (session-8 snapshot, follow-ups, NEED_USER).

GOAL (session 9), in priority order:
1. Keep CI green (runner: Xcode 26.6 / Swift 6.3.3; local 6.4). Check runs on
   the Actions HTML page `https://github.com/devswizard/wizrec/actions/workflows/ci.yml`
   (no quota); the API (`…/actions/runs`, `/check-runs/<job>/annotations`) has
   60 requests/hour unauthenticated and agents share it — poll ≥ 2 min apart.
   Annotations: "Test issues", "Failed tests", "Slowest tests", and `sample`
   stacks on a hang. CI layout: DECISIONS "CI test layout (session 7)".
2. If I put a Sparkle public key into release/sparkle.conf: ship builds,
   checks the updater is on (Info.plist SUFeedURL/SUPublicEDKey), and prepares
   v0.1.1 (release notes; tag → Release workflow draft → `release/publish`
   line `v0.1.1` without allow-build-rpaths → public) and runs
   `scripts/release/update-appcast.sh v0.1.1` only if sign_update can reach
   the key. Without a key, v0.1.1 still ships (rpath-clean DMG) if there are
   user-visible changes worth it.
3. Pending work below (no user input needed), with agents.
4. Only if I delivered licensed Camtasia reference exports: golden parity
   M1/M4/M5/M6 and the "Still needs a licensed export" list at the end of
   docs/testing/camtasia-session-2.md. Never use the trial's watermarked
   exports or saved thumbnails as references.

PENDING WORK → AGENTS (branches `agent/<name>12`, all from main)
- audio (owns Sources/AudioEngine/**): AUD12-1 audio export is ~10× slower
  when `audioFormatSampleRate` is missing/invalid (mix at 44.1 kHz then
  resample?): find and fix, with a timing test gated by WIZREC_PERF=1;
  AUD12-2 speed up the resampler / Clip Speed stretch that dominate CI
  (`compressedAudioUsesProjectSampleRate`, `wavUsesProjectSampleRate` ~40 s,
  `panelItemsApplySaveAndUndo` 32 s in debug) without changing output bytes.
- qa (owns Tests/**, TestGenKit, WizRecTestSupport): QA12-1 CI time — try
  building the media test targets optimized (or `-Osize` for TestGenKit)
  and measure the serial step; QA12-2 integration tests for every merge;
  flaky watch (3 runs); QA12-3 watch for the one golden self-test that read
  176/180 frames at load ~400.
- app (owns Sources/WizRecApp/**, Sources/PlayerKit/**, scripts/ui-checks/**):
  APP12-1 library tiles: Tab at grid ends and past the last realized tile
  (AX audit extended); APP12-2 run scripts/ui-checks/run-all.sh once green
  and fix what fails. GUI work needs an unlocked screen: bounded caffeinate.
- researcher (owns docs/specs/**, docs/ledger/**, docs/testing/**; the only
  agent that may drive Camtasia): RES12-1 save-only experiments for the
  remaining [?]: background placed from the Assets panel (shader §11 Q1),
  rounding of a non-frame-exact Clip Speed duration, media-bin drop into an
  open group (does the group grow?). Spec in our own words; you review at
  the wall.
- timeline: only if RES12-1 changes a rule (e.g. InsertClipInGroup growth).
- ship (owns .github/**, scripts/release/**, docs/RELEASING.md): goal 2;
  fix the two actionlint warnings in release.yml.
- render / captions: only with licensed exports (goal 4).

READ FIRST, in order:
1. CLAUDE.md (hard rules, architecture, milestones, current state)
2. docs/HANDOFF.md — §0 session-8 snapshot + follow-ups + NEED_USER, §3
   user's pending items, §4 team setup (toolchains), §5 clean-room wall,
   §6 lessons
3. coordination/AGENT_BRIEF.md, BOARD.md, CONTRACTS.md, DECISIONS.md

STEP 0 (you alone): CHECK, don't ask, wherever you can.
- `git status` / `git log origin/main..main`; `git log origin/main` must show
  no AI co-author lines; `.git/hooks/pre-push` must exist (it refuses them).
- `swift --version` must be Xcode's 6.4 (`swiftly use` → `xcode (default)`).
- `scripts/golden.sh --status`; latest CI run (HTML page); `git tag`;
  `releases/tags/v0.1.0` is public; `release/sparkle.conf` public key set?;
  `git worktree list`; screen unlocked
  (`ioreg -n Root -d1 | grep CGSSessionScreenIsLocked`).
- Already decided (never ask): SwiftPM + scripts; bundle ID
  com.devswizard.WizRec; no Apple Developer account → ad-hoc DMGs, never
  notarized; publishing via publish.yml; Sparkle feed on raw.githubusercontent;
  no AI attribution anywhere on GitHub; never push local `worktree-agent-*`
  branches (old history).
- The permission classifier blocks reading the keychain GitHub token and
  keychain writes (`generate_keys`): never try; use workflows with
  GITHUB_TOKEN instead, and leave key creation to me.
- Ask me ONCE, batched, only: Sparkle key done? licensed reference exports
  delivered? OK to delete the 56 old `worktree-agent-*` branches?

STEP 1 (you alone):
- `swift build && swift test` on main: expect the §0 test count; sum the
  "Test run with N tests" lines across runners.
- CI-compiler build: `DEVELOPER_DIR=/Library/Developer/CommandLineTools
  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swiftly run
  swift build --build-tests --scratch-path <tmp> +6.3.3` (~60 s clean).
- Remove ~/WorkDir/vibe_coding/camtasia_rea_refs/.gui.lock if left behind.

STEP 2: spawn the agents above in ONE message (up to 6; CI stays with you).
Each prompt: "Read coordination/AGENT_BRIEF.md first", its name,
`git switch -c agent/<name>12 main`, its tasks, "commit small and often; never
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
