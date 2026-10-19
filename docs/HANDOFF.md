# Handoff — multi-agent build session

This document is for the **lead session** that continues this project. The
lead coordinates a team of agents that talk to one another, uses REA for
research, and keeps a clean-room wall between research and implementation.

Before doing anything else, read `CLAUDE.md` (the full plan and hard rules),
then `docs/FORMAT.md`.

---

## 0. Snapshot at handoff (2026-10-19)

- **Done (M0):** the `TSCProjKit` lossless project library, the `tscproj`
  CLI, 16 passing tests, `docs/FORMAT.md`, and the app icon.
- **The repo is not yet under git.** Agent worktrees need git, so the lead's
  first step is:
  ```sh
  cd /Users/emonkhan/WorkDir/vibe_coding/camtasia_rea
  git init && git add -A && git commit -m "M0: TSCProjKit lossless .tscproj library, CLI, format spec, app icon"
  ```
  End the commit message with the attribution line the harness provides.
- **Compatibility confirmed:** Camtasia 2026.2.3 opens and plays a demo
  project rewritten by `TSCProjKit`.
- **Pending on the user:**
  - Choose a name and a licence (see "Open decisions" in `CLAUDE.md`).
  - Export reference renders from Camtasia when the QA agent asks for them.

## 1. Team roster

The lead is the main session. It owns planning, interface contracts, merging
and every conversation with the user. Spawn the other agents with the `Agent`
tool, give each a fixed **name**, and run them in the background.
Implementers use `isolation: "worktree"`.

| Name | Side of wall | Owns | Wave |
|---|---|---|---|
| `researcher` | **RE side** | REA investigations, black-box experiments, `docs/specs/**`, `docs/ledger/EVIDENCE.md`, `docs/FORMAT.md` updates | 1 |
| `media` | Impl | `Sources/MediaEngine` (AVFoundation, libavcodec for `tscc2`, frame cache, thumbnails, waveforms) | 1 |
| `render` | Impl | `Sources/RenderEngine` (`evaluate` → `RenderPlan`, Metal compositor, then effects) | 1 |
| `timeline` | Impl | `Sources/TimelineEngine` (commands, undo, snapping, ripple, groups, id remap) | 1 |
| `qa` | Impl | Golden-frame harness (`Tests/GoldenTests`, SSIM/PSNR), generators for effect test projects, CI workflow, perf tests | 1 |
| `app` | Impl | `App/` Xcode project, `NSDocument` for `.cmproj`, window layout, player, timeline UI, inspector | 2 |
| `recorder` | Impl | `Sources/Recorder` (ScreenCaptureKit, AVCapture, cursor log) | 2 |
| `audio` | Impl | `Sources/AudioEngine` | 3 |
| `export` | Impl | `Sources/Exporter` | 3 |
| `captions` | Impl | `Sources/Captions` (whisper.cpp) | 3 |

Keep no more than about 6 agents running at once. Start wave 2 once the wave 1
contracts are stable and the M1 player works.

## 2. Clean-room wall (mandatory)

- **`researcher` is the only agent allowed to use REA tools or look inside
  Camtasia binaries.**
  - Everything it produces is a **behavioural spec**: inputs, outputs, maths
    written in our own words and notation, parameter ranges, and reference
    images or values.
  - A spec must never contain decompiled code, pseudocode transcribed from
    TechSmith functions, symbol-by-symbol structure, or copied strings longer
    than identifiers.
- **Implementers never use REA tools**, never read REA output or evidence
  bundles, and never open Camtasia binaries.
  - They work only from `docs/specs/**`, `docs/FORMAT.md`, the project JSON,
    and their own measurements of reference renders.
  - When a spec is missing something, the implementer asks `researcher` a
    behavioural question through the lead. The answer comes back as a spec
    update.
- **The lead reviews every spec** before announcing it, and rejects any spec
  that leaks implementation detail.
- **Off limits to everyone** (see the hard rules in `CLAUDE.md`):
  - Licensing and activation frameworks, `ShaferFilechck*`, and the
    watermark.
  - Patching or injecting into Camtasia.
  - Redistributing TechSmith assets.

## 3. Communication protocol

The team uses two channels. Direct messages go through `SendMessage`; durable
state lives in files in the repo. Run `ListAgents` to see which agents are
live.

### Messages (`SendMessage`)

Start each message with one of these tags:

| Tag | Sender → receiver | Meaning |
|---|---|---|
| `CLAIM <task-id>` | agent → lead | Taking a task from the board |
| `SPEC_READY <path>` | researcher → lead | Spec ready for wall review |
| `SPEC_PUBLISHED <path>` | lead → implementers | Reviewed spec, safe to use |
| `QUESTION <topic>` | impl → lead | Behaviour unknown. The lead turns it into a research task. |
| `API_CHANGE <module>` | impl → lead + dependents | Public interface changed; diff summary inside |
| `BLOCKED <task-id> <reason>` | any → lead | Needs a decision, a dependency, or the user |
| `REVIEW <branch>` | impl → lead | Ready to merge; tests green |
| `DONE <task-id>` | any → lead | Finished. Includes a summary and follow-ups. |
| `NEED_USER <ask>` | any → lead | Only the lead talks to the user (reference exports, approvals, names) |

Researcher and implementers never message each other directly; everything
crosses the wall through the lead. Implementers may message each other about
interfaces (`API_CHANGE`) with the lead in copy.

### Durable files

| File | Contents |
|---|---|
| `coordination/BOARD.md` | Task board: `id · owner · status (todo/claimed/review/done) · depends-on · acceptance`. Only the lead edits it. |
| `coordination/CONTRACTS.md` | Public Swift interfaces between modules, written by the lead **before** a wave starts. Changing one requires `API_CHANGE` and the lead's approval. |
| `coordination/DECISIONS.md` | Dated decision log (name, licence, tooling, scope calls). |
| `docs/specs/**` | Behavioural specs (researcher writes them, the lead publishes them). |
| `docs/ledger/EVIDENCE.md` | **RE side only.** REA evidence IDs, target SHA-256, method, conclusion, open unknowns. Implementers must not read it. |

### Branching

Each implementer works in its own worktree on the branch `agent/<name>`. The
lead merges into `main` after `swift test` passes, and resolves conflicts
itself.

## 4. REA usage (researcher only)

1. **Load the tools.**
   - Invoke the skill `reverse-engineer-anything` first.
   - REA tools are deferred; load them with `ToolSearch` (`select:<names>` or
     the query `"+rea …"`).
2. **Choose the method**, in this order of preference (see `CLAUDE.md` rule 4):
   - **File-level, no binary involved.** Use these tools first:
     - `inspect_artifact` and `open_binary` on `.trec`, `.cmproj` or archives.
     - `inspect_plist` (`docPrefs`,