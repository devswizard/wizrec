# Re-running the golden gates when references land

Status (2026-10-19, session 3): **no Camtasia reference exports yet.** Every
golden-frame case and golden sheet skips cleanly; the harness self-tests
(WizRec's own render used as the reference) run and pass on every
`swift test`.

## What skips, and how

| Suite | Without `REFS_DIR` | `REFS_DIR` set, no export yet |
|---|---|---|
| `GoldenFrameTests` (15 cases) | suite disabled | each case prints `golden <case>: no reference.mp4 yet, skipped` and passes |
| `SheetGoldenTests` (EF1–EF9, CO1–CO2) | suite disabled | each sheet prints `sheet <name>: no reference yet …, skipped`; EF8/EF9 print `after-EF0, skipped` |
| `GoldenHarnessSelfTests`, `SheetHarnessSelfTests` | run (need Metal) | run |

The self-tests record 18 *known issues* on purpose (a reference shifted one
frame, a damaged cell); they are expected and do not fail the run.

## One command

```sh
scripts/golden.sh --status       # which cases/sheets have a reference
scripts/golden.sh                # run GoldenFrameTests + SheetGoldenTests
scripts/golden.sh --calibrate    # same, plus per-case SSIM/PSNR calibration
```

`REFS_DIR` defaults to `~/WorkDir/vibe_coding/camtasia_rea_refs`; failure
artefacts (rendered / reference / diff4x / SSIM PNGs) go to `$GOLDEN_OUT`
(default `$TMPDIR/WizRecGolden`). `GOLDEN_DUMP=1` keeps artefacts for every
frame. How to make the exports: `reference-exports.md` (frames) and
`camtasia-session-2.md` (sheets).

## Setting `psnrMin` (only from real data)

The golden manifests gate on SSIM (0.97 frames, 0.95 sheets) and the marker
centroid. `psnrMin` is `nil` everywhere until real references exist. The hook:

1. `scripts/golden.sh --calibrate` writes
   `$GOLDEN_OUT/calibration/<case>.json` with `minSSIM`, `minPSNR` and
   `suggestedPsnrMin` (lowest PSNR over the compared frames − 1 dB, rounded
   down to 0.5 dB) and prints a summary.
2. Review the failing/odd cases first: never calibrate on a case that fails
   SSIM.
3. Copy the values into `TestGen.psnrMinByCase`
   (`Sources/TestGenKit/TestGen.swift`, marked `TODO(S3-QA-1)`).
4. `swift run wizrec-testgen --force` rewrites each `golden.json` with the new
   floor (it never touches `reference.mp4`).
5. `scripts/golden.sh` again; commit the `TestGen` change with the numbers in
   the message.

The unit test `psnrMinStaysUnsetWithoutReferences` fails if someone sets a
floor before step 3; update it in the same commit.
