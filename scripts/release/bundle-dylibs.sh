#!/bin/bash
# Copies every non-system dylib the app needs (Homebrew FFmpeg and all its transitive
# dependencies: x264, x265, LAME, dav1d, …) into WizRec.app/Contents/Frameworks, rewrites
# their install names to @rpath/<name>, gives the executable an
# @executable_path/../Frameworks run path, and copies each library's licence files from its
# Homebrew keg into Contents/Resources/Licenses/<formula>/ with a MANIFEST.txt.
#
#   scripts/release/bundle-dylibs.sh build/WizRec.app
#
# Ends with an ad-hoc signature (install_name_tool invalidates signatures; arm64 refuses to
# load unsigned code). scripts/release/sign.sh re-signs with a real identity.
# Fails if any Mach-O in the bundle still points into /opt/homebrew or /usr/local.
set -euo pipefail

APP=${1:?usage: bundle-dylibs.sh <WizRec.app>}
EXE="$APP/Contents/MacOS/WizRec"
FW="$APP/Contents/Frameworks"
LIC="$APP/Contents/Resources/Licenses"
[ -x "$EXE" ] || { echo "error: $EXE not found" >&2; exit 1; }
mkdir -p "$FW" "$LIC"

# System locations stay as they are; everything else is bundled.
is_system() { case "$1" in /usr/lib/*|/System/*) return 0;; *) return 1;; esac; }

# Run paths of a Mach-O (LC_RPATH entries), one per line, with @loader_path expanded.
rpaths() {
  local f=$1 dir
  dir=$(dirname "$f")
  otool -l "$f" | awk '/cmd LC_RPATH/{r=1} r&&/ path /{print $2; r=0}' | sed "s|@loader_path|$dir|g"
}

# Resolves a load command (absolute, @rpath/…, @loader_path/…) of $2 to a real file.
resolve() {
  local dep=$1 from=$2 rest p
  case "$dep" in
    @rpath/*)
      rest=${dep#@rpath/}
      while IFS= read -r p; do
        [ -n "$p" ] && [ -f "$p/$rest" ] && { realpath "$p/$rest"; return 0; }
      done < <(rpaths "$from"; echo /opt/homebrew/lib; echo /usr/local/lib)
      return 1;;
    @loader_path/*) realpath "$(dirname "$from")/${dep#@loader_path/}";;
    @executable_path/*) realpath "$(dirname "$EXE")/${dep#@executable_path/}";;
    *) realpath "$dep";;
  esac
}

# Homebrew keg (…/Cellar/<formula>/<version>) of a real library path, or empty.
keg() { echo "$1" | sed -nE 's|^(.*/Cellar/[^/]+/[^/]+)/.*|\1|p'; }

MANIFEST="$LIC/MANIFEST.txt"
echo "# Libraries bundled in Contents/Frameworks: <file> <formula> <version> <licence>" > "$MANIFEST"

record_licence() {
  local name=$1 real=$2 k formula version licence
  k=$(keg "$real")
  if [ -z "$k" ]; then
    echo "$name (not from Homebrew: $real) - - UNKNOWN" >> "$MANIFEST"
    echo "warning: $name is not from a Homebrew keg; add its licence by hand" >&2
    return
  fi
  formula=$(basename "$(dirname "$k")"); version=$(basename "$k")
  # SPDX expression from the formula (Homebrew's SBOM leaves it as NOASSERTION).
  licence=$(brew info --json=v2 "$formula" 2>/dev/null | python3 -I -c 'import json,sys
f=json.load(sys.stdin)["formulae"]
print((f[0].get("license") if f else None) or "UNKNOWN")' 2>/dev/null || echo UNKNOWN)
  licence=$(echo "$licence" | tr ' ' '_')
  echo "$name $formula $version $licence" >> "$MANIFEST"
  if [ ! -d "$LIC/$formula" ]; then
    mkdir -p "$LIC/$formula"
    local found=0 f
    for f in "$k"/COPYING* "$k"/LICENSE* "$k"/LICENCE* "$k"/COPYRIGHT* "$k"/NOTICE* "$k"/AUTHORS*; do
      [ -f "$f" ] && { cp "$f" "$LIC/$formula/"; found=1; }
    done
    [ "$found" = 1 ] || echo "warning: no licence file in $k (licence: $licence); add it to THIRD_PARTY_NOTICES" >&2
  fi
}

# Breadth-first walk from the executable.
queue=("$EXE")
done_list=" "
while [ ${#queue[@]} -gt 0 ]; do
  f=${queue[0]}; queue=("${queue[@]:1}")
  case "$done_list" in *" $f "*) continue;; esac
  done_list="$done_list$f "
  # First line of otool -L on a dylib is its own id; skip it by comparing names.
  self=$(otool -D "$f" | tail -n +2)
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    [ "$dep" = "$self" ] && continue
    is_system "$dep" && continue
    case "$dep" in @rpath/*) [ -f "$FW/${dep#@rpath/}" ] && continue;; esac
    real=$(resolve "$dep" "$f") || { echo "error: cannot resolve $dep (needed by $f)" >&2; exit 1; }
    name=$(basename "$dep")
    if [ ! -f "$FW/$name" ]; then
      cp "$real" "$FW/$name"
      chmod u+w "$FW/$name"
      install_name_tool -id "@rpath/$name" "$FW/$name" 2>/dev/null
      record_licence "$name" "$real"
      queue+=("$FW/$name")
    fi
    install_name_tool -change "$dep" "@rpath/$name" "$f" 2>/dev/null
  done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
done

if ! otool -l "$EXE" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE"
fi

# Nothing may still point outside the bundle.
leaks=0
for f in "$EXE" "$FW"/*.dylib; do
  if otool -L "$f" | tail -n +2 | grep -E "/opt/homebrew|/usr/local|/Cellar/"; then
    echo "error: $f still links outside the bundle" >&2; leaks=1
  fi
done
[ "$leaks" = 0 ] || exit 1

# WizRec's own licence and the third-party notices travel with the binaries.
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cp "$ROOT/LICENSE" "$LIC/WizRec-LICENSE.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$LIC/THIRD_PARTY_NOTICES.md"

# Ad-hoc signatures (inside out) so the bundle runs; sign.sh replaces them.
for f in "$FW"/*.dylib; do codesign --force --sign - "$f" >/dev/null 2>&1; done
codesign --force --sign - "$APP" >/dev/null 2>&1

count=$(ls "$FW"/*.dylib | wc -l | tr -d ' ')
size=$(du -sh "$FW" | cut -f1)
echo "Bundled $count dylibs ($size) into $FW; licences in $LIC"
