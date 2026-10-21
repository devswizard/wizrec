#!/usr/bin/env bash
# Checks that the release notes are ready for a version before it is tagged.
#
#   scripts/release/check-notes.sh 0.1.3 [notes-file]
#
# notes-file defaults to docs/release-notes-template.md (the body release.yml gives the draft
# GitHub Release). Fails when:
#   - a TODO(release) placeholder is left;
#   - the download line does not name WizRec-<version>.dmg, or another version's DMG is named;
#   - the source links (blob/v<version>/LICENSE, tree/v<version>) are missing, or a
#     blob/ or tree/ link points at another tag.
# Links to earlier releases (releases/tag/v…) are allowed. release.yml runs this on a tag
# before building, so a stale template stops the run in seconds, not after the build.
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION=${1:?usage: check-notes.sh <version> [notes-file]}
VERSION=${VERSION#v}
NOTES=${2:-docs/release-notes-template.md}
[ -f "$NOTES" ] || { echo "check-notes: $NOTES not found" >&2; exit 1; }

fail=0
err() { echo "check-notes: $NOTES: $*" >&2; fail=1; }

# The HTML comment at the top is not shown on GitHub; check only the visible text (comment
# lines become empty, so line numbers stay those of the file).
body=$(awk '
    !done && /<!--/ { skip = 1 }
    { print (skip ? "" : $0) }
    skip && /-->/ { skip = 0; done = 1 }
' "$NOTES")

if grep -n 'TODO(release)' <<<"$body" >&2; then
    err "TODO(release) placeholder left (lines above)"
fi

v_re=${VERSION//./\\.}
grep -q "WizRec-${v_re}\.dmg" <<<"$body" || err "no WizRec-${VERSION}.dmg in the download line"
others=$(grep -oE 'WizRec-[0-9][0-9A-Za-z.-]*\.dmg' <<<"$body" | sort -u | grep -v "^WizRec-${v_re}\.dmg$" || true)
[ -z "$others" ] || err "names another version's DMG: $(tr '\n' ' ' <<<"$others")"

grep -q "/blob/v${v_re}/LICENSE" <<<"$body" || err "no licence link to blob/v${VERSION}/LICENSE"
grep -q "/tree/v${v_re})" <<<"$body" || err "no source link to tree/v${VERSION}"
stale=$(grep -oE '/(blob|tree)/v[0-9][0-9A-Za-z.-]*[0-9A-Za-z]' <<<"$body" | sort -u \
    | grep -vE "^/(blob|tree)/v${v_re}$" || true)
[ -z "$stale" ] || err "source links to another tag: $(tr '\n' ' ' <<<"$stale")"

if [ "$fail" -ne 0 ]; then
    exit 1
fi
echo "check-notes: $NOTES ready for v$VERSION"
