#!/bin/bash
# Smoke-tests a release DMG: mounts it read-only (not in Finder), checks the app's bundle id,
# signature (inside out, strict) and that nothing links outside the bundle, then launches the
# app from the mounted image with `--quit-after 5` and expects a clean exit. Detaches always.
#
#   scripts/release/verify-dmg.sh build/WizRec-0.1.0.dmg
#
# Needs a GUI login session (the app opens its welcome window for a few seconds).
#
# Mounts with `diskutil image attach` where it exists (macOS 27 deprecates `hdiutil attach`
# and `hdiutil detach`), else with hdiutil. WIZREC_DMG_TOOL=diskutil|hdiutil forces one.
set -euo pipefail

DMG=${1:?usage: verify-dmg.sh <WizRec-x.y.z.dmg>}
EXPECT_ID=${WIZREC_BUNDLE_ID:-com.devswizard.WizRec}
TOOL=${WIZREC_DMG_TOOL:-auto}
if [ "$TOOL" = auto ]; then
  if diskutil image attach --help 2>/dev/null | grep -q -- '--mountPoint'; then TOOL=diskutil; else TOOL=hdiutil; fi
fi
case "$TOOL" in diskutil|hdiutil) ;; *) echo "error: WIZREC_DMG_TOOL must be auto, diskutil or hdiutil (got $TOOL)" >&2; exit 2 ;; esac

MNT=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/wizrec-verify.XXXXXX")" && pwd -P)   # real path, as mount(8) prints it
DEV=""   # whole-disk node of the attached image (diskutil path), e.g. /dev/disk17
cleanup() {
  if [ "$TOOL" = diskutil ]; then
    if [ -n "$DEV" ]; then
      diskutil eject "$DEV" >/dev/null 2>&1 \
        || { diskutil unmountDisk force "$DEV" >/dev/null 2>&1; diskutil eject "$DEV" >/dev/null 2>&1; } || true
    elif mount | grep -qF " on $MNT ("; then
      diskutil eject "$MNT" >/dev/null 2>&1 || true   # attached, but no /dev node parsed
    fi
  else
    hdiutil detach "$MNT" -quiet 2>/dev/null || hdiutil detach "$MNT" -force -quiet 2>/dev/null || true
  fi
  rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

if [ "$TOOL" = diskutil ]; then
  attach_out=$(diskutil image attach --readOnly --nobrowse --mountPoint "$MNT" "$DMG")
  DEV=$(printf '%s\n' "$attach_out" | awk '/^\/dev\/disk[0-9]+[ \t]/ { print $1; exit }')
  [ -n "$DEV" ] || { echo "$attach_out" >&2; echo "error: could not attach $DMG" >&2; exit 1; }
else
  hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$DMG" >/dev/null
fi
APP="$MNT/WizRec.app"
[ -d "$APP" ] || { echo "error: no WizRec.app in $DMG" >&2; exit 1; }
[ -L "$MNT/Applications" ] || { echo "error: no Applications link in $DMG" >&2; exit 1; }
[ -f "$MNT/LICENSE.txt" ] || { echo "error: no LICENSE.txt in $DMG" >&2; exit 1; }

id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
[ "$id" = "$EXPECT_ID" ] || { echo "error: bundle id $id, expected $EXPECT_ID" >&2; exit 1; }
# Sparkle entries: off (neither) or on (https feed + 32-byte key); a half configuration fails.
# WIZREC_EXPECT_UPDATER=on|off also requires that state.
updater=$("$(dirname "$0")/sparkle-plist-check.sh" "$APP" ${WIZREC_EXPECT_UPDATER:+--expect "$WIZREC_EXPECT_UPDATER"})
case "$updater" in
  on\ *) updates="on (${updater#on })" ;;
  *) updates="off (no SUFeedURL/SUPublicEDKey)" ;;
esac

codesign --verify --deep --strict "$APP"
authority=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)
signature=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Signature=//p' | head -n 1)
[ -d "$APP/Contents/Frameworks/Sparkle.framework" ] || { echo "error: Sparkle.framework missing" >&2; exit 1; }
for l in Sparkle/LICENSE MANIFEST.txt WizRec-LICENSE.txt THIRD_PARTY_NOTICES.md; do
  [ -f "$APP/Contents/Resources/Licenses/$l" ] || { echo "error: Licenses/$l missing" >&2; exit 1; }
done
# Every Mach-O in the bundle (app, dylibs, Sparkle and its helpers): load paths must stay in
# the bundle (@rpath/@loader_path/@executable_path) or the OS (/usr/lib, /System); run paths
# (LC_RPATH) the same. A path into Homebrew, /usr/local, Xcode or the Command Line Tools
# works only on the build machine. WIZREC_ALLOW_BUILD_RPATHS=1 turns run-path findings
# into warnings, for checking releases built before bundle-dylibs.sh stripped them (v0.1.0).
in_bundle_or_os() { case "$1" in @rpath/*|@loader_path*|@executable_path*|/usr/lib/*|/System/*) return 0;; *) return 1;; esac; }
machos=0; bad=0; rpath_warn=0
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q '^Mach-O' || continue
  machos=$((machos + 1))
  rel=${f#"$APP"/}
  # otool -L: a header line per architecture ("<file> (architecture …):"), then the load
  # commands; a dylib's own install name (LC_ID_DYLIB) is listed too and must obey the same rule.
  while IFS= read -r dep; do
    in_bundle_or_os "$dep" || { echo "error: $rel loads $dep (outside the bundle)" >&2; bad=1; }
  done < <(otool -L "$f" | grep -v ':$' | awk 'NF{print $1}')
  while IFS= read -r p; do
    in_bundle_or_os "$p" && continue
    if [ "${WIZREC_ALLOW_BUILD_RPATHS:-0}" = 1 ]; then
      echo "warning: $rel has run path $p (outside the bundle)" >&2; rpath_warn=$((rpath_warn + 1))
    else
      echo "error: $rel has run path $p (outside the bundle)" >&2; bad=1
    fi
  done < <(otool -l "$f" | awk '/cmd LC_RPATH/{r=1} r&&/ path /{print $2; r=0}')
done < <(find "$APP/Contents" -type f -print0)
[ "$machos" -gt 1 ] || { echo "error: no Mach-O files found in $APP" >&2; exit 1; }
[ "$bad" = 0 ] || exit 1

start=$(date +%s)
log=$(mktemp "${TMPDIR:-/tmp}/wizrec-verify-log.XXXXXX")
status=0
# No window restoration: the smoke test neither reopens nor saves the windows of an installed
# WizRec that shares the bundle ID (same flag as scripts/ui-checks).
"$APP/Contents/MacOS/WizRec" -ApplePersistenceIgnoreState YES --quit-after 5 >"$log" 2>&1 || status=$?
elapsed=$(( $(date +%s) - start ))
if [ "$status" != 0 ] || grep -qE "dyld|Library not loaded|image not found" "$log"; then
  cat "$log" >&2; rm -f "$log"
  echo "error: app exited with status $status" >&2; exit 1
fi
rm -f "$log"
paths="load/run paths clean in $machos Mach-O files"
[ "$rpath_warn" = 0 ] || paths="$paths except $rpath_warn build run path(s)"
echo "OK $DMG: $id $version, signed ${authority:-${signature:-?}}, updates $updates, $paths, launched and quit cleanly in ${elapsed}s (mounted with $TOOL)"
