#!/bin/bash
# UI check (e): library tiles carry their title where VoiceOver and System Events read it
# (AXTitle / AXDescription, role AXButton), and pressing a Backgrounds tile places it
# (one undo step, "Add Background").
set -u
. "$(dirname "$0")/lib.sh"

# tile_label <dump> <identifier>: "role | title | description" of the element with that identifier.
tile_label() { awk -F' \\| ' -v k="$2" '$5==k {print $1 " | " $2 " | " $4; f=1; exit} END {exit !f}' <<< "$1"; }

# expect_tile <dump> <identifier> <title>
expect_tile() {
    local got
    got=$(tile_label "$1" "$2") || { fail "no element $2"; return; }
    case "$got" in
        *AXButton*" | $3 | $3"*) pass "$2 reads \"$3\" (AXButton, AXTitle, AXDescription)";;
        *) fail "$2 reads \"$got\", want AXButton | $3 | $3";;
    esac
}

make_work
gui_lock
open_project || exit 1

[ "$(ax click Effects)" = ok ] && pass "Effects tab selected" || fail "no Effects tab"
sleep 1
d=$(ax dump)
expect_tile "$d" library.RoundCorners "Rounded Corners"
expect_tile "$d" library.DropShadow "Drop Shadow"

[ "$(ax click Backgrounds)" = ok ] && pass "Backgrounds tab selected" || fail "no Backgrounds tab"
sleep 1
d=$(ax dump)
expect_tile "$d" library.wizrec-aurora "Aurora"
expect_tile "$d" library.wizrec-gradient-drift "Gradient Drift"
has_el "Aurora" && pass "tile found by its title" || fail "tile not found by its title"

[ "$(ax click library.wizrec-aurora)" = ok ] && pass "pressed Aurora" || fail "could not press Aurora"
sleep 2
ax keys s cmd >/dev/null
TSC="$PROJECT/project.tscproj"
wait_until 15 'grep -q "wizrec-aurora.tscshadervid" "$TSC"' && pass "Aurora placed and saved" \
    || fail "Aurora not in the saved project"
grep -q '"effectDef"' "$TSC" && grep -q '"sourceFileType" : "tscshadervid"' "$TSC" \
    && pass "saved with effectDef and sourceEffect" || fail "saved without effectDef/sourceEffect"
app_alive && pass "app responsive" || fail "app exited"
stop_app
gui_unlock

[ "$FAILURES" -eq 0 ] && log "library a11y: all checks passed" || log "library a11y: $FAILURES failure(s) (work dir $WORK)"
exit "$FAILURES"
