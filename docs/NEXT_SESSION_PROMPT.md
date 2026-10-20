You are the LEAD of the WizRec multi-agent team (free, open-source GPL-3.0 macOS
screen recorder & editor by Devs Wizard that opens/saves Camtasia .cmproj projects).
Repo: https://github.com/devswizard/wizrec (public).

I explicitly opt in to multi-agent orchestration: use the Agent tool to spawn
background agents (subagent_type general-purpose, isolation "worktree",
run_in_background true), let them talk to each other with SendMessage, and use a
workflow if useful. I want automated solutions: decide sensible defaults yourself
and only ask me what truly needs me.

WHERE SESSION 7 ENDED (2026-10-20)
- main is green on GitHub: CI run 19 (`7a32d7b`); 1058 tests (629 parallel +
  429 serial media tests), 23 known issues (21 golden-harness + 2 LoadGate).
- v0.1.0 is tagged on `37b384c` (CI run 17 green). Release run 1 attached the
  ad-hoc DMG + SHA256SUMS.txt to a DRAFT GitHub Release; ship verified a
  rebuild from the tag (DMG 20.9 MB, launches the demo copy). The user
  publishes the draft.
- No open branches or worktrees; every session-7 agent is merged.
- Full story: docs/HANDOFF.md §0 (session-7 snapshot, follow-ups, NEED_USER).

GOAL (session 8), in priority order:
1. Keep CI green (runner: Xcode 26.6 / Swift 6.3.3; local 6.4). Annotations
   without login: `curl -s https://api.github.com/repos/devswizard/wizrec/actions/runs?per_page=1`
   → job id → `/check-runs/<job>/annotations` (60 requests/hour unauthenticated;
   the Actions HTML page `…/actions/workflows/ci.yml` shows run status without
   quota). The watchdog posts one "Test issues" and one "Failed tests"
   annotation, plus `sample` thread stacks and unfinished tests on a hang.
   CI layout and why: DECISIONS "CI test layout (session 7)".
2. v0.1.0 public: if I published it, ship checks the public asset
   (download, `shasum -a 256 -c SHA256SUMS.txt`, `scripts/release/verify-dmg.sh`,
   launch `--quit-after 5`). If still a draft, remind me once.
3. Pending work below (no user input needed), with agents.
4. Only if I delivered licensed Camtasia reference exports: golden parity
   M1/M4/M5/M6 and every look/timing question in "Still needs a licensed
   export" at the end of docs/testing/camtasia-session-2.md. Never use the
   trial's watermarked exports or saved thumbnails as references.

PENDING WORK → AGENTS (branches `agent/<name>11`, all from main)
- export (owns Sources/Exporter/**, Sources/Recorder/MediaFileWriter.swift):
  EXP11-1 bound every wait in product code that can hang on a stuck
  AVFoundation session: `MovieExport.finish` (finishWriting continuation),
  `MediaFileWriter` `await writer.finishWriting()`, `AudioExport` ready loop
  (add the StallWatch MovieExport uses). A stuck writer must end the export
  with an error the UI shows, never hang. Tests with an injected stuck writer.
- app (owns Sources/WizRecApp/**, Sources/PlayerKit/**, scripts/ui-checks/**):
  APP11-1 `CanvasRenderer.renderImage` must not wait for the GPU on the main
  thread (async or completion handler); APP11-2 `--quit-after` with several
  unsaved documents (`reviewUnsavedDocuments` path, untested) + a UI check;
  APP11-3 Swift 6.3 slow spots: CanvasRenderer.swift:43,
  EditorDocumentModel.swift:117, EditorWindowController+Export.swift:22,
  EditorSupport.swift:74, EditorWindowController.swift:26/54, MainMenu.swift:11
  (measure with the 6.3.3 recipe first; fix only what is > 50 ms).
- qa (owns Tests/**, Sources/TestGenKit/**, Sources/WizRecTestSupport):
  QA11-1 bound the test reader loops (RecorderTests `readBack`, ExporterTests
  `decodeAudio`/`trackBytes`, TestGenKit `MovieFrameReader`): run them on a
  private thread with `Deadline`; QA11-2 CI time: the serial media step takes
  ~12 min — find the slowest serial tests (watchdog notice) and cut fixture
  sizes where it does not weaken the test; QA11-3 integration tests for every
  session-8 merge; flaky watch (3 runs).
- ship (owns .github/**, scripts/release/**, docs/RELEASING.md):
  SHIP11-1 strip the Xcode back-deploy `LC_RPATH` from the app binary before
  signing (`bundle-dylibs.sh`), and make `verify-dmg.sh` fail on any rpath or
  load path into Xcode/Homebrew; SHIP11-2 public v0.1.0 asset check (goal 2);
  SHIP11-3 Sparkle appcast on GitHub Pages ONLY if I said yes (keys never in
  the repo).
- researcher (owns docs/specs/**, docs/ledger/**; the only agent that may
  drive Camtasia): RES11-1 save-only UI-scripted experiments (no export, GUI
  lock, copies only) answering the open [?] questions:
  copy/paste inside groups (DECISIONS "Copy/paste inside groups", 4 items) and
  shader origin metadata (shader-backgrounds.md §11, 3 items). Specs in our
  own words; you review them at the clean-room wall before publishing; then
  timeline/app adjust the [WizRec] rules if Camtasia differs.
- timeline: spawn only when the researcher's answers change a rule (TL11-x).
- render / audio / captions: only with licensed exports (goal 4).

READ FIRST, in order:
1. CLAUDE.md (hard rules, architecture, milestones, current state)
2. docs/HANDOFF.md — §0 session-7 snapshot + follow-ups + NEED_USER, §3
   user's pending items, §4 team setup (toolchains), §5 clean-room wall,
   §6 lessons
3. coordination/AGENT_BRIEF.md, BOARD.md, CONTRACTS.md, DECISIONS.md

STEP 0 (you alone): CHECK, don't ask, wherever you can.
- `git status` / `git log origin/main..main`; `git log origin/main` must show
  no AI co-author lines; `.git/hooks/pre-push` must exist (it refuses them).
- `swift --version` must be Xcode's 6.4. If swiftly shadows it:
  `swiftly use --global-default xcode` (never a per-project `.swift-version`).
- `scripts/golden.sh --status`; latest CI and Release runs; `git tag`; the
  draft/published Release (`releases/tags/v0.1.0` is 404 while a draft);
  `git worktree list`.
- Already decided (never ask): SwiftPM + scripts; bundle ID
  com.devswizard.WizRec; no Apple Developer account → ad-hoc DMGs, never
  notarized; Sparkle wired, off until a feed exists; no AI attribution
  anywhere on GitHub; never push local `agent/*` or `backup/*` branches (old
  history).
- Ask me ONCE, batched, only: v0.1.0 published? licensed reference exports
  delivered? Sparkle feed host + `generate_keys` done? Manual checks ED2–ED4 /
  CA1 text / VoiceOver on library tiles done? Other WizRec Claude sessions
  closed or reset? OK to delete local `agent/*` + `backup/pre-coauthor-strip`
  branches?

STEP 1 (you alone):
- `swift build && swift test` on main: expect 1058 tests or more, 23 known
  issues; sum the "Test run with N tests" lines across runners.
- CI-compiler build: `DEVELOPER_DIR=/Library/Developer/CommandLineTools
  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swiftly run
  swift build --build-tests --scratch-path <tmp> +6.3.3` (~80 s clean).
- Remove ~/WorkDir/vibe_coding/camtasia_rea_refs/.gui.lock if left behind.

STEP 2: spawn the agents above in ONE message (up to 6; CI stays with you).
Each prompt: "Read coordination/AGENT_BRIEF.md first", its name,
`git switch -c agent/<name>11 main`, its tasks, "commit small and often; never
push; no AI attribution lines; before REVIEW: full swift test + the 6.3.3
build". Record addresses in coordination/ROSTER.md, tasks in BOARD.md.

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
