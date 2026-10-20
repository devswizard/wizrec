# Shared helpers for the scripted UI checks (sourced, not run).
#
# - GUI lock: one agent or person drives the GUI at a time. `gui_lock` waits for
#   $GUI_LOCK (mkdir is atomic), writes the owner, and `gui_unlock` (also on exit) removes it.
# - The app is started from build/WizRec.app by executable path, on a COPY of the demo project
#   in a temp dir. A watchdog kills that one process (by pid) if a check hangs; other WizRec
#   copies (e.g. one running from a mounted DMG) are never touched.
# - Defaults the checks depend on are passed as `-Key value` argument-domain pairs, so the
#   user's stored preferences are neither read nor changed.
# - The first launch of a freshly built app is slow (the system assesses the new binary, caches
#   are cold). Window waits poll up to FIRST_LAUNCH_TIMEOUT s until a launch of this exact
#   binary has shown its project once (a stamp next to the app), then up to LAUNCH_TIMEOUT s.

UI_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$UI_DIR/../.." && pwd)
APP=${WIZREC_APP:-$ROOT/build/WizRec.app}
BIN="$APP/Contents/MacOS/WizRec"
DEMO=${DEMO_PROJECT:-$HOME/Documents/demo project.cmproj}
GUI_LOCK=${GUI_LOCK:-$HOME/WorkDir/vibe_coding/camtasia_rea_refs/.gui.lock}
GUI_OWNER=${GUI_OWNER:-app}
WATCHDOG=${WATCHDOG:-180}
LAUNCH_TIMEOUT=${LAUNCH_TIMEOUT:-45}
FIRST_LAUNCH_TIMEOUT=${FIRST_LAUNCH_TIMEOUT:-150}
WARM_STAMP="$(dirname "$APP")/.$(basename "$APP").ui-warm"

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

# Identity of the built binary (mtime, inode, size): a rebuild changes it.
bin_id() { stat -f '%m %i %z' "$BIN" 2>/dev/null; }
# A launch of this binary has already shown its project.
app_warm() { [ -f "$WARM_STAMP" ] && [ "$(cat "$WARM_STAMP" 2>/dev/null)" = "$(bin_id)" ]; }
mark_warm() { bin_id > "$WARM_STAMP" 2>/dev/null || true; }
# Seconds to allow a launch to show its project: longer for the first launch of a new build.
launch_timeout() { if app_warm; then echo "$LAUNCH_TIMEOUT"; else echo "$FIRST_LAUNCH_TIMEOUT"; fi; }

# launch_app [args…]: starts the app and a watchdog; sets APP_PID. The watchdog adds the
# first-launch allowance for a new build.
launch_app() {
    [ -x "$BIN" ] || { log "no app at $APP (run scripts/make-app.sh)"; exit 2; }
    local limit=$WATCHDOG
    app_warm || limit=$((WATCHDOG + FIRST_LAUNCH_TIMEOUT))
    "$BIN" "$@" > "$WORK/app.log" 2>&1 &
    APP_PID=$!
    ( sleep "$limit"; kill -9 "$APP_PID" 2>/dev/null && echo "watchdog killed $APP_PID" >> "$WORK/app.log" ) &
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

# The work dir goes when every check passed; after a failure only its exports (often GBs of
# ProRes) go, and the project copy and app.log stay for inspection.
cleanup() {
    stop_app
    gui_unlock
    if [ -n "${WORK:-}" ] && [ -d "$WORK" ]; then
        if [ "$FAILURES" -eq 0 ]; then rm -rf "$WORK"; else rm -rf "$WORK/exports"; fi
    fi
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

# project_opened: the app logged its project window ("WizRec: opened …", printed once the
# window has loaded) and System Events lists that window.
project_opened() { grep -q "^WizRec: opened " "$WORK/app.log" 2>/dev/null && has_window demo; }

# wait_for_project [seconds]: polls until the project window is up (default: launch_timeout);
# gives up early when the app exits. Marks this build warm on success.
wait_for_project() {
    local t=${1:-$(launch_timeout)} started
    started=$(date +%s)
    wait_until "$t" 'project_opened || ! app_alive'
    if app_alive && project_opened; then
        log "project window up after $(( $(date +%s) - started )) s"
        mark_warm
        return 0
    fi
    if app_alive; then log "no project window after $t s"; else log "app exited before its window opened"; fi
    tail -5 "$WORK/app.log" 2>/dev/null
    return 1
}

# Opens the project copy and waits for its window.
# Passes --quit-after (QUIT_AFTER s, default 150, plus the first-launch allowance for a new
# build), so an abandoned app quits by itself before the watchdog kills it. QUIT_AFTER=0 leaves
# it out, for checks of behaviour a scripted run turns off (the export close/quit
# confirmation); the watchdog still ends those.
open_project() {
    local q=() quit=${QUIT_AFTER:-150}
    if [ "$quit" != 0 ] && ! app_warm; then quit=$((quit + FIRST_LAUNCH_TIMEOUT)); fi
    [ "$quit" != 0 ] && q=(--quit-after "$quit")
    launch_app "$PROJECT" ${q[@]+"${q[@]}"} "$@"
    wait_for_project || { fail "project window did not open"; return 1; }
    sleep 2
}
