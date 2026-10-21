#!/bin/bash
# UI check: the start screen and the editor toolbar (APP13).
#
# Every launch passes --start-screen (a timed run shows no start screen otherwise) and replaces
# the recent list with `-WizRec.RecentProjects` (the demo copy plus a missing project), so the
# user's own recent projects are neither shown nor changed.
#
#   0. a timed launch without --start-screen shows no window at all (scripted-run policy);
#   1. keyboard: the start screen lists both projects (the missing one dimmed), ↓ + Delete
#      removes the missing one, ↑ + Return opens the demo copy, the start screen steps aside;
#      the toolbar has Import, Record, Undo, Redo and Export with the menus' enabled states,
#      its Export button opens the export sheet; ⌘W on the last project brings the start
#      screen back;
#   2. a real mouse double-click on the recent row opens the project;
#   3. New Project opens an untitled editor whose Export is disabled (nothing to export), and
#      closing it brings the start screen back.
set -u
. "$(dirname "$0")/lib.sh"

shown_count() { grep -c '^WizRec: start screen shown' "$WORK/app.log" 2>/dev/null; }
start_up() { [ "$(shown_count)" -ge "${1:-1}" ] && has_window "Start Screen"; }

# launch_start [quit-after s]: the app with the start screen and the test recent list.
launch_start() {
    local quit=${1:-90}
    app_warm || quit=$((quit + FIRST_LAUNCH_TIMEOUT))
    : > "$WORK/app.log"
    launch_app --start-screen --no-audio --quit-after "$quit" -ApplePersistenceIgnoreState YES \
        -WizRec.OnboardingCompleted YES -WizRec.ShowStartScreenAtLaunch YES \
        -WizRec.RecentProjects "(\"$PROJECT\", \"$WORK/Missing Project.cmproj\")" ${shots[@]+"${shots[@]}"}
}

wait_start() {
    if wait_until "$(launch_timeout)" 'start_up || ! app_alive' && start_up; then
        pass "$1: start screen shown"
        sleep 1
        return 0
    fi
    fail "$1: no start screen"; tail -5 "$WORK/app.log"; return 1
}

# expect_toolbar <window> <expected lines…>: `ax toolbar` lists exactly these items.
expect_toolbar() {
    local win=$1 got want
    shift
    got=$(ax toolbar "$win" | sed '/^$/d')
    want=$(printf '%s\n' "$@")
    if [ "$got" = "$want" ]; then
        pass "toolbar of $win: $(echo "$got" | tr '\n' ',' | sed 's/,$//')"
    else
        fail "toolbar of $win:"; echo "got:"; echo "$got"; echo "want:"; echo "$want"
    fi
}

case_scripted() {
    : > "$WORK/app.log"
    launch_app --no-audio --quit-after 12 -ApplePersistenceIgnoreState YES -WizRec.OnboardingCompleted YES \
        -WizRec.ShowStartScreenAtLaunch YES
    sleep 7
    local w
    w=$(ax windows | sed '/^$/d')
    if app_alive && [ -z "$w" ] && [ "$(shown_count)" = 0 ]; then
        pass "timed launch: no start screen and no open panel"
    else
        fail "timed launch showed: ${w:-start screen}"
    fi
    stop_app
}

case_keyboard() {
    launch_start
    wait_start "keyboard" || { stop_app; return; }
    local k
    for k in start.newProject start.newRecording start.openProject start.importMedia start.showAtLaunch \
        start.recent.demo "start.recent.Missing Project"; do
        has_el "$k" || fail "start screen lacks $k"
    done
    pass "start screen has its actions and both recent projects"
    ax keys down >/dev/null
    sleep 0.5
    ax keys delete >/dev/null
    if wait_until 5 '! has_el "start.recent.Missing Project"'; then
        pass "Delete removes the missing project from the list"
    else
        fail "missing project still listed after Delete"
    fi
    ax keys up >/dev/null
    sleep 0.5
    ax keys return >/dev/null
    wait_for_project || { fail "Return did not open the recent project"; stop_app; return; }
    pass "Return opens the selected recent project"
    wait_until 5 '! has_window "Start Screen"' && pass "start screen closes when a project opens" \
        || fail "start screen still up with a project open"
    expect_toolbar demo "Import | true" "Record | true" "Undo | false" "Redo | false" "Export | true"
    ax toolbar-press demo Export >/dev/null
    if wait_until 10 'has_el export.start'; then
        pass "toolbar Export opens the export sheet"
        ax click export.close >/dev/null
        wait_until 10 '! has_el export.close' || fail "export sheet did not close"
    else
        fail "toolbar Export did not open the export sheet"
    fi
    sleep 1
    ax keys w cmd >/dev/null
    if wait_until 10 'start_up 2'; then
        pass "closing the last project brings the start screen back"
    else
        fail "no start screen after closing the last project"; ax windows
    fi
    stop_app
}

case_double_click() {
    launch_start
    wait_start "double-click" || { stop_app; return; }
    local f x y w h
    f=$(ax frame start.recent.demo) || { fail "no frame for the recent row"; stop_app; return; }
    read -r x y w h <<< "$f"
    "$MOUSE" click $((x + w / 2)) $((y + h / 2)) 2 >> "$WORK/app.log"
    if wait_for_project; then pass "double-click opens the recent project"; else fail "double-click did not open it"; fi
    stop_app
}

untitled_up() { grep -q '^WizRec: opened Untitled.cmproj' "$WORK/app.log" && has_window "Untitled Project"; }

case_new_project() {
    launch_start
    wait_start "new project" || { stop_app; return; }
    ax click start.newProject >/dev/null
    if wait_until 20 'untitled_up'; then
        pass "New Project opens an untitled editor"
    else
        fail "New Project did not open an editor"; tail -5 "$WORK/app.log"; stop_app; return
    fi
    sleep 1
    expect_toolbar "Untitled" "Import | true" "Record | true" "Undo | false" "Redo | false" "Export | false"
    ax keys w cmd >/dev/null
    if wait_until 10 'start_up 2'; then
        pass "closing the untitled project brings the start screen back"
    else
        fail "no start screen after closing the untitled project"; ax windows
    fi
    stop_app
}

# SHOTS_DIR=<dir>: also write window snapshots there (3 s after each launch).
shots=()
[ -n "${SHOTS_DIR:-}" ] && shots=(-WizRec.WindowSnapshots "$SHOTS_DIR" -WizRec.WindowSnapshotDelay 3)

make_work
MOUSE="$WORK/mouse"
swiftc -O "$UI_DIR/mouse.swift" -o "$MOUSE" > "$WORK/mouse-build.log" 2>&1 || { fail "mouse helper did not build"; exit 1; }

gui_lock
case_scripted
case_keyboard
case_double_click
case_new_project
gui_unlock

[ "$FAILURES" -eq 0 ] && log "start screen and toolbar: all checks passed" \
    || log "start screen and toolbar: $FAILURES failure(s) (work dir $WORK, log $WORK/app.log)"
exit "$FAILURES"
