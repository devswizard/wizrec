#!/bin/bash
# Prints the Sparkle Info.plist entries for make-app.sh. The values come from the committed
# release/sparkle.conf (feed_url, public_ed_key); the environment overrides each one:
#
#   WIZREC_SPARKLE_FEED     appcast URL (https only), e.g. https://example.org/wizrec/appcast.xml
#   WIZREC_SPARKLE_PUBKEY   EdDSA public key from Sparkle's generate_keys (base64, 32 bytes)
#   WIZREC_SPARKLE_CONF     another config file (default: release/sparkle.conf)
#
# No public key (the committed state until the maintainer creates one): prints nothing, and
# the app's updater stays off. A feed set in the environment without a key, a key without a
# feed, or an invalid value: exits 1, so a release is never built with a half-configured
# updater. The private key is never read here; it stays in the maintainer's keychain
# (docs/RELEASING.md, "Sparkle").
set -euo pipefail

CONF=${WIZREC_SPARKLE_CONF:-$(cd "$(dirname "$0")/../.." && pwd)/release/sparkle.conf}

# Value of `key = value` in $CONF (comments and blanks ignored); empty when absent.
conf() {
  [ -f "$CONF" ] || return 0
  awk -v k="$1" -F= '
    /^[[:space:]]*#/ { next }
    { key=$1; gsub(/[[:space:]]/, "", key) }
    key == k { v=substr($0, index($0, "=") + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print v; exit }
  ' "$CONF"
}

FEED=${WIZREC_SPARKLE_FEED:-$(conf feed_url)}
KEY=${WIZREC_SPARKLE_PUBKEY:-$(conf public_ed_key)}

if [ -z "$KEY" ]; then
  if [ -n "${WIZREC_SPARKLE_FEED:-}" ]; then
    echo "error: WIZREC_SPARKLE_FEED is set but there is no public key (WIZREC_SPARKLE_PUBKEY or public_ed_key in $CONF)" >&2
    exit 1
  fi
  exit 0   # updater off
fi
if [ -z "$FEED" ]; then
  echo "error: a Sparkle public key is set but no feed URL (WIZREC_SPARKLE_FEED or feed_url in $CONF)" >&2
  exit 1
fi
case "$FEED" in
  https://?*) ;;
  *) echo "error: the Sparkle feed URL must be an https:// URL (got '$FEED')" >&2; exit 1;;
esac
case "$FEED$KEY" in
  *[\<\>\&\"\'[:space:]]*) echo "error: the Sparkle feed URL or public key contains invalid characters" >&2; exit 1;;
esac
len=$(printf '%s' "$KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')
if [ "$len" != 32 ]; then
  echo "error: the Sparkle public key is not a base64 Ed25519 public key (generate_keys -p prints it)" >&2
  exit 1
fi

printf '    <key>SUFeedURL</key><string>%s</string>\n' "$FEED"
printf '    <key>SUPublicEDKey</key><string>%s</string>\n' "$KEY"
