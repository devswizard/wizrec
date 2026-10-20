#!/bin/bash
# UI check (d): the sidebar's Audio tab lists Camtasia's eight Audio Effects items.
# Applying them needs a timeline selection, which cannot be scripted (the timeline draws its
# clips itself); the apply path is covered by AudioPanelTests.
set -u
. "$(dirname "$0")/lib.sh"

ITEMS=(aiNoiseRemoval audioCompression captions clipSpeed emphasize fadeIn fadeOut pitch)   # AudioPanelItem raw values

make_work
gui_lock
open_project || exit 1
[ "$(ax click Audio)" = ok ] && pass "Audio tab selected" || fail "no Audio tab"
sleep 1
missing=0
for i in "${ITEMS[@]}"; do has_el "library.$i" || { log "missing tile: $i"; missing=$((missing + 1)); }; done
[ "$missing" -eq 0 ] && pass "Audio tab lists all ${#ITEMS[@]} items" || fail "$missing Audio item(s) missing"
app_alive && pass "app responsive" || fail "app exited"
stop_app
gui_unlock

[ "$FAILURES" -eq 0 ] && log "audio panel: all checks passed" || log "audio panel: $FAILURES failure(s) (work dir $WORK)"
exit "$FAILURES"
