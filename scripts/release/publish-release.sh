#!/bin/bash
# Publishes the draft GitHub Release of a tag after checking what it ships:
#
#   1. finds the release by tag (drafts have no tag URL, so it searches the list), waiting up
#      to WAIT_MINUTES for the Release workflow to create it with its assets;
#   2. already public → prints so and exits 0 (idempotent);
#   3. the tag must exist in the repository (publishing a draft whose tag is missing would
#      create the tag on the default branch's head);
#   4. the title and notes must carry no AI attribution lines;
#   5. downloads every asset, `shasum -a 256 -c SHA256SUMS.txt` (every DMG must be listed),
#      then scripts/release/verify-dmg.sh on each DMG (mount, signature, load paths, launch);
#   6. flips draft → false (and marks it latest), then reads it back.
#
#   GH_TOKEN=… GITHUB_REPOSITORY=devswizard/wizrec scripts/release/publish-release.sh v0.1.0
#
# Environment:
#   GH_TOKEN            token with contents: write (in Actions: the workflow's GITHUB_TOKEN).
#                       Used only in request headers; never printed
#   GITHUB_REPOSITORY   owner/repo (default devswizard/wizrec)
#   GITHUB_API_URL      API root (default https://api.github.com; Actions sets it)
#   WAIT_MINUTES        how long to wait for the draft and its assets (default 0)
#   DRY_RUN=1           do every check, but do not publish
#   WORK_DIR            where assets are downloaded (default: a new temp dir)
# Uses curl and python3 only (no gh), so it runs the same on a runner and on a Mac.
set -euo pipefail

TAG=${1:?usage: publish-release.sh <tag>}
REPO=${GITHUB_REPOSITORY:-devswizard/wizrec}
WAIT_MINUTES=${WAIT_MINUTES:-0}
API="${GITHUB_API_URL:-https://api.github.com}/repos/$REPO"
HERE=$(cd "$(dirname "$0")" && pwd)

case "$TAG" in v[0-9]*) ;; *) echo "error: tag must look like v1.2.3 (got '$TAG')" >&2; exit 2;; esac
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "error: invalid tag '$TAG'" >&2; exit 2; }
[[ "$WAIT_MINUTES" =~ ^[0-9]+$ ]] || { echo "error: WAIT_MINUTES must be a whole number" >&2; exit 2; }
[ -n "${GH_TOKEN:-}" ] || { echo "error: GH_TOKEN is not set (drafts are visible only with push access)" >&2; exit 2; }

# curl config on stdin keeps the token off the command line (ps) and out of the log.
api() {
  printf 'header = "Authorization: Bearer %s"\n' "$GH_TOKEN" \
    | curl -fsSL --retry 3 --retry-delay 5 -K - \
        -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}

WORK=${WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/wizrec-publish.XXXXXX")}
mkdir -p "$WORK"
REL="$WORK/release.json"

# Writes the release with tag $TAG (draft or not) to $REL; returns 1 when there is none.
find_release() {
  local page list
  for page in 1 2 3; do
    list=$(api "$API/releases?per_page=100&page=$page")
    if printf '%s' "$list" | python3 -I -c 'import json,sys
t=sys.argv[1]; r=[x for x in json.load(sys.stdin) if x.get("tag_name")==t]
if not r: sys.exit(1)
json.dump(r[0], open(sys.argv[2], "w"))' "$TAG" "$REL"; then
      return 0
    fi
    [ "$(printf '%s' "$list" | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)))')" -lt 100 ] && break
  done
  return 1
}

field() { python3 -I -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("" if v is None else str(v).lower() if isinstance(v,bool) else v)' "$REL" "$1"; }
has_assets() { python3 -I -c 'import json,sys
n={a["name"] for a in json.load(open(sys.argv[1]))["assets"] if a.get("state","uploaded")=="uploaded"}
sys.exit(0 if "SHA256SUMS.txt" in n and any(x.endswith(".dmg") for x in n) else 1)' "$REL"; }

deadline=$(( $(date +%s) + WAIT_MINUTES * 60 ))
while :; do
  if find_release && { [ "$(field draft)" = false ] || has_assets; }; then break; fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "error: no release for $TAG with a DMG and SHA256SUMS.txt in $REPO (the Release workflow creates the draft when the tag is pushed)" >&2
    exit 1
  fi
  echo "Waiting for the $TAG release and its assets…"
  sleep 60
done

id=$(field id)
if [ "$(field draft)" = false ]; then
  echo "Already public: $TAG ($(field html_url)). Nothing to do."
  exit 0
fi
echo "Draft release $id for $TAG found."

# 3. The tag must exist (a draft can name a tag that was never pushed).
api -o /dev/null "$API/git/ref/tags/$TAG" || { echo "error: tag $TAG does not exist in $REPO" >&2; exit 1; }

# 4. No AI attribution in the title or notes (user rule, DECISIONS 2026-10-20).
python3 -I -c 'import json,re,sys
r=json.load(open(sys.argv[1]))
text=(r.get("name") or "")+"\n"+(r.get("body") or "")
pat=re.compile(r"co-authored-by:|generated (with|by) .*(claude|ai\b|copilot|chatgpt)|\bclaude\b|anthropic|chatgpt|openai|copilot|\U0001F916", re.I)
bad=[l for l in text.splitlines() if pat.search(l)]
for l in bad: print("error: AI attribution in the release notes: "+l.strip(), file=sys.stderr)
sys.exit(1 if bad else 0)' "$REL"

# 5. Download every asset and check it.
ASSETS="$WORK/assets"
rm -rf "$ASSETS"; mkdir -p "$ASSETS"
python3 -I -c 'import json,sys
for a in json.load(open(sys.argv[1]))["assets"]: print(a["id"], a["name"])' "$REL" \
  | while read -r aid name; do
      case "$name" in */*|.*|"") echo "error: unexpected asset name '$name'" >&2; exit 1;; esac
      api -H "Accept: application/octet-stream" -o "$ASSETS/$name" "$API/releases/assets/$aid"
      echo "downloaded $name ($(du -h "$ASSETS/$name" | cut -f1))"
    done

(
  cd "$ASSETS"
  [ -s SHA256SUMS.txt ] || { echo "error: SHA256SUMS.txt is missing or empty" >&2; exit 1; }
  for d in *.dmg; do
    awk -v n="$d" '$2==n{f=1} END{exit !f}' SHA256SUMS.txt \
      || { echo "error: $d is not listed in SHA256SUMS.txt" >&2; exit 1; }
  done
  shasum -a 256 -c SHA256SUMS.txt
)
for d in "$ASSETS"/*.dmg; do
  "$HERE/verify-dmg.sh" "$d"
done

if [ "${DRY_RUN:-0}" = 1 ]; then
  echo "DRY_RUN: all checks passed; $TAG stays a draft."
  exit 0
fi

# 6. Publish and read back.
# (stdin carries the curl config, so the body goes on the command line; it holds no secret.)
api -X PATCH --data '{"draft":false,"make_latest":"true"}' -o "$REL" "$API/releases/$id"
[ "$(field draft)" = false ] || { echo "error: GitHub still reports $TAG as a draft" >&2; exit 1; }
echo "Published $TAG: $(field html_url)"
