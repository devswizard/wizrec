#!/bin/bash
# Sparkle 2 (MIT) appcast for a release DMG: copies the DMG into build/updates/ (which keeps
# earlier DMGs for the archive) and runs Sparkle's generate_appcast, which signs every item
# with the EdDSA private key. Off by default: release.sh runs it only with SPARKLE=1.
#
#   WIZREC_DOWNLOAD_PREFIX=https://github.com/devswizard/wizrec/releases/download/v0.2.0/ \
#     SPARKLE=1 scripts/release.sh
#   scripts/release/appcast.sh build/WizRec-0.2.0.dmg            # the same, on an existing DMG
#
# Environment:
#   WIZREC_DOWNLOAD_PREFIX  required: URL the DMG will be downloaded from (ends with /)
#   SPARKLE_BIN             Sparkle's bin/ folder; default: the SwiftPM artifact
#                           (.build/artifacts/sparkle/Sparkle/bin, present after `swift build`)
#   SPARKLE_KEY_FILE        optional file with the EdDSA private key (CI: written from a
#                           secret to a temp file). Unset: generate_appcast reads the key from
#                           the maintainer's login keychain (created once by generate_keys).
#   SPARKLE_ACCOUNT         optional keychain account name of the key (generate_keys --account)
# The private key never enters the repository, the command line or the log.
set -euo pipefail
cd "$(dirname "$0")/../.."

DMG=${1:?usage: appcast.sh <WizRec-x.y.z.dmg>}
BIN=${SPARKLE_BIN:-.build/artifacts/sparkle/Sparkle/bin}
PREFIX=${WIZREC_DOWNLOAD_PREFIX:?set WIZREC_DOWNLOAD_PREFIX to the URL the DMG is served from}
[ -x "$BIN/generate_appcast" ] || { echo "error: $BIN/generate_appcast not found (run swift build, or set SPARKLE_BIN)" >&2; exit 1; }
case "$PREFIX" in https://*/) ;; *) echo "error: WIZREC_DOWNLOAD_PREFIX must be an https:// URL ending in /" >&2; exit 1;; esac

OUT=${SPARKLE_OUT:-build/updates}
mkdir -p "$OUT"
cp "$DMG" "$OUT/"

args=(--download-url-prefix "$PREFIX")
[ -n "${SPARKLE_ACCOUNT:-}" ] && args+=(--account "$SPARKLE_ACCOUNT")
if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
  # Via stdin so the path is not even visible in ps output.
  "$BIN/generate_appcast" "${args[@]}" --ed-key-file - "$OUT" < "$SPARKLE_KEY_FILE"
else
  "$BIN/generate_appcast" "${args[@]}" "$OUT"
fi
echo "Appcast: $OUT/appcast.xml — upload it to WIZREC_SPARKLE_FEED's URL and the DMG to $PREFIX"
