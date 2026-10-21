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
# Removes run paths into the build machine (Xcode back-deployment, Homebrew) before signing.
# Fails if any Mach-O it handles still points into /opt/homebrew, /usr/local or a toolchain.
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
# Sparkle comes from SwiftPM (make-app.sh copies it and its licence), not from Homebrew.
if [ -d "$FW/Sparkle.framework" ]; then
  sv=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$FW/Sparkle.framework/Resources/Info.plist" 2>/dev/null || echo "?")
  echo "Sparkle.framework sparkle $sv MIT" >> "$MANIFEST"
  [ -f "$LIC/Sparkle/LICENSE" ] || { echo "error: Sparkle licence missing from $LIC/Sparkle" >&2; exit 1; }
fi

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

# Run paths into the build machine's toolchain or package manager mean nothing on a user's
# Mac, and dyld would search them first. Xcode adds one for Swift back-deployment
# (…/XcodeDefault.xctoolchain/usr/lib/swift-6.x/macosx); the walk above already copied
# anything the app loads through it into Contents/Frameworks. Removed before signing.
is_build_path() {
  case "$1" in
    */Xcode*.app/*|*/CommandLineTools/*|*.xctoolchain/*|/Library/Developer/*|/opt/homebrew/*|/usr/local/*|*/Cellar/*) return 0;;
    *) return 1;;
  esac
}
raw_rpaths() { otool -l "$1" | awk '/cmd LC_RPATH/{r=1} r&&/ path /{print $2; r=0}'; }
stripped=0
for f in "$EXE" "$FW"/*.dylib; do
  while IFS= read -r p; do
    if is_build_path "$p"; then
      # -delete_rpath removes one entry; a duplicate shows up again in the next pass. Bounded:
      # a failing install_name_tool, or more than 8 copies, stops the build with an error.
      passes=0
      while raw_rpaths "$f" | grep -qxF "$p"; do
        passes=$((passes + 1))
        if [ "$passes" -gt 8 ]; then
          echo "error: run path $p is still in $f after 8 removals" >&2; exit 1
        fi
        if ! err=$(install_name_tool -delete_rpath "$p" "$f" 2>&1); then
          echo "error: install_name_tool -delete_rpath $p failed on $f: $err" >&2; exit 1
        fi
      done
      echo "removed run path $p from $(basename "$f")"
      stripped=$((stripped + 1))
    fi
  done < <(raw_rpaths "$f" | sort -u)
done

# Nothing may still point outside the bundle: no load path and no run path into Homebrew,
# /usr/local or a developer toolchain.
leaks=0
for f in "$EXE" "$FW"/*.dylib; do
  if otool -L "$f" | tail -n +2 | grep -E "/opt/homebrew|/usr/local|/Cellar/|/Xcode[^/]*\.app/|/CommandLineTools/|\.xctoolchain/"; then
    echo "error: $f still links outside the bundle" >&2; leaks=1
  fi
  while IFS= read -r p; do
    is_build_path "$p" && { echo "error: $f still has run path $p" >&2; leaks=1; }
  done < <(raw_rpaths "$f")
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
echo "Bundled $count dylibs ($size) into $FW; licences in $LIC; removed $stripped build run path(s)"
