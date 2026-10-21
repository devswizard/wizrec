#!/bin/bash
# UI check: canvas handles, crop mode, context menus, library tile drags and the Captions tab
# (APP15-1, ui-workflow.md §12 items 6–9), with real mouse input on a copy of the demo project.
#
#   1. a click on the canvas selects a clip; dragging its corner scales it, its knob rotates
#      it, crop mode (⌥⌘C) and its left edge handle crop it; each is one undo step (⌘Z undoes);
#   2. the canvas context menu offers clipboard, Scale and Crop Mode; the timeline clip menu
#      offers Ripple Cut, Duplicate, Clip Speed and the track switches; ⌘D duplicates;
#   3. an effect tile dragged from the Effects tab onto the canvas clip is added to it;
#   4. the Captions tab: Add at Playhead adds a caption, typing into its row edits it.
#
# The app logs edits, selection (with handle screen positions) and opened menus
# (-WizRec.LogUI YES). SHOTS_DIR=<dir>: window snapshots (handles, crop mode, captions tab).
set -u
. "$(dirname "$0")/lib.sh"

shots=()
[ -n "${SHOTS_DIR:-}" ] && shots=(-WizRec.WindowSnapshots "$SHOTS_DIR")
snap() { [ -n "${SHOTS_DIR:-}" ] && kill -USR1 "$APP_PID" 2>/dev/null && sleep 1; return 0; }

make_work
MOUSE="$WORK/mouse"
swiftc -O "$UI_DIR/mouse.swift" -o "$MOUSE" > "$WORK/mouse-build.log" 2>&1 || { fail "mouse helper did not build"; cat "$WORK/mouse-build.log"; exit 1; }

# field <name>: the value of name=… on the last "selected" line.
field() { grep '^WizRec: selected \[' "$WORK/app.log" | tail -1 | tr ' ' '\n' | grep "^$1=" | head -1 | cut -d= -f2; }
edits() { grep -c '^WizRec: edit ' "$WORK/app.log"; }
last_edit() { grep '^WizRec: edit ' "$WORK/app.log" | tail -1 | sed 's/^WizRec: edit //'; }
last_menu() { grep '^WizRec: menu ' "$WORK/app.log" | tail -1; }
xy() { tr ',' ' ' <<< "$1"; }

# expect_edit <before> <what> <undo name>: a new edit whose undo name is <undo name>.
expect_edit() {
    if wait_until 10 '[ "$(edits)" -gt "$1" ]' && last_edit | grep -q "^undo=$3 "; then
        pass "$2 ($(last_edit))"
    else
        fail "$2: $(last_edit)"
    fi
}

# expect_menu <what> <item…>: the last opened menu lists every item.
expect_menu() {
    local what=$1 m missing=""
    shift
    wait_until 5 'last_menu | grep -q .' || true
    m=$(last_menu | sed 's/^WizRec: menu //' | tr '|' '\n' | sed 's/(off)//; s/(on)//')
    for i in "$@"; do grep -qxF "$i" <<< "$m" || missing="$missing $i"; done
    if [ -z "$missing" ]; then pass "$what lists: $*"; else fail "$what lacks:$missing ($(last_menu))"; fi
}

case_canvas() {
    : > "$WORK/app.log"
    open_project --no-audio --window-size 1280x800 --seek 2 -WizRec.LogUI YES -WizRec.SidebarTab effects \
        ${shots[@]+"${shots[@]}"} || return
    local f x y w h before c
    f=$(ax frame editor.canvas) || { fail "no canvas frame"; return; }
    read -r x y w h <<< "$f"
    "$MOUSE" click $((x + w / 2)) $((y + h / 2)) > /dev/null
    if ! wait_until 5 '[ -n "$(field corner2)" ]'; then fail "a canvas click selected no clip"; return; fi
    pass "canvas click selects a clip ($(grep '^WizRec: selected \[' "$WORK/app.log" | tail -1 | cut -d' ' -f3))"
    snap
    # Corner: drag 40 pt outward (up-right) → larger scale.
    local s0 s1 r0 r1 c0 c1
    s0=$(field scale)
    read -r cx cy <<< "$(xy "$(field corner2)")"
    before=$(edits)
    "$MOUSE" drag "$cx" "$cy" $((cx + 40)) $((cy - 25)) > /dev/null
    expect_edit "$before" "corner drag scales" "Change Property"
    sleep 0.6
    s1=$(field scale)
    awk -v a="$s0" -v b="$s1" 'BEGIN { exit !(b > a) }' && pass "scale $s0 → $s1" || fail "scale did not grow ($s0 → $s1)"
    # Knob: drag sideways → rotation changes.
    r0=$(field rotation)
    read -r kx ky <<< "$(xy "$(field knob)")"
    before=$(edits)
    "$MOUSE" drag "$kx" "$ky" $((kx + 60)) $((ky + 10)) > /dev/null
    expect_edit "$before" "knob drag rotates" "Change Property"
    sleep 0.6
    r1=$(field rotation)
    [ "$r0" != "$r1" ] && pass "rotation $r0 → $r1" || fail "rotation unchanged ($r0)"
    snap
    # Undo the rotation.
    before=$(edits)
    ax keys z cmd > /dev/null
    wait_until 5 '[ "$(edits)" -gt "$before" ]' && sleep 0.6
    [ "$(field rotation)" = "$r0" ] && pass "⌘Z undoes the rotation" || fail "rotation after undo: $(field rotation), want $r0"
    # Crop mode and the left edge.
    ax keys c cmd,opt > /dev/null
    wait_until 5 'grep -q "^WizRec: crop mode on" "$WORK/app.log"' && pass "⌥⌘C turns crop mode on" || fail "no crop mode"
    sleep 0.6
    snap
    c0=$(field cropLeft)
    read -r lx ly <<< "$(xy "$(field cropHandle)")"
    before=$(edits)
    "$MOUSE" drag "$lx" "$ly" $((lx + 30)) "$ly" > /dev/null
    expect_edit "$before" "edge drag crops" "Change Property"
    sleep 0.6
    c1=$(field cropLeft)
    awk -v a="${c1:-0}" 'BEGIN { exit !(a > 0) }' && pass "crop left = $c1" || fail "crop left not set (${c1:-none})"
    snap
    ax keys esc > /dev/null
    wait_until 5 'grep -q "^WizRec: crop mode off" "$WORK/app.log"' && pass "Esc leaves crop mode" || fail "crop mode stayed on"
    # Canvas context menu.
    "$MOUSE" rightclick $((x + w / 2)) $((y + h / 2)) > /dev/null
    sleep 1
    expect_menu "canvas menu" Cut Copy Duplicate Delete Scale "Crop Mode" Group
    snap
    ax keys esc > /dev/null
    # Timeline clip menu.
    read -r tx ty <<< "$(xy "$(field timeline)")"
    if [ -n "${tx:-}" ]; then
        "$MOUSE" rightclick "$tx" "$ty" > /dev/null
        sleep 1
        expect_menu "timeline clip menu" Copy Duplicate "Split at Playhead" "Ripple Delete" "Ripple Cut" "Clip Speed" "Lock Track"
        snap
        ax keys esc > /dev/null
    else
        fail "no timeline position for the selected clip"
    fi
    before=$(edits)
    ax keys d cmd > /dev/null
    expect_edit "$before" "⌘D duplicates" "Duplicate"
    # An effect tile onto the clip on the canvas.
    local tf tx2 ty2 tw th
    if tf=$(ax frame library.DropShadow); then
        read -r tx2 ty2 tw th <<< "$tf"
        before=$(edits)
        "$MOUSE" drag $((tx2 + tw / 2)) $((ty2 + th / 3)) $((x + w / 2)) $((y + h / 2)) 1.5 > /dev/null
        if wait_until 10 'grep -q "^WizRec: library drop effect DropShadow clip=[0-9]* ok=true" "$WORK/app.log"'; then
            pass "effect tile dropped on the canvas clip"
            expect_edit "$before" "the effect is one undo step" "Add Effect"
        else
            fail "effect tile drop on the canvas: $(grep '^WizRec: library drop' "$WORK/app.log" | tail -1)"
        fi
    else
        fail "no Drop Shadow tile"
    fi
    app_alive && pass "app responsive" || fail "app exited"
    stop_app
}

case_captions() {
    : > "$WORK/app.log"
    open_project --no-audio --window-size 1280x800 --seek 3 -WizRec.LogUI YES -WizRec.SidebarTab captions \
        ${shots[@]+"${shots[@]}"} || return
    local before
    has_el captions.generate && pass "Captions tab shows Generate Captions" || fail "no Generate Captions button"
    snap
    before=$(edits)
    ax click captions.addAtPlayhead > /dev/null
    if wait_until 8 '[ "$(edits)" -gt "$before" ]' && last_edit | grep -q '^undo=Add Caption '; then
        pass "Add at Playhead adds a caption"
        sleep 1
        before=$(edits)
        ax set captions.text.0 "Hello from WizRec" > /dev/null
        expect_edit "$before" "typing into the caption row edits it" "Edit Caption"
        snap
    else
        # The demo may have no audio under the playhead: then the panel says so in plain words.
        if grep -q '^WizRec: status Move the playhead over a clip with audio' "$WORK/app.log"; then
            pass "Add at Playhead explains it needs audio under the playhead"
        else
            fail "Add at Playhead did nothing: $(last_edit)"
        fi
    fi
    app_alive && pass "app responsive" || fail "app exited"
    stop_app
}

gui_lock
caffeinate -d -t 600 &
CAFF=$!
case_canvas
case_captions
kill "$CAFF" 2>/dev/null
gui_unlock

[ "$FAILURES" -eq 0 ] && log "canvas tools, menus, tile drags, captions: all checks passed" \
    || log "canvas tools: $FAILURES failure(s) (work dir $WORK, log $WORK/app.log)"
exit "$FAILURES"
