#!/bin/bash
# UI check: accessibility audit of every library tile on every library tab (APP11-4; stands in
# for a manual VoiceOver pass). The app lists its tiles (-WizRec.PrintLibrary YES); ax-audit
# (AXUIElement, see ax-audit.swift) selects each tab, scrolls through it and checks that every
# tile is in the accessibility tree as an AXButton with a non-empty, unique label, exposes
# AXPress, takes keyboard focus, that Tab / Shift-Tab move focus between tiles, and that Tab
# walks every tile (scrolling unrealized ones in) and leaves the grid predictably at both ends.
set -u
. "$(dirname "$0")/lib.sh"

make_work
AUDIT="$WORK/ax-audit"
swiftc -O "$UI_DIR/ax-audit.swift" -o "$AUDIT" > "$WORK/ax-audit-build.log" 2>&1 \
    || { fail "ax-audit did not build"; cat "$WORK/ax-audit-build.log"; exit 1; }

gui_lock
# A small window (minimum size): the tall tabs have tiles the lazy grid has not realized.
open_project --window-size 900x560 -WizRec.PrintLibrary YES || exit 1
grep '^library-tile ' "$WORK/app.log" | cut -d' ' -f2- > "$WORK/tiles.txt"
n=$(wc -l < "$WORK/tiles.txt" | tr -d ' ')
[ "$n" -gt 0 ] && pass "app lists $n library tiles" || fail "app listed no library tiles"

run_bounded 600 "$AUDIT" "$APP_PID" demo "$WORK/tiles.txt" > "$WORK/ax-audit.log" 2>&1
status=$?
while IFS= read -r line; do
    case "$line" in
        PASS\ *) pass "${line#PASS }";;
        FAIL\ *) fail "${line#FAIL }";;
    esac
done < "$WORK/ax-audit.log"
[ "$status" -eq 0 ] || grep -q '^FAIL ' "$WORK/ax-audit.log" || fail "ax-audit exited with $status"
app_alive && pass "app responsive" || fail "app exited"
stop_app
gui_unlock

[ "$FAILURES" -eq 0 ] && log "library AX audit: all checks passed" || log "library AX audit: $FAILURES failure(s) (work dir $WORK)"
exit "$FAILURES"
