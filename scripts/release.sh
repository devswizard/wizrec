#!/bin/bash
# Builds a WizRec release: app bundle with FFmpeg and its dependencies inside, signature,
# optional notarization, DMG, optional Sparkle appcast. See docs/RELEASING.md.
#
#   scripts/release.sh                         # ad-hoc signed DMG for local testing
#   VERSION=0.2.0 WIZREC_SIGN_IDENTITY="Developer ID Application: …" \
#     NOTARIZE=1 WIZREC_NOTARY_PROFILE=wizrec-notary scripts/release.sh
#   DRY_RUN=1 …                                # print signing/notary commands, run nothing remote
#
# Environment (all optional):
#   VERSION                 marketing version (default 0.1.0, passed to make-app.sh)
#   WIZREC_SIGN_IDENTITY    codesign identity; unset = ad-hoc
#   NOTARIZE=1              notarize + staple app and DMG (needs WIZREC_NOTARY_PROFILE)
#   SPARKLE=1               also write an appcast (needs SPARKLE_BIN; see docs/RELEASING.md)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${VERSION:-0.1.0}
export VERSION
APP=build/WizRec.app
DMG=build/WizRec-$VERSION.dmg

echo "== Build app (release)"
RELEASE=1 CONFIG=release scripts/make-app.sh

echo "== Bundle FFmpeg and dependencies"
scripts/release/bundle-dylibs.sh "$APP"

echo "== Sign app"
scripts/release/sign.sh "$APP"

if [ "${NOTARIZE:-0}" = 1 ]; then
  echo "== Notarize app"
  scripts/release/notarize.sh "$APP"
fi

echo "== Disk image"
scripts/release/make-dmg.sh "$APP" "$DMG"
if [ -n "${WIZREC_SIGN_IDENTITY:-}" ]; then
  scripts/release/sign.sh "$DMG"
  if [ "${NOTARIZE:-0}" = 1 ]; then
    echo "== Notarize DMG"
    scripts/release/notarize.sh "$DMG"
  fi
fi

if [ "${SPARKLE:-0}" = 1 ]; then
  echo "== Sparkle appcast"
  scripts/release/appcast.sh "$DMG"
fi

shasum -a 256 "$DMG"
echo "Done: $DMG"
