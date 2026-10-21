#!/bin/bash
# Sparkle readiness check: builds build/WizRec.app with scripts/make-app.sh in several
# configurations and checks the Sparkle entries of each Info.plist (sparkle-plist-check.sh).
#
#   1. WIZREC_SPARKLE_PUBKEY alone: make-app.sh fails (never a half-configured updater);
#   2. WIZREC_SPARKLE_FEED + WIZREC_SPARKLE_PUBKEY set to a throwaway test key (32 random
#      bytes, never a real key): SUFeedURL and SUPublicEDKey with exactly those values (on);
#   3. a config with feed_url and an empty public_ed_key: no SUFeedURL, no SUPublicEDKey (off);
#   4. committed release/sparkle.conf: updater off while public_ed_key is empty, on with that
#      key and feed_url once the maintainer fills it in. Last, so build/WizRec.app ends up as
#      an ordinary build of the committed config.
#
#   scripts/release/check-sparkle.sh          # CONFIG=release by default, like make-app.sh
#   CONFIG=debug scripts/release/check-sparkle.sh
#
# Overwrites build/WizRec.app (left as a build of the committed config). Needs no keychain,
# never runs generate_keys or sign_update, and reads no private key.
set -euo pipefail
cd "$(dirname "$0")/../.."
export CONFIG=${CONFIG:-release}

APP=build/WizRec.app
CHECK=scripts/release/sparkle-plist-check.sh
CONF=release/sparkle.conf
tmp=$(mktemp -d "${TMPDIR:-/tmp}/wizrec-sparkle-check.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# Value of `key = value` in a config file (same reading as sparkle-info.sh).
conf() {
  awk -v k="$1" -F= '
    /^[[:space:]]*#/ { next }
    { key=$1; gsub(/[[:space:]]/, "", key) }
    key == k { v=substr($0, index($0, "=") + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print v; exit }
  ' "$2"
}
FEED=$(conf feed_url "$CONF")
[ -n "$FEED" ] || { echo "error: $CONF has no feed_url" >&2; exit 1; }
COMMITTED_KEY=$(conf public_ed_key "$CONF")
TEST_KEY=$(head -c 32 /dev/urandom | base64)

# make-app.sh with only the Sparkle variables given here (never inherited from the caller).
build() {
  env -u WIZREC_SPARKLE_FEED -u WIZREC_SPARKLE_PUBKEY -u WIZREC_SPARKLE_CONF "$@" \
    scripts/make-app.sh >"$tmp/build.log" 2>&1
}
fail() { echo "FAIL: $*" >&2; tail -n 20 "$tmp/build.log" >&2 || true; exit 1; }

echo "== 1. WIZREC_SPARKLE_PUBKEY alone"
if build WIZREC_SPARKLE_PUBKEY="$TEST_KEY"; then
  fail "make-app.sh accepted WIZREC_SPARKLE_PUBKEY without WIZREC_SPARKLE_FEED"
fi
grep -q "set both WIZREC_SPARKLE_FEED and WIZREC_SPARKLE_PUBKEY" "$tmp/build.log" \
  || fail "half configuration failed without the pair error"
echo "ok: refused (set both or neither)"

echo "== 2. WIZREC_SPARKLE_FEED + WIZREC_SPARKLE_PUBKEY (throwaway test key)"
build WIZREC_SPARKLE_FEED="$FEED" WIZREC_SPARKLE_PUBKEY="$TEST_KEY" || fail "make-app.sh with the test key"
"$CHECK" "$APP" --expect on --feed "$FEED" --key "$TEST_KEY" || fail "test key must turn the updater on"
echo "ok: SUFeedURL $FEED and SUPublicEDKey (test key)"

echo "== 3. feed_url with empty public_ed_key"
printf 'feed_url = %s\npublic_ed_key =\n' "$FEED" > "$tmp/off.conf"
build WIZREC_SPARKLE_CONF="$tmp/off.conf" || fail "make-app.sh with an empty public_ed_key"
"$CHECK" "$APP" --expect off || fail "empty public_ed_key must leave the updater off"
echo "ok: no SUFeedURL, no SUPublicEDKey"

echo "== 4. committed $CONF"
build || fail "make-app.sh with the committed config"
if [ -z "$COMMITTED_KEY" ]; then
  "$CHECK" "$APP" --expect off || fail "committed config (empty public_ed_key) must leave the updater off"
  echo "ok: public_ed_key empty -> updater off"
else
  "$CHECK" "$APP" --expect on --feed "$FEED" --key "$COMMITTED_KEY" \
    || fail "committed config (public_ed_key set) must turn the updater on with that key"
  echo "ok: public_ed_key set -> updater on ($FEED)"
fi

echo "OK: Sparkle readiness ($CONFIG build): committed config $([ -z "$COMMITTED_KEY" ] && echo off || echo on), empty key off, test key on, half configuration refused"
