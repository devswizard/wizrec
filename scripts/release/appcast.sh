#!/bin/bash
# Sparkle (MIT) appcast for a release DMG. Off by default: release.sh runs it only with
# SPARKLE=1, and the app does not contain the Sparkle updater yet (docs/RELEASING.md, "Sparkle").
#
#   SPARKLE_BIN=~/sparkle/bin SPARKLE=1 scripts/release.sh
#
# SPARKLE_BIN is the `bin/` folder of a Sparkle 2 release (generate_keys, generate_appcast).
# The EdDSA private key stays in the maintainer's keychain (created once with generate_keys);
# generate_appcast reads it from there. Output: build/updates/appcast.xml next to the DMG.
set -euo pipefail

DMG=${1:?usage: appcast.sh <WizRec-x.y.z.dmg>}
BIN=${SPARKLE_BIN:?set SPARKLE_BIN to the bin/ folder of a Sparkle 2 release}
[ -x "$BIN/generate_appcast" ] || { echo "error: $BIN/generate_appcast not found" >&2; exit 1; }

OUT=build/updates
mkdir -p "$OUT"
cp "$DMG" "$OUT/"
"$BIN/generate_appcast" --download-url-prefix "${WIZREC_DOWNLOAD_PREFIX:-https://example.invalid/wizrec/}" "$OUT"
echo "Appcast: $OUT/appcast.xml (set WIZREC_DOWNLOAD_PREFIX to the real release URL)"
