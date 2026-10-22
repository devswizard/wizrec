You are the LEAD of the WizRec multi-agent team (free, open-source GPL-3.0 macOS
screen recorder & editor by Devs Wizard that opens/saves Camtasia .cmproj projects).
Repo: https://github.com/devswizard/wizrec (public).

I explicitly opt in to multi-agent orchestration: use the Agent tool to spawn
background agents (subagent_type general-purpose, isolation "worktree",
run_in_background true), let them talk to each other with SendMessage, and use a
workflow if useful. I want automated solutions: do everything yourself, decide
sensible defaults, and only ask me what truly needs me.

WHERE SESSION 11 ENDED (2026-10-21)
- main is green locally: 1299 tests, 0 known issues, Swift 6.3.3 build green.
  CI runs 53–56 green; run 57 (final merge push) and the wrap-up push were
  running at the end: check the Actions page first.
- v0.1.0–v0.1.3 PUBLIC; v0.1.3 installed in /Applications on my Mac.
- **v0.1.4 NOT TAGGED**: my screen locked at ~21:57, so app's UI checks
  (scripts/ui-checks/run-all.sh, 11 checks incl. new check-canvas-tools.sh)
  and window snapshots never ran. Notes ready (`check-notes.sh 0.1.4` OK),
  make-app.sh VERSION 0.1.4.
- Session 11 landed: 2 empty tracks for new projects; canvas handles (§8.1)
  + crop mode; context menus; tile drags (effects/transitions/annotations/
  animations/caption styles); Captions + Animations tabs; Duplicate, Ripple
  Cut, Split All, Select at Playhead; group drops via DropClip(group:);
  --ephemeral-layout; researcher specs effects/inspector.md, callouts §6a,
  ui-workflow §8.1.
- Sparkle feed prepared but OFF: no key yet. No licensed exports.
- Leftover worktrees: agent/app15 (resume it for UI checks or remove) and
  qa's watch worktree; agent branches app15/qa16–18/timeline15/media15/
  researcher15 are merged.
- Full story: docs/HANDOFF.md §0 (session-11 snapshot, follow-ups, NEED_USER).

GOAL (session 12), in priority order:
1. Keep CI green (runner: Xcode 26.6 / Swift 6.3.3; local 6.4). Check runs on
   the Actions HTML page `https://github.com/devswizard/wizrec/actions/workflows/ci.yml`
   (no quota); the API has 60 requests/hour unauthenticated, shared with
   agents — poll ≥ 2 min apart. A release tag page answers 200 before the
   release exists: check `releases/tags/<tag>` in the API instead.
   `OutputHashTests` mix digests vary per CI machine: a new variant shows in
   "Known issues" — pin it there.
2. FIRST, with the screen unlocked: run the UI checks on a fresh
   build/WizRec.app (scripts/make-app.sh), look at the snapshots of every
   changed screen, fix what fails, then ship v0.1.4 (tag → Release draft →
   `release/publish` line → public → verify from the public URL) and install
   it in /Applications (only while my WizRec isn't running; otherwise ask me
   to quit it first). Update the notes if more lands before the tag.
3. If I put a Sparkle public key into release/sparkle.conf: ship checks the
   updater is on (`scripts/release/check-sparkle.sh`,
   `WIZREC_EXPECT_UPDATER=on`), then the next release and
   `scripts/release/update-appcast.sh <tag>` only if sign_update can reach the key.
4. Pending work below, with agents. User-visible fixes first.
5. Only if I delivered licensed Camtasia reference exports: golden parity
   M1/M4/M5/M6 and the "Still needs a licensed export" list at the end of
   docs/testing/camtasia-session-2.md. Never use the trial's watermarked
   exports or saved thumbnails as references.
6. End of session: an honest progress report in Bengali — % complete and %
   remaining per area and overall, vs the end of session 11 (product ~55%,
   engine/format ~72%, editor UX ~60%, look parity unverified).

PENDING WORK → AGENTS (branches `agent/<name>16`, qa `agent/qa19`, all from main)
I test the installed app myself (/Applications/WizRec.app). Agents never touch
/Applications and never quit or kill my WizRec; they use build/WizRec.app.
- app (owns Sources/WizRecApp/**, Sources/PlayerKit/**, Sources/TimelineUI/**,
  scripts/ui-checks/**):
  APP16-1 run-all.sh + check-canvas-tools.sh + check-drops.sh on a fresh
  build, fix failures, send snapshots (blocks v0.1.4);
  APP16-2 inspector pass from docs/specs/effects/inspector.md (ranges,
  clamping, display scales, degrees↔radians, ease fields);
  APP16-3 canvas snapping (§8.1), handle hit radius ~4 pt, inline track
  rename (RenameTrack), caption style tiles in the AX-audit manifest,
  Captions tab lists empty slots (needs captions `slots(in:)`).
- captions: CAP16-1 `ClassicCaptions.slots(in:)` (empty caption slots) for app.
- timeline: TL16-1 `SetClipColor` once researcher has the values; fix
  AnimationSync dropping a Custom animation's empty animationTracks entry.
- researcher (owns docs/specs/**, docs/ledger/**, docs/testing/**; the only
  agent that may drive Camtasia): RES16-1 save-only: clip colour label
  `colorAttribute` values, Duplicate placement, Select at Playhead on locked
  tracks, Camtasia opens a WizRec 2-track empty project; RES16-2 crop mode
  (save often: Camtasia stopped answering AX after the crop tool), snap
  distance/targets, Size lock, gradient fill and Motion Path keys.
- qa (owns Tests/**, TestGenKit, WizRecTestSupport, ci.yml test steps):
  QA16-1 integration tests for every session-12 merge; QA16-2 flaky watch.
- recorder (optional): non-real-time MediaFileWriter.append 2 s bound → 30 s.
- ship: only for a key (goal 3) or a release-pipeline finding.
- render / audio: only with licensed exports (goal 5) or a finding from qa.

READ FIRST, in order:
1. CLAUDE.md (hard rules, architecture, milestones, current state)
2. docs/HANDOFF.md — §0 session-11 snapshot + follow-ups + NEED_USER, §3
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
`git switch -c agent/<name>16 main`, its tasks, "commit small and often; never
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
