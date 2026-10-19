#!/bin/bash
# Packs WizRec.app into a compressed, read-only disk image with an /Applications shortcut,
# the GPL licence and the third-party notices.
#
#   scripts/release/make-dmg.sh build/WizRec.app build/WizRec-0.1.0.dmg
set -euo pipefail

APP=${1:?usage: make-dmg.sh <WizRec.app> <out.dmg>}
OUT=${2:?usage: make-dmg.sh <WizRec.app> <out.dmg>}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/wizrec-dmg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/WizRec.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/LICENSE" "$STAGE/LICENSE.txt"
[ -f "$ROOT/THIRD_PARTY_NOTICES.md" ] && cp "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGE/THIRD_PARTY_NOTICES.md"

rm -f "$OUT"
hdiutil create -volname "WizRec" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT" >/dev/null
hdiutil verify "$OUT" >/dev/null
echo "Wrote $OUT ($(du -h "$OUT" | cut -f1))"
