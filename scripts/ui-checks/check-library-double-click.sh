#!/bin/bash
# UI check (f): a real mouse double-click (CGEvent, not AXPress) on a Backgrounds library tile
# places the background at the playhead and selects it; the inspector then shows the
# background's parameters, and a typed value is saved into its sourceEffect. With a group open
# on the timeline (`--open-group`, the demo's Rev group), the double-click places it on the
# group's bottom track and records ShaderVidSource / RevBackground (shader-backgrounds.md §11).
set -u
. "$(dirname "$0")/lib.sh"

make_work
MOUSE="$WORK/mouse"
swiftc -O "$UI_DIR/mouse.swift" -o "$MOUSE" > "$WORK/mouse-build.log" 2>&1 || { fail "mouse helper did not build"; exit 1; }
LIB=$(printf %s "$WORK/library" | tr -s /)   # no "//" from a TMPDIR ending in /
TSC="$PROJECT/project.tscproj"
backgrounds() { python3 -I "$UI_DIR/backgrounds.py" "$TSC"; }

# double_click <tile identifier>: a real double-click in the middle of the tile.
double_click() {
    local f x y w h
    f=$(ax frame "$1") || return 1
    [ "$f" = missing ] && return 1
    read -r x y w h <<< "$(awk '{printf "%d %d %d %d", $1, $2, $3, $4}' <<< "${f//,/.}")"
    [ "$w" -gt 0 ] && [ "$h" -gt 0 ] || return 1
    "$MOUSE" click $((x + w / 2)) $((y + h / 2)) 2 >> "$WORK/app.log"
}

save_and_wait() {
    local before
    before=$(stat -f %m "$TSC")
    ax keys s cmd >/dev/null
    wait_until 15 '[ "$(stat -f %m "$TSC")" != "$before" ]' || sleep 2
    sleep 1
}

gui_lock

# Part 1: top level.
open_project -WizRec.BackgroundLibraryRoot "$LIB" || exit 1
[ "$(ax click Backgrounds)" = ok ] && pass "Backgrounds tab selected" || fail "no Backgrounds tab"
sleep 1
double_click library.wizrec-gradient-drift && pass "double-clicked Gradient Drift" || fail "Gradient Drift tile not on screen"
wait_until 20 'has_el inspector.background.Color0' && pass "placed and selected: inspector shows the background" \
    || fail "inspector shows no background controls after the double-click"
for id in inspector.background.Color1 inspector.background.Speed inspector.background.Speed.field; do
    has_el "$id" && pass "inspector has $id" || fail "inspector lacks $id"
done
[ "$(ax set inspector.background.Speed.field 3)" = ok ] && pass "typed Speed 3" || fail "no Speed field"
sleep 1
save_and_wait
line=$(backgrounds | grep "src=wizrec-gradient-drift.tscshadervid" | head -1)
log "saved: $line"
case "$line" in
    *" group=- svs=- rev=- speed=3"*) pass "top-level background saved with Speed 3, no ShaderVidSource";;
    *) fail "unexpected saved background: '$line'";;
esac
app_alive && pass "app responsive" || fail "app exited"
stop_app

# Part 2: the demo's Rev group (group 4) open, playhead at its end.
open_project --open-group --seek 25.66 -WizRec.BackgroundLibraryRoot "$LIB" || exit 1
grep -q "opened group 4 for editing" "$WORK/app.log" && pass "group 4 open" || fail "group 4 not opened"
[ "$(ax click Backgrounds)" = ok ] || fail "no Backgrounds tab"
sleep 1
double_click library.wizrec-soft-waves && pass "double-clicked Soft Waves" || fail "Soft Waves tile not on screen"
wait_until 20 'has_el inspector.background.Color0' && pass "placed into the group and selected" \
    || fail "no background selected after the double-click (see $WORK/app.log)"
save_and_wait
line=$(backgrounds | grep "src=wizrec-soft-waves.tscshadervid" | head -1)
log "saved: $line"
want="group=4 svs=$LIB/backgrounds/wizrec-soft-waves.tscshadervid rev=backgrounds/wizrec-soft-waves.tscshadervid"
case "$line" in
    *" $want "*) pass "Rev background recorded (ShaderVidSource, RevBackground)";;
    *) fail "unexpected saved background: '$line' (want '$want')";;
esac
[ -f "$LIB/backgrounds/wizrec-soft-waves.tscshadervid" ] && pass "library file written" || fail "no library file"
app_alive && pass "app responsive" || fail "app exited"
stop_app
gui_unlock

[ "$FAILURES" -eq 0 ] && log "library double-click: all checks passed" \
    || log "library double-click: $FAILURES failure(s) (work dir $WORK)"
exit "$FAILURES"
