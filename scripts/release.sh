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
#   WIZREC_SIGN_IDENTITY    codesign identity; unset = ad-hoc. A non-Developer-ID identity
#                           (self-signed "WizRec Dev") signs without hardened runtime
#   NOTARIZE=1              notarize + staple app and DMG (needs WIZREC_NOTARY_PROFILE and
#                           WIZREC_SIGN_IDENTITY; skipped with a warning when ad-hoc)
#   WIZREC_BUNDLE_ID        CFBundleIdentifier (default com.devswizard.WizRec)
#   WIZREC_SPARKLE_FEED     appcast https URL  } both or neither; written to Info.plist, the
#   WIZREC_SPARKLE_PUBKEY   EdDSA public key   } app's updater is off without them
#   SPARKLE=1               also write a signed appcast (needs WIZREC_DOWNLOAD_PREFIX; see
#                           scripts/release/appcast.sh and docs/RELEASING.md)
#   VERIFY=1                mount the DMG and launch the app (--quit-after 5) as a smoke test
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${VERSION:-0.1.0}
export VERSION
APP=build/WizRec.app
DMG=build/WizRec-$VERSION.dmg

if [ "${NOTARIZE:-0}" = 1 ] && [ -z "${WIZREC_SIGN_IDENTITY:-}" ]; then
  echo "warning: NOTARIZE=1 but WIZREC_SIGN_IDENTITY is not set; ad-hoc build, skipping notarization" >&2
  NOTARIZE=0
fi

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

if [ "${VERIFY:-0}" = 1 ]; then
  echo "== Verify DMG"
  scripts/release/verify-dmg.sh "$DMG"
fi

if [ "${SPARKLE:-0}" = 1 ]; then
  echo "== Sparkle appcast"
  scripts/release/appcast.sh "$DMG"
fi

shasum -a 256 "$DMG"
echo "Done: $DMG"
