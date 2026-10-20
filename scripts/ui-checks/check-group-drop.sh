#!/bin/bash
# UI check (c): media dropped into an open group lands inside the group.
#
# A real Finder drag cannot be scripted reliably (the timeline draws its clips itself), so the
# app's closest scriptable route is used: `--group-drop <file>` opens the first group as a
# double-click does and hands the file to the timeline's group-drop handler, the same
# `onGroupDrop` → `placeInGroup` path a drop takes. The saved copy is then inspected.
set -u
. "$(dirname "$0")/lib.sh"

make_work
ffmpeg -v error -f lavfi -i "testsrc2=size=640x360:rate=30:duration=2" -pix_fmt yuv420p "$WORK/dropped.mp4"
TSCPROJ=${TSCPROJ:-$ROOT/.build/release/tscproj}
[ -x "$TSCPROJ" ] || (cd "$ROOT" && swift build -c release --product tscproj >/dev/null)
before=$("$TSCPROJ" info "$PROJECT")

gui_lock
# The timed quit starts at launch: a new build's slow first launch gets longer.
quit=20
app_warm || quit=60
launch_app "$PROJECT" --group-drop "$WORK/dropped.mp4" --save --quit-after "$quit"
wait_until $((quit + $(launch_timeout))) '! app_alive' || fail "app did not quit after the scripted drop"
grep -q "^WizRec: opened " "$WORK/app.log" && mark_warm
gui_unlock

grep "script:" "$WORK/app.log"
after=$("$TSCPROJ" info "$PROJECT")
grep -q "script: group drop into 4 accepted=true innerTrack0Clips=2" "$WORK/app.log" \
    && pass "drop accepted, inner track 0 has 2 clips" || fail "drop not placed (see $WORK/app.log)"
grep -q "script: saved dirty=false" "$WORK/app.log" && pass "project saved" || fail "project not saved"
# The new clip is nested in the group (indented under Group#4), its source is in the bin, and
# nothing was added at the top level.
echo "$after" | grep -q "media (3)" && pass "file imported into the media bin" || fail "media bin not updated"
echo "$after" | awk '/Group#4/{g=1;next} g && /^      [A-Za-z]+#[0-9]+ .*"dropped"/{f=1} END{exit !f}' \
    && pass "clip nested in group 4" || fail "dropped clip not inside the group"
[ "$(echo "$after" | grep -c '^    [A-Za-z]*#')" = "$(echo "$before" | grep -c '^    [A-Za-z]*#')" ] \
    && pass "no new top-level clip" || fail "top-level clips changed"
echo "$after" | sed -n '/^timeline:/,$p'

[ "$FAILURES" -eq 0 ] && log "group drop: all checks passed (work dir $WORK)" || log "group drop: $FAILURES failure(s) (work dir $WORK)"
exit "$FAILURES"
