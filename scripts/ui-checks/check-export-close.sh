#!/bin/bash
# UI check (a): closing the project window or quitting while an export runs asks first;
# "Keep Exporting" keeps it running, "Cancel Export and Close/Quit" cancels it and removes the
# unfinished file. Exports go to the work dir (argument-domain WizRec.ExportFolder).
#
# Three batch presets (1080p + two 4K) keep the queue busy long enough to answer the alerts.
set -u
. "$(dirname "$0")/lib.sh"

PRESETS=("MP4 4K (H.264)" "MP4 4K (HEVC)")

# Every file left in the export folder must be a complete, readable movie.
check_outputs() {
    local bad=0 f
    for f in "$WORK/exports"/*; do
        [ -e "$f" ] || continue
        if ! ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" >/dev/null 2>&1; then
            log "unfinished file left: $f"; bad=1
        fi
    done
    ls -la "$WORK/exports"
    return $bad
}

start_export() {
    ax keys e cmd >/dev/null
    wait_until 10 'has_button Export' || { fail "export sheet did not open"; return 1; }
    for p in "${PRESETS[@]}"; do [ "$(ax check "$p")" = ok ] || log "preset checkbox missing: $p"; done
    ax click Export >/dev/null
    wait_until 10 'has_button "Cancel All"' && pass "export running" || { fail "export did not start"; return 1; }
    sleep 1
}

make_work
gui_lock

# --- Close the window while exporting
open_project -WizRec.ExportFolder "$WORK/exports" || exit 1
if start_export; then
    ax keys w cmd >/dev/null
    wait_until 5 'has_button "Keep Exporting"' && pass "close asks while exporting" || fail "close did not ask"
    ax click "Keep Exporting" >/dev/null
    sleep 1
    has_window demo && has_button "Cancel All" && pass "Keep Exporting: window open, export still running" \
        || fail "Keep Exporting did not keep the window and export"
    ax keys w cmd >/dev/null
    wait_until 5 'has_button "Cancel Export and Close"' || fail "second close did not ask"
    ax click "Cancel Export and Close" >/dev/null
    wait_until 20 '! has_window demo' && pass "window closed after cancelling" || fail "window still open"
    app_alive && pass "app still running after closing the window" || fail "app exited on window close"
    sleep 1
    check_outputs && pass "no unfinished export files after close" || fail "unfinished export files after close"
fi
stop_app

# --- Quit while exporting
rm -rf "$WORK/exports"; mkdir -p "$WORK/exports"
open_project -WizRec.ExportFolder "$WORK/exports" || exit 1
if start_export; then
    ax keys q cmd >/dev/null
    wait_until 5 'has_button "Keep Exporting"' && pass "quit asks while exporting" || fail "quit did not ask"
    ax click "Keep Exporting" >/dev/null
    sleep 1
    app_alive && has_button "Cancel All" && pass "Keep Exporting: app running, export still running" \
        || fail "Keep Exporting did not keep the app and export"
    ax keys q cmd >/dev/null
    wait_until 5 'has_button "Cancel Export and Quit"' || fail "second quit did not ask"
    ax click "Cancel Export and Quit" >/dev/null
    wait_until 20 '! app_alive' && pass "app quit after cancelling" || fail "app did not quit"
    check_outputs && pass "no unfinished export files after quit" || fail "unfinished export files after quit"
fi
stop_app
gui_unlock

[ "$FAILURES" -eq 0 ] && log "export close/quit: all checks passed" || log "export close/quit: $FAILURES failure(s) (work dir $WORK, log $WORK/app.log)"
exit "$FAILURES"
