#!/bin/sh
# Re-runs every golden-frame and golden-sheet suite against the user's Camtasia
# reference exports. One command once references land:
#
#   scripts/golden.sh                 # status + golden + sheet suites
#   scripts/golden.sh --calibrate     # also write $GOLDEN_OUT/calibration/<case>.json
#   scripts/golden.sh --status        # only list which cases have references
#
# Environment: REFS_DIR (default ~/WorkDir/vibe_coding/camtasia_rea_refs),
# GOLDEN_OUT (artefacts, default $TMPDIR/WizRecGolden), GOLDEN_DUMP=1,
# GOLDEN_PREFER=mp4 (compare reference.mp4 even where a ProRes reference.mov exists).
# See docs/testing/golden-rerun.md.
set -eu

REFS_DIR="${REFS_DIR:-$HOME/WorkDir/vibe_coding/camtasia_rea_refs}"
export REFS_DIR
GOLDEN_OUT="${GOLDEN_OUT:-${TMPDIR:-/tmp}/WizRecGolden}"
export GOLDEN_OUT

mode=run
for a in "$@"; do
    case "$a" in
        --calibrate) GOLDEN_CALIBRATE=1; export GOLDEN_CALIBRATE ;;
        --status) mode=status ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown argument $a" >&2; exit 2 ;;
    esac
done

if [ ! -d "$REFS_DIR" ]; then
    echo "REFS_DIR $REFS_DIR does not exist; run: swift run wizrec-testgen && swift run wizrec-testgen sheets" >&2
    exit 1
fi

# Status: one line per case/sheet.
have=0; total=0
for m in "$REFS_DIR"/*/golden.json "$REFS_DIR"/effects/*/sheet.json "$REFS_DIR"/callouts/*/sheet.json \
         "$REFS_DIR"/research/cursor/*/sheet.json; do
    [ -f "$m" ] || continue
    d=$(dirname "$m"); total=$((total + 1))
    refs=""
    for r in reference.mov reference.mp4 reference.png; do
        if [ -f "$d/$r" ]; then refs="$refs $r"; fi
    done
    if [ -n "$refs" ]; then have=$((have + 1)); echo "ref    ${d#"$REFS_DIR"/}:$refs"
    else echo "none   ${d#"$REFS_DIR"/}"; fi
done
echo "$have of $total cases/sheets have a reference export (sheets may also use a Camtasia-saved thumbnail)."
if [ "$mode" = status ]; then exit 0; fi

cd "$(dirname "$0")/.."
rm -rf "$GOLDEN_OUT/calibration"
rc=0
swift test --filter 'GoldenTests\.(GoldenFrameTests|SheetGoldenTests)' || rc=$?
if [ "${GOLDEN_CALIBRATE:-0}" = 1 ] && [ -d "$GOLDEN_OUT/calibration" ]; then
    echo "calibration ($GOLDEN_OUT/calibration): case  reference  frames  minSSIM  minCellSSIM  minPSNR  suggested"
    for f in "$GOLDEN_OUT"/calibration/*.json; do
        line=""
        for k in caseName reference frames minSSIM minCellSSIM minPSNR suggestedPsnrMin; do
            v=$(plutil -extract "$k" raw -o - "$f" 2>/dev/null || echo "-")
            line="$line  $v"
        done
        echo "$line"
    done
    echo "paste-ready (review first; never calibrate a case that fails SSIM):"
    echo "  // TestGen.psnrMinByCase / TestGen.sheetThresholds"
    for f in "$GOLDEN_OUT"/calibration/*.json; do
        v=$(plutil -extract swift raw -o - "$f" 2>/dev/null) && echo "  $v"
    done
fi
exit "$rc"
