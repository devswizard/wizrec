#!/bin/bash
# UI check: drag and drop from "Finder" (APP14-1, ui-workflow.md §4), the empty states (§5)
# and the timeline toolbar's enabled states (§9).
#
# Real drags: drag.swift starts an NSDraggingSession with file URLs in a helper window and
# moves it with HID mouse events, as a drag from Finder does. The app logs each import
# ("WizRec: imported …") and every status line ("WizRec: status …").
#
#   1. start screen: a video dropped on it opens a new project with the video on the timeline;
#      that empty-then-filled project showed its first steps (canvas Record / Import Media,
#      the media bin's Import Media…) before the drop and not after;
#   2. open project (a copy of the demo): a video dropped on the canvas is added at the
#      playhead, one dropped on the timeline is added there, one dropped on the media bin only
#      goes into the bin; a text file and a folder are refused with a plain sentence; a dropped
#      project opens in its own window.
#
# SHOTS_DIR=<dir>: window snapshots (start screen, empty project, canvas drop outline).
set -u
. "$(dirname "$0")/lib.sh"

shots=()
[ -n "${SHOTS_DIR:-}" ] && shots=(-WizRec.WindowSnapshots "$SHOTS_DIR")
snap() { [ -n "${SHOTS_DIR:-}" ] && kill -USR1 "$APP_PID" 2>/dev/null && sleep 1; return 0; }

make_work
DRAG="$WORK/drag"
swiftc -O "$UI_DIR/drag.swift" -o "$DRAG" > "$WORK/drag-build.log" 2>&1 || { fail "drag helper did not build"; cat "$WORK/drag-build.log"; exit 1; }
ffmpeg -loglevel error -f lavfi -i testsrc=duration=2:size=320x240:rate=30 -pix_fmt yuv420p "$WORK/clip.mp4" \
    || { fail "ffmpeg could not make the test clip"; exit 1; }
echo "not media" > "$WORK/notes.txt"
mkdir -p "$WORK/Clips"
cp -R "$PROJECT" "$WORK/second.cmproj"

# center <ax key>: "x y" of the element's centre (screen points, top-left origin).
center() {
    local f x y w h
    f=$(ax frame "$1") || return 1
    read -r x y w h <<< "$f"
    [ -n "${h:-}" ] || return 1
    echo "$((x + w / 2)) $((y + h / 2))"
}

# expect_enabled <ax key> <true|false>: the control's AXEnabled.
expect_enabled() {
    local got
    got=$(ax enabled "$1" 2>/dev/null)
    if [ "$got" = "$2" ]; then pass "$1 enabled=$2"; else fail "$1 enabled=${got:-missing}, want $2"; fi
}

imports() { grep -c '^WizRec: imported ' "$WORK/app.log" 2>/dev/null; }
last_import() { grep '^WizRec: imported ' "$WORK/app.log" | tail -1; }

# drop_on <ax key> <dx> <dy> <hover s> <files…>: drags the files onto the element's centre
# moved by dx, dy points. With SHOTS_DIR, snapshots while the pointer hovers.
drop_on() {
    local key=$1 dx=$2 dy=$3 hover=$4 c x y
    shift 4
    c=$(center "$key") || { fail "no frame for $key"; return 1; }
    read -r x y <<< "$c"
    if [ -n "${SHOTS_DIR:-}" ]; then ( sleep 2.6; kill -USR1 "$APP_PID" 2>/dev/null ) & fi
    run_bounded 30 "$DRAG" $((x + dx)) $((y + dy)) --hover "$hover" "$@" >> "$WORK/drag.log" 2>&1
}

# expect_import <before> <what> <grep pattern>: a new import line matching the pattern.
expect_import() {
    local before=$1 what=$2 pat=$3
    if wait_until 20 '[ "$(imports)" -gt "$before" ]' && last_import | grep -q -- "$pat"; then
        pass "$what ($(last_import | sed 's/^WizRec: //'))"
    else
        fail "$what: $(last_import || echo 'no import')"; tail -3 "$WORK/drag.log"
    fi
}

case_start_screen() {
    local quit=120
    app_warm || quit=$((quit + FIRST_LAUNCH_TIMEOUT))
    : > "$WORK/app.log"
    launch_app --start-screen --no-audio --quit-after "$quit" -WizRec.OnboardingCompleted YES \
        -WizRec.ShowStartScreenAtLaunch YES -WizRec.RecentProjects "(\"$PROJECT\")" -WizRec.SidebarTab media \
        ${shots[@]+"${shots[@]}"}
    if ! wait_until "$(launch_timeout)" 'grep -q "^WizRec: start screen shown" "$WORK/app.log" || ! app_alive'; then
        fail "no start screen"; stop_app; return
    fi
    sleep 1
    snap
    # Empty states of a new project, then a drop onto its canvas.
    ax click start.newProject >/dev/null
    if ! wait_until 30 'grep -q "^WizRec: opened Untitled" "$WORK/app.log"'; then
        fail "New Project did not open an editor"; stop_app; return
    fi
    sleep 2
    local k
    for k in canvas.emptyState canvas.record canvas.importMedia bin.importMedia; do
        has_el "$k" && pass "empty project shows $k" || fail "empty project lacks $k"
    done
    # Timeline toolbar (ui-workflow.md §9): nothing to undo, cut or split yet; zoom works.
    expect_enabled timeline.undo false
    expect_enabled timeline.split false
    expect_enabled timeline.copy false
    expect_enabled timeline.addTrack true
    expect_enabled timeline.zoomToFit true
    snap
    local before
    before=$(imports)
    drop_on editor.canvas 0 0 2 "$WORK/clip.mp4"
    expect_import "$before" "drop on the empty canvas adds the video" "place=true clips=\[[0-9]*@track0\]"
    sleep 1
    has_el canvas.emptyState && fail "canvas first steps still shown with a clip" || pass "canvas first steps gone after the drop"
    has_el bin.importMedia && fail "bin empty state still shown with media" || pass "bin empty state gone after the drop"
    expect_enabled timeline.undo true
    expect_enabled timeline.copy true     # the dropped clip is selected
    ax keys w cmd >/dev/null
    sleep 1
    ax keys d cmd >/dev/null   # Don't Save (the untitled project)
    if ! wait_until 15 'has_window "Start Screen"'; then
        fail "no start screen after closing the project"; stop_app; return
    fi
    # A drop on the start screen opens a new project with the video.
    before=$(imports)
    drop_on start.newProject 380 60 1 "$WORK/clip.mp4"
    if wait_until 30 '[ "$(grep -c "^WizRec: opened Untitled" "$WORK/app.log")" -ge 2 ]'; then
        pass "drop on the start screen opens a new project"
        expect_import "$before" "start-screen drop places the video" "place=true clips=\[[0-9]*@track0\]"
    else
        fail "drop on the start screen opened nothing"; tail -3 "$WORK/drag.log"
    fi
    stop_app
}

case_editor() {
    : > "$WORK/app.log"
    open_project --no-audio -WizRec.SidebarTab media ${shots[@]+"${shots[@]}"} || return
    local before tile
    before=$(imports)
    drop_on editor.canvas 0 0 2 "$WORK/clip.mp4"
    expect_import "$before" "drop on the canvas adds at the playhead" "place=true clips=\[[0-9]*@track[0-9]*\]"
    before=$(imports)
    drop_on editor.timeline 200 10 1 "$WORK/clip.mp4"
    expect_import "$before" "drop on the timeline adds there" "place=true clips=\[[0-9]*@track[0-9]*\]"
    tile=$(ax dump demo 2>/dev/null | grep -o 'bin\.[0-9]*' | head -1)
    if [ -n "$tile" ]; then
        before=$(imports)
        drop_on "$tile" 0 0 1 "$WORK/clip.mp4"
        expect_import "$before" "drop on the media bin imports without placing" "place=false clips=\[\]"
    else
        fail "no media tile to drop on"
    fi
    drop_on editor.canvas 0 0 1 "$WORK/notes.txt"
    if wait_until 10 'grep -q "^WizRec: status “notes.txt” can’t be added" "$WORK/app.log"'; then
        pass "a text file is refused in plain words"
    else
        fail "no message for a dropped text file"; grep '^WizRec: status' "$WORK/app.log" | tail -2
    fi
    drop_on editor.canvas 0 0 1 "$WORK/Clips"
    if wait_until 10 'grep -q "^WizRec: status “Clips” is a folder" "$WORK/app.log"'; then
        pass "a folder is refused in plain words"
    else
        fail "no message for a dropped folder"; grep '^WizRec: status' "$WORK/app.log" | tail -2
    fi
    drop_on editor.canvas 0 0 1 "$WORK/second.cmproj"
    if wait_until 30 'grep -q "^WizRec: opened second.cmproj" "$WORK/app.log"'; then
        pass "a dropped project opens in its own window"
    else
        fail "the dropped project did not open"; tail -3 "$WORK/app.log"
    fi
    app_alive && pass "app responsive" || fail "app exited"
    stop_app
}

gui_lock
caffeinate -d -t 600 &
CAFF=$!
case_start_screen
case_editor
kill "$CAFF" 2>/dev/null
gui_unlock

[ "$FAILURES" -eq 0 ] && log "drops and empty states: all checks passed" \
    || log "drops and empty states: $FAILURES failure(s) (work dir $WORK, log $WORK/app.log)"
exit "$FAILURES"
