# Contributing to WizRec

Thanks for helping. WizRec is GPL-3.0-or-later; by contributing you agree your work is
released under that licence.

## Clean-room rules (non-negotiable)

WizRec opens Camtasia projects through **interoperability from observed behaviour**. To keep
the project legally clean, every contributor follows these rules. A pull request that breaks
one is closed, however useful it is.

1. **No TechSmith code.** Never copy, transcribe or paraphrase decompiled or disassembled
   TechSmith code. Don't paste snippets from it into issues, comments or commits either.
2. **Two roles, one wall.** Reverse-engineering findings are written as *behavioural specs*
   in `docs/specs/*.md`: **what** happens (keys, values, units, pictures), never **how**
   TechSmith's code does it. Implementers work only from those specs, the project files and
   reference renders. If you have studied TechSmith binaries, write specs, not the code
   that implements them.
3. **Prefer black-box methods**, in this order: your own project and media files; your own
   Camtasia exports as reference renders; running Camtasia and observing it; static
   analysis only for an interoperability question nothing else can answer. Tag every spec
   claim `[obs]` (observed), `[inf]` (inferred) or `[?]` (unknown).
4. **No licensing work of any kind.** Nothing that analyses, patches, hooks or emulates
   Camtasia's licensing, activation, accounts or trial watermark, and nothing that unlocks
   Camtasia. Such contributions are refused.
5. **No TechSmith assets in the repository**: no themes, shaders (`.tscshadervid`,
   `.tsceffect`), sample projects, callout art, cursors, sounds, icons or fonts copied from
   Camtasia. Tests may *read* Camtasia's sample projects from `/Applications/Camtasia.app`
   when installed and must skip when it isn't. When a user's project references TechSmith
   content, WizRec renders it from the user's copy and never redistributes it.
6. **Our own assets only.** New backgrounds, transitions, callout presets, cursors and click
   effects (`Sources/WizRecAssets`) are written from scratch. Fonts must be OFL (or another
   GPL-compatible licence), downloaded from the upstream project, unmodified, with the
   licence file next to them and a SHA-256 entry in `THIRD_PARTY_NOTICES.md`.
7. **Names.** Never put "Camtasia" in a product, module, bundle or type name. Describing
   compatibility ("opens Camtasia projects") is fine.
8. **Personal data.** Never commit someone's projects, recordings or media. `.trec` files
   can contain window titles; don't log or vendor them.

## Project files are a compatibility contract

- Read and write projects only through `TSCProjKit` (and `TimelineEngine` commands for
  edits). It keeps unknown keys, key order and the exact text of numbers.
- Never re-serialise a project through `Codable` or `JSONSerialization`.
- Every edit command has an expected-JSON test and a byte-identical undo test.

## Setting up

```sh
brew install ffmpeg pkg-config
swift build
swift test
scripts/make-app.sh && open build/WizRec.app
```

Golden-frame tests need reference exports (`REFS_DIR`) and skip without them; performance
tests run with `WIZREC_PERF=1`. `WIZREC_ASSET_DUMP=<dir> swift test --filter AssetPreview`
writes PNG previews of the built-in library.

## Code conventions

- Swift 6 language mode with strict concurrency; must build with the Swift 6.0 toolchain.
- Every public type gets a one- or two-line doc comment that states its units (ticks or
  seconds, pixels or fractions).
- Project data is untrusted input: no force-unwraps on it; fall back to the format's defaults.
- `@unchecked Sendable` only with a comment that justifies it.
- Tests use Swift Testing (`import Testing`); fixtures in `Tests/<Module>Tests/Fixtures` must
  be original or contributor-owned.
- New dependencies must be GPL-3.0-compatible; open an issue first.
- Metal shaders are compiled at runtime from source strings, so no Metal toolchain is needed.

## Commits and pull requests

- Imperative subject line ("Add iris transition"), one logical change per commit.
- `swift build && swift test` green, no new warnings.
- Describe how you verified the change; for format behaviour, cite the spec section or the
  evidence (which project, which reference render).
