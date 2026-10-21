#!/bin/bash
# UI check: a --quit-after run with several edited projects quits without asking and writes
# nothing (APP11-2). Two copies of the demo project are opened in one app, a marker is added in
# each (key M in each window), then:
#
#   1. ⌘Q: AppKit's unsaved-documents review (`reviewUnsavedDocuments`) must not ask;
#   2. the --quit-after timer: the timed quit must not ask either.
#
# Each time the app must exit by itself with no save alert, log one discard line naming both
# projects, and leave both copies byte-for-byte unchanged (every file's checksum, size and
# modification time, and no file added or removed).
set -u
. "$(dirname "$0")/lib.sh"

# fingerprint <dir>: one line per file or folder (path, size, mtime, sha1 for files).
fingerprint() {
    (cd "$1" && find . -print0 | sort -z | while IFS= read -r -d '' f; do
        if [ -f "$f" ]; then
            printf '%s %s %s\n' "$f" "$(stat -f '%z %m' "$f")" "$(shasum "$f" | cut -d' ' -f1)"
        else
            printf '%s dir\n' "$f"
        fi
    done)
}

both_opened() { [ "$(grep -c '^WizRec: opened demo-[ab]\.cmproj' "$WORK/app.log" 2>/dev/null)" -ge 2 ]; }
asking() { has_el "Don't Save"; }

# add_markers: key M in each project window (the timeline has focus after opening): M in the
# key window, ⌘` (next window), M again. Raising a window through accessibility does not
# reliably make it key; ⌘` does.
add_markers() {
    [ "$(ax raise demo-a)" = ok ] || { fail "no window demo-a"; return 1; }
    ax keys m >/dev/null
    sleep 0.5
    ax keys '`' cmd >/dev/null
    sleep 0.8
    ax keys m >/dev/null
    sleep 0.5
}

# expect_quiet_exit <seconds> <what>: the app exits within <seconds> without a save alert.
expect_quiet_exit() {
    if wait_until "$1" '! app_alive'; then
        pass "$2: app exited without asking"
    else
        asking && fail "$2: a save alert is up" || fail "$2: app still running after $1 s"
        kill -9 "$APP_PID" 2>/dev/null || true
    fi
}

# expect_notice <what>: exactly one discard line, naming both projects.
expect_notice() {
    local lines
    lines=$(grep -c 'discarded unsaved edits in' "$WORK/app.log" 2>/dev/null)
    if [ "$lines" = 1 ] && grep 'discarded unsaved edits in' "$WORK/app.log" | grep -q 'demo-a' \
        && grep 'discarded unsaved edits in' "$WORK/app.log" | grep -q 'demo-b'; then
        pass "$1: one discard line names both projects"
    else
        fail "$1: discard notice wrong ($lines line(s)):"
        grep 'discarded unsaved edits' "$WORK/app.log"
    fi
}

expect_unchanged() {
    local p
    for p in a b; do
        if [ "$(fingerprint "$WORK/demo-$p.cmproj")" = "$(cat "$WORK/before-$p.txt")" ]; then
            pass "$1: demo-$p.cmproj unchanged"
        else
            fail "$1: demo-$p.cmproj changed:"
            diff <(cat "$WORK/before-$p.txt") <(fingerprint "$WORK/demo-$p.cmproj") | head -20
        fi
    done
}

# run_case <name> <quit-after s> <how>: how = "cmd-q" or "timer".
run_case() {
    local name=$1 quit=$2 how=$3
    app_warm || quit=$((quit + FIRST_LAUNCH_TIMEOUT))
    : > "$WORK/app.log"
    launch_app "$WORK/demo-a.cmproj" "$WORK/demo-b.cmproj" --no-audio --quit-after "$quit"
    if ! wait_until "$(launch_timeout)" 'both_opened || ! app_alive' || ! both_opened; then
        fail "$name: both project windows did not open"; tail -5 "$WORK/app.log"; stop_app; return
    fi
    mark_warm
    sleep 2
    add_markers || { stop_app; return; }
    if [ "$how" = cmd-q ]; then
        ax keys q cmd >/dev/null
        expect_quiet_exit 20 "$name"
    else
        expect_quiet_exit $((quit + 20)) "$name"
    fi
    stop_app
    expect_notice "$name"
    expect_unchanged "$name"
}

make_work
mv "$PROJECT" "$WORK/demo-a.cmproj"
cp -R "$WORK/demo-a.cmproj" "$WORK/demo-b.cmproj"
fingerprint "$WORK/demo-a.cmproj" > "$WORK/before-a.txt"
fingerprint "$WORK/demo-b.cmproj" > "$WORK/before-b.txt"

gui_lock
run_case "⌘Q with two edited projects" 150 cmd-q
run_case "timed quit with two edited projects" 25 timer
gui_unlock

[ "$FAILURES" -eq 0 ] && log "quit with unsaved projects: all checks passed" \
    || log "quit with unsaved projects: $FAILURES failure(s) (work dir $WORK, log $WORK/app.log)"
exit "$FAILURES"
