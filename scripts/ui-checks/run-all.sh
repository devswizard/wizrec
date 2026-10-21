#!/bin/bash
# Scripted click-through of the app (opt-in; never part of `swift test`).
#
#   scripts/make-app.sh && scripts/ui-checks/run-all.sh
#
# Needs: Accessibility permission for the terminal (System Events UI scripting), ffmpeg,
# ~/Documents/demo project.cmproj (copied to a temp dir; the original is never opened).
# Each check takes the GUI lock only while it drives the app. Exit status: number of failed checks.
set -u
cd "$(dirname "$0")"
failed=0
for c in check-export-close.sh check-settings-captions.sh check-group-drop.sh check-audio-panel.sh check-library-a11y.sh check-library-double-click.sh check-library-ax-audit.sh check-quit-unsaved.sh check-start-screen.sh; do
    echo "=== $c"
    ./"$c" || failed=$((failed + 1))
done
echo "=== $failed check script(s) failed"
exit "$failed"
