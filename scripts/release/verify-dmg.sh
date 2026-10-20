#!/bin/bash
# Smoke-tests a release DMG: mounts it read-only (not in Finder), checks the app's bundle id,
# signature (inside out, strict) and that nothing links outside the bundle, then launches the
# app from the mounted image with `--quit-after 5` and expects a clean exit. Detaches always.
#
#   scripts/release/verify-dmg.sh build/WizRec-0.1.0.dmg
#
# Needs a GUI login session (the app opens its welcome window for a few seconds).
set -euo pipefail

DMG=${1:?usage: verify-dmg.sh <WizRec-x.y.z.dmg>}
EXPECT_ID=${WIZREC_BUNDLE_ID:-com.devswizard.WizRec}
MNT=$(mktemp -d "${TMPDIR:-/tmp}/wizrec-verify.XXXXXX")
cleanup() { hdiutil detach "$MNT" -quiet 2>/dev/null || hdiutil detach "$MNT" -force -quiet 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$DMG" >/dev/null
APP="$MNT/WizRec.app"
[ -d "$APP" ] || { echo "error: no WizRec.app in $DMG" >&2; exit 1; }
[ -L "$MNT/Applications" ] || { echo "error: no Applications link in $DMG" >&2; exit 1; }
[ -f "$MNT/LICENSE.txt" ] || { echo "error: no LICENSE.txt in $DMG" >&2; exit 1; }

id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
[ "$id" = "$EXPECT_ID" ] || { echo "error: bundle id $id, expected $EXPECT_ID" >&2; exit 1; }
if /usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  updates="on ($(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP/Contents/Info.plist"))"
else
  updates="off (no SUFeedURL)"
fi

codesign --verify --deep --strict "$APP"
authority=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)
signature=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Signature=//p' | head -n 1)
[ -d "$APP/Contents/Frameworks/Sparkle.framework" ] || { echo "error: Sparkle.framework missing" >&2; exit 1; }
for f in "$APP/Contents/MacOS/WizRec" "$APP"/Contents/Frameworks/*.dylib; do
  if otool -L "$f" | tail -n +2 | grep -qE "/opt/homebrew|/usr/local|/Cellar/"; then
    echo "error: $f links outside the bundle" >&2; exit 1
  fi
done

start=$(date +%s)
log=$(mktemp "${TMPDIR:-/tmp}/wizrec-verify-log.XXXXXX")
status=0
"$APP/Contents/MacOS/WizRec" --quit-after 5 >"$log" 2>&1 || status=$?
elapsed=$(( $(date +%s) - start ))
if [ "$status" != 0 ] || grep -qE "dyld|Library not loaded|image not found" "$log"; then
  cat "$log" >&2; rm -f "$log"
  echo "error: app exited with status $status" >&2; exit 1
fi
rm -f "$log"
echo "OK $DMG: $id $version, signed ${authority:-${signature:-?}}, updates $updates, launched and quit cleanly in ${elapsed}s"
