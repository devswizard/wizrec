#!/bin/bash
# Code-signs WizRec.app (bundled dylibs first, then the app) or a .dmg.
#
#   WIZREC_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" scripts/release/sign.sh build/WizRec.app
#   scripts/release/sign.sh build/WizRec.app            # no identity: ad-hoc ("-"), local use only
#   DRY_RUN=1 scripts/release/sign.sh build/WizRec.app  # print the commands only
#
# The identity comes from the environment only and must already be in the keychain (or a
# CI keychain created from repository secrets). Nothing secret lives in this repo.
# With a real identity: hardened runtime, secure timestamp and WizRec.entitlements.
set -euo pipefail

TARGET=${1:?usage: sign.sh <WizRec.app|file.dmg>}
IDENTITY=${WIZREC_SIGN_IDENTITY:--}
DRY_RUN=${DRY_RUN:-0}
HERE=$(cd "$(dirname "$0")" && pwd)
ENTITLEMENTS="$HERE/WizRec.entitlements"

run() { echo "+ $*"; [ "$DRY_RUN" = 1 ] || "$@"; }

if [ "$IDENTITY" = "-" ]; then
  echo "note: WIZREC_SIGN_IDENTITY not set; ad-hoc signing (runs on this Mac only, cannot be notarized)"
  opts=(--force --sign -)
  app_opts=("${opts[@]}")
else
  opts=(--force --timestamp --options runtime --sign "$IDENTITY")
  app_opts=("${opts[@]}" --entitlements "$ENTITLEMENTS")
fi

case "$TARGET" in
  *.dmg)
    run codesign "${opts[@]}" "$TARGET"
    run codesign --verify --verbose=2 "$TARGET"
    ;;
  *.app)
    shopt -s nullglob
    for f in "$TARGET"/Contents/Frameworks/*.dylib "$TARGET"/Contents/Frameworks/*.framework; do
      run codesign "${opts[@]}" "$f"
    done
    run codesign "${app_opts[@]}" "$TARGET"
    run codesign --verify --deep --strict --verbose=2 "$TARGET"
    ;;
  *) echo "error: expected a .app or .dmg" >&2; exit 1;;
esac
