#!/bin/bash
# Code-signs WizRec.app (bundled dylibs first, then the app) or a .dmg.
#
#   WIZREC_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" scripts/release/sign.sh build/WizRec.app
#   scripts/release/sign.sh build/WizRec.app            # no identity: ad-hoc ("-"), local use only
#   DRY_RUN=1 scripts/release/sign.sh build/WizRec.app  # print the commands only
#
# The identity comes from the environment only and must already be in the keychain (or a
# CI keychain created from repository secrets). Nothing secret lives in this repo.
# With a Developer ID identity (or WIZREC_HARDENED=1): hardened runtime, secure timestamp and
# WizRec.entitlements. Any other identity (self-signed "WizRec Dev"): plain signature.
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
elif [[ "$IDENTITY" == "Developer ID Application:"* ]] || [ "${WIZREC_HARDENED:-0}" = 1 ]; then
  opts=(--force --timestamp --options runtime --sign "$IDENTITY")
  app_opts=("${opts[@]}" --entitlements "$ENTITLEMENTS")
else
  # A local/self-signed identity (e.g. "WizRec Dev") has no Team ID, so the hardened
  # runtime's library validation would refuse the bundled dylibs, and Apple's timestamp
  # service does not countersign it. Plain signature; cannot be notarized.
  echo "note: '$IDENTITY' is not a Developer ID identity; signing without hardened runtime (local use, no notarization)"
  opts=(--force --sign "$IDENTITY")
  app_opts=("${opts[@]}")
fi

# Sparkle 2, inside out (Sparkle's documented order): XPC services, Autoupdate, Updater.app,
# then the framework. Downloader.xpc keeps its own (sandbox) entitlements.
sign_sparkle() {
  local fw=$1 v
  v="$fw/Versions/B"
  [ -d "$v" ] || v="$fw/Versions/Current"
  if [ -d "$v/XPCServices/Installer.xpc" ]; then run codesign "${opts[@]}" "$v/XPCServices/Installer.xpc"; fi
  if [ -d "$v/XPCServices/Downloader.xpc" ]; then
    run codesign "${opts[@]}" --preserve-metadata=entitlements "$v/XPCServices/Downloader.xpc"
  fi
  if [ -f "$v/Autoupdate" ]; then run codesign "${opts[@]}" "$v/Autoupdate"; fi
  if [ -d "$v/Updater.app" ]; then run codesign "${opts[@]}" "$v/Updater.app"; fi
  run codesign "${opts[@]}" "$fw"
}

case "$TARGET" in
  *.dmg)
    run codesign "${opts[@]}" "$TARGET"
    run codesign --verify --verbose=2 "$TARGET"
    ;;
  *.app)
    shopt -s nullglob
    for f in "$TARGET"/Contents/Frameworks/*.dylib; do
      run codesign "${opts[@]}" "$f"
    done
    for f in "$TARGET"/Contents/Frameworks/*.framework; do
      case "$(basename "$f")" in
        Sparkle.framework) sign_sparkle "$f";;
        *) run codesign "${opts[@]}" "$f";;
      esac
    done
    run codesign "${app_opts[@]}" "$TARGET"
    run codesign --verify --deep --strict --verbose=2 "$TARGET"
    ;;
  *) echo "error: expected a .app or .dmg" >&2; exit 1;;
esac
