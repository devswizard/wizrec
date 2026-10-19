#!/bin/sh
# Builds WizRec.app and opens the user's demo project in it (read-only).
#
#   scripts/run-demo.sh                    # open and wait
#   scripts/run-demo.sh --autoplay --overlay --stats-log
#   PROJECT=~/Documents/other.cmproj scripts/run-demo.sh
set -eu
cd "$(dirname "$0")/.."
PROJECT=${PROJECT:-"$HOME/Documents/demo project.cmproj"}
if [ ! -e "$PROJECT" ]; then
    echo "no project at $PROJECT" >&2
    exit 1
fi
scripts/make-app.sh
exec build/WizRec.app/Contents/MacOS/WizRec "$PROJECT" "$@"
