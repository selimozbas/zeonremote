#!/bin/bash
# Checks the app inside a release DMG before it is published:
#
# - version in Info.plist matches project(ZeonVNC VERSION ...)
# - LSMinimumSystemVersion is set, and no executable or library in the
#   bundle needs a newer macOS than that (the 0.3 binary needed macOS 27)
# - everything is built for arm64
# - the code signature is valid
#
# Usage: tools/check-release.sh path/to/ZeonVNC-x.y.z.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG="${1:?usage: tools/check-release.sh <dmg>}"
MOUNT=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null
trap 'hdiutil detach "$MOUNT" >/dev/null 2>&1; rmdir "$MOUNT"' EXIT
APP="$MOUNT/ZeonVNC.app"
ERRORS=0
error() { echo "error: $*" >&2; ERRORS=$((ERRORS + 1)); }

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null || true; }

# 1.2.3 -> 001002003 for comparing versions as numbers
vnum() { IFS=. read -r a b c <<<"$1"; printf "%03d%03d%03d" "${a:-0}" "${b:-0}" "${c:-0}"; }

EXPECTED=$(sed -n 's/^project(ZeonVNC VERSION \([0-9.]*\).*/\1/p' "$ROOT/CMakeLists.txt")
VERSION=$(plist CFBundleShortVersionString)
[ "$VERSION" = "$EXPECTED" ] || error "version is '$VERSION', expected $EXPECTED"

MIN=$(plist LSMinimumSystemVersion)
if [ -z "$MIN" ]; then
  error "LSMinimumSystemVersion is not set"
  MIN=0
fi

while IFS= read -r f; do
  file -b "$f" | grep -q "Mach-O" || continue
  name=${f#"$APP/"}
  archs=$(lipo -archs "$f")
  [[ " $archs " == *" arm64 "* ]] || error "$name is built for '$archs', not arm64"
  minos=$(otool -l "$f" | awk '/LC_BUILD_VERSION/{b=1} b && $1=="minos"{print $2; exit}')
  if [ -z "$minos" ]; then
    minos=$(otool -l "$f" | awk '/LC_VERSION_MIN_MACOSX/{b=1} b && $1=="version"{print $2; exit}')
  fi
  if [ -n "$minos" ] && [ "$(vnum "$minos")" -gt "$(vnum "$MIN")" ]; then
    error "$name needs macOS $minos, but the app claims macOS $MIN"
  fi
done < <(find "$APP/Contents" -type f \( -perm -u+x -o -name "*.dylib" \))

codesign --verify --deep --strict "$APP" || error "invalid code signature"

if [ "$ERRORS" -gt 0 ]; then
  echo "$DMG: $ERRORS problem(s)" >&2
  exit 1
fi
echo "$DMG: version $VERSION, macOS $MIN or later, arm64, signature valid"
