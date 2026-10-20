#!/bin/bash
# Adds a published release to the Sparkle appcast (release/appcast.xml, served from main by
# raw.githubusercontent.com; see release/sparkle.conf):
#
#   1. downloads the PUBLIC DMG and SHA256SUMS.txt of <tag> (no token) and checks the sum;
#   2. reads the app's versions from the DMG (mounted read-only) and checks them;
#   3. signs the DMG with Sparkle's sign_update, which reads the EdDSA private key from the
#      login keychain itself (or SPARKLE_KEY_FILE, passed on stdin). This script never reads,
#      prints or stores the key;
#   4. checks the signature against public_ed_key in release/sparkle.conf (openssl);
#   5. writes the item (replacing an earlier item of the same version), newest first, then
#      signs the feed itself (sign_update embeds the signature in the XML).
#
#   scripts/release/update-appcast.sh v0.2.0
#   git add release/appcast.xml && git commit -m "Appcast: v0.2.0"   # then push to main
#
# Environment (all optional):
#   GITHUB_REPOSITORY    owner/repo (default devswizard/wizrec)
#   WIZREC_DOWNLOAD_BASE where the assets are (default https://github.com/<repo>/releases/download/<tag>)
#   WIZREC_APPCAST       appcast file (default release/appcast.xml)
#   WIZREC_SPARKLE_CONF  config with the public key (default release/sparkle.conf)
#   SPARKLE_BIN          Sparkle's bin/ (default .build/artifacts/sparkle/Sparkle/bin, after swift build)
#   SPARKLE_ACCOUNT      keychain account of the key (generate_keys --account)
#   SPARKLE_KEY_FILE     private key file instead of the keychain (CI)
#   SIGN_FEED=0          do not sign the appcast file itself
#   WIZREC_DMG_TOOL      auto (default), diskutil or hdiutil, as in verify-dmg.sh
set -euo pipefail

TAG=${1:?usage: update-appcast.sh <tag>}
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "error: invalid tag '$TAG'" >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
REPO=${GITHUB_REPOSITORY:-devswizard/wizrec}
VERSION=${TAG#v}
BASE=${WIZREC_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download/$TAG}
APPCAST=${WIZREC_APPCAST:-$ROOT/release/appcast.xml}
CONF=${WIZREC_SPARKLE_CONF:-$ROOT/release/sparkle.conf}
BIN=${SPARKLE_BIN:-$ROOT/.build/artifacts/sparkle/Sparkle/bin}
DMG_NAME="WizRec-$VERSION.dmg"
DMG_URL="$BASE/$DMG_NAME"

[ -x "$BIN/sign_update" ] || { echo "error: $BIN/sign_update not found (run swift build, or set SPARKLE_BIN)" >&2; exit 1; }
PUBKEY=$(WIZREC_SPARKLE_CONF="$CONF" WIZREC_SPARKLE_FEED='' WIZREC_SPARKLE_PUBKEY='' \
  "$ROOT/scripts/release/sparkle-info.sh" | sed -n 's|.*<key>SUPublicEDKey</key><string>\(.*\)</string>|\1|p')
if [ -z "$PUBKEY" ]; then
  echo "error: no public_ed_key in $CONF: the updater is off. Create the key pair first (docs/RELEASING.md, \"Sparkle: turning updates on\")" >&2
  exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/wizrec-appcast.XXXXXX")
MNT=""; DEV=""; TOOL=${WIZREC_DMG_TOOL:-auto}
cleanup() {
  if [ -n "$MNT" ]; then
    if [ "$TOOL" = diskutil ]; then
      [ -n "$DEV" ] && { diskutil eject "$DEV" >/dev/null 2>&1 || diskutil unmountDisk force "$DEV" >/dev/null 2>&1 || true; }
    else
      hdiutil detach "$MNT" -quiet 2>/dev/null || hdiutil detach "$MNT" -force -quiet 2>/dev/null || true
    fi
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# 1. Public assets, checksum.
echo "Downloading $DMG_URL"
(cd "$WORK" && curl -fsSL --retry 3 -o "$DMG_NAME" "$DMG_URL" && curl -fsSL --retry 3 -o SHA256SUMS.txt "$BASE/SHA256SUMS.txt")
(cd "$WORK" && awk -v n="$DMG_NAME" '$2==n' SHA256SUMS.txt | shasum -a 256 -c -)
DMG="$WORK/$DMG_NAME"
LENGTH=$(stat -f %z "$DMG")

# 2. Versions from the app inside the DMG.
if [ "$TOOL" = auto ]; then
  if diskutil image attach --help 2>/dev/null | grep -q -- '--mountPoint'; then TOOL=diskutil; else TOOL=hdiutil; fi
fi
MNT="$WORK/mnt"; mkdir -p "$MNT"
if [ "$TOOL" = diskutil ]; then
  attach_out=$(diskutil image attach --readOnly --nobrowse --mountPoint "$MNT" "$DMG")
  DEV=$(printf '%s\n' "$attach_out" | awk '/^\/dev\/disk[0-9]+[ \t]/ { print $1; exit }')
else
  hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$DMG" >/dev/null
fi
PLIST="$MNT/WizRec.app/Contents/Info.plist"
[ -f "$PLIST" ] || { echo "error: no WizRec.app in $DMG_NAME" >&2; exit 1; }
pl() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }
BUILD=$(pl CFBundleVersion); SHORT=$(pl CFBundleShortVersionString); MINOS=$(pl LSMinimumSystemVersion)
APPKEY=$(pl SUPublicEDKey)
[ "$SHORT" = "$VERSION" ] || { echo "error: the DMG's app is version '$SHORT', expected $VERSION" >&2; exit 1; }
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "error: CFBundleVersion '$BUILD' is not a number" >&2; exit 1; }
if [ -z "$APPKEY" ]; then
  echo "warning: $TAG was built with the updater off: its installs never read the feed; newer builds still see this item" >&2
elif [ "$APPKEY" != "$PUBKEY" ]; then
  echo "error: the app's SUPublicEDKey differs from public_ed_key in $CONF" >&2; exit 1
fi

# 3. Signature (sign_update reads the private key itself).
args=(-p)
[ -n "${SPARKLE_ACCOUNT:-}" ] && args+=(--account "$SPARKLE_ACCOUNT")
if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
  SIG=$("$BIN/sign_update" "${args[@]}" --ed-key-file - "$DMG" < "$SPARKLE_KEY_FILE")
else
  SIG=$("$BIN/sign_update" "${args[@]}" "$DMG")
fi
SIG=$(printf '%s' "$SIG" | tr -d '[:space:]')
[ "$(printf '%s' "$SIG" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" = 64 ] || { echo "error: sign_update gave no Ed25519 signature" >&2; exit 1; }

# 4. The signature must verify with the public key the app ships (Ed25519 SPKI = fixed
#    12-byte DER prefix + raw key).
OPENSSL=$(command -v /opt/homebrew/bin/openssl || command -v openssl)
{ printf '302a300506032b6570032100' | xxd -r -p; printf '%s' "$PUBKEY" | base64 -D; } > "$WORK/pub.der"
printf '%s' "$SIG" | base64 -D > "$WORK/sig.bin"
if "$OPENSSL" pkeyutl -verify -pubin -keyform DER -inkey "$WORK/pub.der" -rawin -in "$DMG" -sigfile "$WORK/sig.bin" >/dev/null 2>&1; then
  echo "Signature verified with public_ed_key."
else
  echo "error: the signature does not verify with public_ed_key in $CONF (wrong key in the keychain?)" >&2
  exit 1
fi

# 5. Appcast item.
PUBDATE=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/tags/$TAG" 2>/dev/null \
  | python3 -I -c 'import json,sys,email.utils,datetime
d=json.load(sys.stdin).get("published_at")
print(email.utils.format_datetime(datetime.datetime.fromisoformat(d.replace("Z","+00:00"))) if d else "")' 2>/dev/null || true)
[ -n "$PUBDATE" ] || PUBDATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

mkdir -p "$(dirname "$APPCAST")"
python3 -I - "$APPCAST" "$REPO" "$TAG" "$VERSION" "$BUILD" "${MINOS:-14.0}" "$PUBDATE" "$DMG_URL" "$LENGTH" "$SIG" <<'PY'
import os, sys, xml.etree.ElementTree as ET
path, repo, tag, version, build, minos, pubdate, url, length, sig = sys.argv[1:]
SP = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SP)
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")
q = lambda n: "{%s}%s" % (SP, n)
if os.path.exists(path):
    root = ET.parse(path).getroot()          # drops comments, including an old feed signature
    channel = root.find("channel")
else:
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "WizRec"
    ET.SubElement(channel, "link").text = f"https://github.com/{repo}"
    ET.SubElement(channel, "description").text = "WizRec updates"
    ET.SubElement(channel, "language").text = "en"
for old in channel.findall("item"):
    if old.findtext(q("version")) == build or old.findtext(q("shortVersionString")) == version:
        channel.remove(old)
item = ET.Element("item")
notes = f"https://github.com/{repo}/releases/tag/{tag}"
for tag_name, text in (("title", f"WizRec {version}"), ("pubDate", pubdate), ("link", notes),
                       (q("version"), build), (q("shortVersionString"), version),
                       (q("minimumSystemVersion"), minos), (q("fullReleaseNotesLink"), notes)):
    ET.SubElement(item, tag_name).text = text
ET.SubElement(item, "enclosure", {"url": url, "length": length, "type": "application/octet-stream",
                                  q("edSignature"): sig})
# Items after the channel's own elements, newest (highest build number) first.
items = channel.findall("item") + [item]
for i in channel.findall("item"):
    channel.remove(i)
for i in sorted(items, key=lambda i: int(i.findtext(q("version")) or 0), reverse=True):
    channel.append(i)
ET.indent(root, space="  ")
with open(path, "w", encoding="utf-8") as f:
    f.write('<?xml version="1.0" encoding="utf-8"?>\n')
    f.write(ET.tostring(root, encoding="unicode"))
    f.write("\n")
PY

if [ "${SIGN_FEED:-1}" = 1 ]; then
  if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
    "${BIN}/sign_update" ${SPARKLE_ACCOUNT:+--account "$SPARKLE_ACCOUNT"} --ed-key-file - "$APPCAST" < "$SPARKLE_KEY_FILE"
  else
    "${BIN}/sign_update" ${SPARKLE_ACCOUNT:+--account "$SPARKLE_ACCOUNT"} "$APPCAST"
  fi
fi
xmllint --noout "$APPCAST" 2>/dev/null || python3 -I -c 'import sys,xml.etree.ElementTree as E; E.parse(sys.argv[1])' "$APPCAST"
echo "Appcast: $APPCAST has WizRec $VERSION (build $BUILD, $LENGTH bytes). Commit it and push to main."
