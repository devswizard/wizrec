# Shared helpers for the scripted UI checks (sourced, not run).
#
# - GUI lock: one agent or person drives the GUI at a time. `gui_lock` waits for
#   $GUI_LOCK (mkdir is atomic), writes the owner, and `gui_unlock` (also on exit) removes it.
# - The app is started from build/WizRec.app by executable path, on a COPY of the demo project
#   in a temp dir. A watchdog kills that one process (by pid) if a check hangs; other WizRec
#   copies (e.g. one running from a mounted DMG) are never touched.
# - Defaults the checks depend on are passed as `-Key value` argument-domain pairs, so the
#   user's stored preferences are neither read nor changed.

UI_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$UI_DIR/../.." && pwd)
APP=${WIZREC_APP:-$ROOT/build/WizRec.app}
BIN="$APP/Contents/MacOS/WizRec"
DEMO=${DEMO_PROJECT:-$HOME/Documents/demo project.cmproj}
GUI_LOCK=${GUI_LOCK:-$HOME/WorkDir/vibe_coding/camtasia_rea_refs/.gui.lock}
GUI_OWNER=${GUI_OWNER:-app}
WATCHDOG=${WATCHDOG:-180}

APP_PID=""
WATCH_PID=""
HAVE_LOCK=""
FAILURES=0

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
pass() { log "PASS $*"; }
fail() { log "FAIL $*"; FAILURES=$((FAILURES + 1)); }

gui_lock() {
    while ! mkdir "$GUI_LOCK" 2>/dev/null; do
        log "GUI lock held by $(cat "$GUI_LOCK/owner" 2>/dev/null || echo '?'); retrying in 30 s"
        sleep 30
    done
    echo "$GUI_OWNER" > "$GUI_LOCK/owner"
    HAVE_LOCK=1
}

gui_unlock() {
    if [ -n "$HAVE_LOCK" ]; then rm -r "$GUI_LOCK" 2>/dev/null || true; HAVE_LOCK=""; fi
}

# Copies the demo project into a fresh temp dir; sets WORK and PROJECT.
make_work() {
    [ -d "$DEMO" ] || { log "SKIP: no demo project at $DEMO"; exit 0; }
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/wizrec-ui.XXXXXX")
    cp -R "$DEMO" "$WORK/demo.cmproj"
    PROJECT="$WORK/demo.cmproj"
    mkdir -p "$WORK/exports"
}

# launch_app [args…]: starts the app and a watchdog; sets APP_PID.
launch_app() {
    [ -x "$BIN" ] || { log "no app at $APP (run scripts/make-app.sh)"; exit 2; }
    "$BIN" "$@" > "$WORK/app.log" 2>&1 &
    APP_PID=$!
    ( sleep "$WATCHDOG"; kill -9 "$APP_PID" 2>/dev/null && echo "watchdog killed $APP_PID" >> "$WORK/app.log" ) &
    WATCH_PID=$!
    log "launched WizRec pid $APP_PID"
}

app_alive() { [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; }

# Quits the app if it still runs (Quit, then kill after 15 s), and stops the watchdog.
stop_app() {
    if app_alive; then
        ax keys q cmd >/dev/null 2>&1 || true
        wait_until 15 '! app_alive' || kill -9 "$APP_PID" 2>/dev/null || true
    fi
    [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null || true
    APP_PID=""; WATCH_PID=""
}

cleanup() {
    stop_app
    gui_unlock
}
trap cleanup EXIT INT TERM

ax() { osascript "$UI_DIR/ax.applescript" "$1" "$APP_PID" "${@:2}"; }

# wait_until <seconds> <shell condition>: polls every 0.5 s.
wait_until() {
    local deadline=$(( $(date +%s) + $1 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if eval "$2"; then return 0; fi
        sleep 0.5
    done
    eval "$2"
}

# has_el <key>: an element whose title, description or accessibility identifier is <key> exists.
has_el() { [ "$(ax has "$1" 2>/dev/null)" = yes ]; }
# dump_value <dump> <key>: AXValue of the first element in an `ax dump` whose title,
# description or identifier is <key> (exit status 1 when none matches).
dump_value() {
    awk -F' \\| ' -v k="$2" '($2==k || $4==k || $5==k) {print $3; f=1; exit} END {exit !f}' <<< "$1"
}
has_window() { ax windows 2>/dev/null | grep -q "$1"; }

# Opens the project copy and waits for its window.
# Always passes --quit-after (QUIT_AFTER s, default 150), so an abandoned app quits by itself
# before the watchdog kills it.
open_project() {
    launch_app "$PROJECT" --quit-after "${QUIT_AFTER:-150}" "$@"
    wait_until 30 'has_window demo' || { fail "project window did not open"; return 1; }
    sleep 2
}
