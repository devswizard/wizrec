# Agent brief (every agent reads this first)

You are one named agent on the WizRec team: a free, open-source (GPL-3.0)
macOS screen recorder and editor by Devs Wizard that opens and saves Camtasia
`.cmproj` projects. The lead is the main session; address it as `"main"`.

## Setup

1. You run in your own git worktree. First: `git switch -c agent/<branch>`
   (the branch named in your prompt; `git switch` if it exists). Commit only
   there. Never touch `main`, never merge, never push.
2. Read: `CLAUDE.md` (hard rules), `coordination/CONTRACTS.md`,
   `coordination/DECISIONS.md`, `coordination/BOARD.md`, the `docs/specs/*.md`
   relevant to you, and the `Contract*.swift` files of the modules you touch
   or consume.
3. The lead sends a ROSTER message mapping agent names to SendMessage
   addresses. Names alone are not addresses.

## Hard rules (CLAUDE.md wins)

- **Clean room.** Implementers never use REA tools (`mcp__rea__*`), never open
  or inspect Camtasia binaries/frameworks, and never read
  `docs/ledger/EVIDENCE.md`. Only the researcher does RE work, within
  `coordination/DECISIONS.md` limits.
- **Nothing licensing-related**, ever (TSCLicensing, activation, trial
  watermark, ShaferFilechck…). Refuse and tell the lead.
- **No TechSmith assets in the repo**: no themes, shaders, sample projects,
  callout art, cursors, sounds, icons, fonts. Reading them in place for
  observation is fine.
- **User data**: `~/Documents/*.cmproj` and `~/Movies/WizRec` are read-only for
  agents. Never copy user media into the repo. Test writes only on copies in a
  temp dir. `.trec` `TSCM` atoms contain window titles: never log or vendor.
- **Projects** are read and written only through TSCProjKit and TimelineEngine
  commands. Never `Codable`/`JSONSerialization` on a project.
- **Never put "Camtasia" in a product, module, bundle or type identifier.**
- Swift 6 language mode, strict concurrency, **Swift 6.3 compatible** (CI
  runs Xcode 26.6 / Swift 6.3.3; local is 6.4). 6.3 type-checks some lines
  20–50× slower: keep expressions small, annotate literal/closure types, no
  implicit CGFloat→Double in tuple returns, explicit `withUnsafeBytes`
  closure types. Check new code with
  `swift build -Xswiftc -Xfrontend -Xswiftc -warn-long-expression-type-checking=40`
  and, when installed, `swiftly run swift build +6.3.3`. Swift Testing. Doc comment on every public type with units. No force-unwraps
  on file data. `@unchecked Sendable` only with a justifying comment.
- New dependencies must be GPL-3.0-compatible; ask the lead first.

## Protocol

- Every `SendMessage` starts with a tag and your name, e.g.
  `CLAIM [render] M4-REN-1`. Tags: `CLAIM`, `QUESTION`, `API_CHANGE`,
  `BLOCKED`, `REVIEW`, `DONE`, `NEED_USER`, `SPEC_READY` (researcher only).
- Start by sending `CLAIM` for your board tasks to main.
- Public API changes to another module's contract, or any change to a frozen
  `Contract*.swift`: `API_CHANGE <module>` to main **and** affected agents;
  wait for main's OK. Purely additive public API in your own module still
  gets an `API_CHANGE` notice, usually approved quickly.
- Format/behaviour questions go to main as `QUESTION` (main routes them to the
  researcher). Implementers never message the researcher directly.
- Human needs go to main as one batched `NEED_USER`. Don't wait idle: keep
  working on other tasks.
- `Package.swift` is lead-owned: change it only for your own targets and list
  the change in `REVIEW`.
- Commits: small, imperative subject. **No AI co-author or attribution
  lines** (no `Co-Authored-By: Claude…`, no "Generated with…"): the user's
  rule for everything that reaches GitHub.
- Before every `REVIEW`: `git rebase main`, then `swift build && swift test`
  all green, with no new warnings. The ld warnings saying FFmpeg was "built
  for newer macOS" are pre-existing.
- `REVIEW agent/<branch>` early and often: after each working slice, not only
  at the end. After main says merged, `git rebase main` and continue.
- When all your tasks are done: `DONE` with a summary, test counts,
  measurements and follow-ups. End with that summary as your final reply.
