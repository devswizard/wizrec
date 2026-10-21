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

The self-tests break a reference on purpose (a reference shifted one frame, a
damaged cell, an unreachable PSNR floor). Since QA14-3 (2026-10-21) the harness
hands those failures to a `GoldenFailures` collector and the self-tests check
them, so they record no *known issues*; a known issue in a run is always real.

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

## ProRes references (`reference.mov`)

Camtasia's H.264 exports are not bit-reproducible, so PSNR on them drifts
between exports. Where a ProRes export exists, put it next to the MP4 as
`reference.mov`: golden cases and movie sheets compare against the `.mov`
when present and fall back to `reference.mp4` (`ReferenceFile.resolve`).
`GOLDEN_PREFER=mp4` forces the MP4. The harness logs which file it compared
(`golden <case>: comparing against reference.mov`).

Measured on WizRec's own render as the reference (self-tests): ProRes 422 HQ
keeps PSNR at 64–67 dB on EF6 (H.264 20 Mbit/s: 53–68 dB) and ≥ 45 dB on
`keyframes-linear` at 960×540.

## Setting `psnrMin` (only from real data)

Floors are tied to the file they were measured on: `PSNRFloor(dB:reference:)`
writes `psnrMin` + `psnrReference` into `golden.json` / `sheet.json`, and the
harness enforces the floor only when it compares that same file (a ProRes floor
never gates an MP4). Sheets use `TestGen.sheetThresholds["<group>/<case>"]`
(`SheetThreshold(ssimMin:psnr:)`, default SSIM 0.95, no PSNR floor).

The golden manifests gate on SSIM (0.97 frames, 0.95 sheets) and the marker
centroid. `psnrMin` is `nil` everywhere until real references exist. The hook:

1. `scripts/golden.sh --calibrate` writes
   `$GOLDEN_OUT/calibration/<case>.json` with `minSSIM`, `minPSNR` and
   `suggestedPsnrMin` (lowest PSNR over the compared frames − 1 dB, rounded
   down to 0.5 dB) and prints a summary, plus paste-ready Swift entries for
   `TestGen.psnrMinByCase` and `TestGen.sheetThresholds`. Sheets record
   `minCellSSIM` too.
2. Review the failing/odd cases first: never calibrate on a case that fails
   SSIM.
3. Copy the entries into `TestGen.psnrMinByCase` / `TestGen.sheetThresholds`
   (`Sources/TestGenKit/TestGen.swift`, marked `TODO(S3-QA-1)`).
4. `swift run wizrec-testgen --force` rewrites each `golden.json` with the
   new floor; `swift run wizrec-testgen sheets` updates the thresholds in each
   `sheet.json`, keeping Camtasia-saved bundles (no `--force` needed). Neither
   touches `reference.*`.
5. `scripts/golden.sh` again; commit the `TestGen` change with the numbers in
   the message.

The unit tests `psnrMinStaysUnsetWithoutReferences` and
`sheetThresholdsStayDefaultWithoutReferences` fail if someone sets a floor
before step 3; update them in the same commit.
