#!/bin/bash
# Prints the Sparkle Info.plist entries for make-app.sh, from the build-time environment:
#
#   WIZREC_SPARKLE_FEED     appcast URL (https only), e.g. https://example.org/wizrec/appcast.xml
#   WIZREC_SPARKLE_PUBKEY   EdDSA public key from Sparkle's generate_keys (base64, 32 bytes)
#
# Both unset: prints nothing (the app's updater stays off). Only one set, or an invalid value:
# exits 1, so a release is never built with a half-configured updater. The private key is
# never read here; it stays in the maintainer's keychain (docs/RELEASING.md, "Sparkle").
set -euo pipefail

FEED=${WIZREC_SPARKLE_FEED:-}
KEY=${WIZREC_SPARKLE_PUBKEY:-}

[ -z "$FEED" ] && [ -z "$KEY" ] && exit 0
if [ -z "$FEED" ] || [ -z "$KEY" ]; then
  echo "error: set both WIZREC_SPARKLE_FEED and WIZREC_SPARKLE_PUBKEY, or neither" >&2
  exit 1
fi
case "$FEED" in
  https://?*) ;;
  *) echo "error: WIZREC_SPARKLE_FEED must be an https:// URL" >&2; exit 1;;
esac
case "$FEED$KEY" in
  *[\<\>\&\"\'[:space:]]*) echo "error: WIZREC_SPARKLE_FEED/WIZREC_SPARKLE_PUBKEY contain invalid characters" >&2; exit 1;;
esac
len=$(printf '%s' "$KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')
if [ "$len" != 32 ]; then
  echo "error: WIZREC_SPARKLE_PUBKEY is not a base64 Ed25519 public key (generate_keys -p prints it)" >&2
  exit 1
fi

printf '    <key>SUFeedURL</key><string>%s</string>\n' "$FEED"
printf '    <key>SUPublicEDKey</key><string>%s</string>\n' "$KEY"
