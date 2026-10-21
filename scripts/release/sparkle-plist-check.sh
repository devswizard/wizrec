#!/bin/bash
# Reads the Sparkle entries of a built app's Info.plist and prints the updater state, with the
# same rules as the app's UpdaterConfiguration (PlayerKit):
#
#   off                  neither SUFeedURL nor SUPublicEDKey: the updater never starts
#   on <feed URL>        an https SUFeedURL and a base64 32-byte SUPublicEDKey
#
# Anything else (one of the two alone, a feed that is not https, a key that is not 32 bytes of
# base64) is a half-configured updater: exits 1. Never reads a private key or the keychain.
#
#   scripts/release/sparkle-plist-check.sh build/WizRec.app
#   scripts/release/sparkle-plist-check.sh build/WizRec.app --expect off
#   scripts/release/sparkle-plist-check.sh build/WizRec.app --expect on [--key <base64>] [--feed <url>]
#
# --expect fails (exit 1) when the state differs; --key / --feed also require those exact values.
set -euo pipefail

usage() { echo "usage: sparkle-plist-check.sh <WizRec.app|Info.plist> [--expect off|on] [--key K] [--feed URL]" >&2; exit 2; }
[ $# -ge 1 ] || usage
target=$1; shift
expect=""; want_key=""; want_feed=""
while [ $# -gt 0 ]; do
  case "$1" in
    --expect) expect=${2:-}; shift 2 || usage ;;
    --key) want_key=${2:-}; shift 2 || usage ;;
    --feed) want_feed=${2:-}; shift 2 || usage ;;
    *) usage ;;
  esac
done
case "$expect" in ""|on|off) ;; *) usage ;; esac

plist=$target
[ -d "$target" ] && plist="$target/Contents/Info.plist"
[ -f "$plist" ] || { echo "error: no Info.plist at $plist" >&2; exit 1; }
plutil -lint "$plist" >/dev/null

# Value of a top-level string key, empty when absent.
get() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true; }
feed=$(get SUFeedURL)
key=$(get SUPublicEDKey)

if [ -z "$feed" ] && [ -z "$key" ]; then
  state=off
else
  [ -n "$feed" ] || { echo "error: $plist has SUPublicEDKey but no SUFeedURL" >&2; exit 1; }
  [ -n "$key" ] || { echo "error: $plist has SUFeedURL but no SUPublicEDKey" >&2; exit 1; }
  case "$feed" in
    https://?*) ;;
    *) echo "error: SUFeedURL is not an https URL: $feed" >&2; exit 1 ;;
  esac
  len=$(printf '%s' "$key" | base64 -D 2>/dev/null | wc -c | tr -d ' ')
  [ "$len" = 32 ] || { echo "error: SUPublicEDKey is not 32 bytes of base64" >&2; exit 1; }
  state=on
fi

if [ -n "$expect" ] && [ "$state" != "$expect" ]; then
  echo "error: updater is $state in $plist, expected $expect" >&2; exit 1
fi
if [ -n "$want_key" ] && [ "$key" != "$want_key" ]; then
  echo "error: SUPublicEDKey in $plist is not the expected key" >&2; exit 1
fi
if [ -n "$want_feed" ] && [ "$feed" != "$want_feed" ]; then
  echo "error: SUFeedURL in $plist is '$feed', expected '$want_feed'" >&2; exit 1
fi

if [ "$state" = on ]; then echo "on $feed"; else echo off; fi
