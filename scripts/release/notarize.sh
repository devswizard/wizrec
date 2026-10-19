#!/bin/bash
# Submits a signed WizRec.app or .dmg to Apple's notary service, waits, and staples the ticket.
#
#   WIZREC_NOTARY_PROFILE=wizrec-notary scripts/release/notarize.sh build/WizRec.app
#   DRY_RUN=1 WIZREC_NOTARY_PROFILE=x scripts/release/notarize.sh build/WizRec.app
#
# Credentials are a notarytool keychain profile, created once by the maintainer with
#   xcrun notarytool store-credentials wizrec-notary --apple-id <id> --team-id <TEAMID>
# (it prompts for an app-specific password and keeps it in the keychain). Only the profile
# *name* is passed here; no secret ever appears in the repo, the command line or the logs.
set -euo pipefail

TARGET=${1:?usage: notarize.sh <WizRec.app|file.dmg>}
PROFILE=${WIZREC_NOTARY_PROFILE:?set WIZREC_NOTARY_PROFILE to a notarytool keychain profile name}
DRY_RUN=${DRY_RUN:-0}

run() { echo "+ $*"; [ "$DRY_RUN" = 1 ] || "$@"; }

if [ "$DRY_RUN" != 1 ] && codesign -dv "$TARGET" 2>&1 | grep -q "Signature=adhoc"; then
  echo "error: $TARGET is ad-hoc signed; sign it with a Developer ID first (scripts/release/sign.sh)" >&2
  exit 1
fi

case "$TARGET" in
  *.app)
    ZIP="${TARGET%.app}-notarize.zip"
    run ditto -c -k --keepParent "$TARGET" "$ZIP"
    run xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
    run rm -f "$ZIP"
    run xcrun stapler staple "$TARGET"
    run spctl --assess --type execute --verbose=4 "$TARGET"
    ;;
  *.dmg)
    run xcrun notarytool submit "$TARGET" --keychain-profile "$PROFILE" --wait
    run xcrun stapler staple "$TARGET"
    run spctl --assess --type open --context context:primary-signature --verbose=4 "$TARGET"
    ;;
  *) echo "error: expected a .app or .dmg" >&2; exit 1;;
esac
