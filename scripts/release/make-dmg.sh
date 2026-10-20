#!/bin/bash
# Packs WizRec.app into a compressed, read-only disk image with an /Applications shortcut,
# the GPL licence and the third-party notices.
#
#   scripts/release/make-dmg.sh build/WizRec.app build/WizRec-0.1.0.dmg
#
# Uses `diskutil image create from` (APFS volume, lzfse-compressed ULFO) where it exists:
# macOS 27 deprecates `hdiutil create`. Older systems (and CI runners without it) fall back
# to `hdiutil create` (HFS+, zlib-compressed UDZO). WIZREC_DMG_TOOL=diskutil|hdiutil forces
# one; the default is auto.
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

TOOL=${WIZREC_DMG_TOOL:-auto}
if [ "$TOOL" = auto ]; then
  if diskutil image create from --help 2>/dev/null | grep -q -- '--volumeName'; then TOOL=diskutil; else TOOL=hdiutil; fi
fi

rm -f "$OUT"
case "$TOOL" in
  diskutil)
    # It prints "[n% completed]" progress on stderr; show its output only on failure.
    if ! clog=$(diskutil image create from --format ULFO --volumeName "WizRec" "$STAGE" "$OUT" 2>&1); then
      echo "$clog" >&2; echo "error: diskutil image create failed" >&2; exit 1
    fi ;;
  hdiutil)
    hdiutil create -volname "WizRec" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT" >/dev/null ;;
  *) echo "error: WIZREC_DMG_TOOL must be auto, diskutil or hdiutil (got $TOOL)" >&2; exit 2 ;;
esac
# Checksum check. `hdiutil verify` is not deprecated on macOS 27 and `diskutil image` has no
# equivalent; verify-dmg.sh additionally mounts the image.
if ! vlog=$(hdiutil verify "$OUT" 2>&1); then
  echo "$vlog" >&2; echo "error: $OUT failed its checksum" >&2; exit 1
fi
echo "Wrote $OUT ($(du -h "$OUT" | awk '{print $1}'), $TOOL)"
