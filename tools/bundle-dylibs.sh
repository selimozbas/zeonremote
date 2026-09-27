#!/bin/bash
# Copies all non-system dylibs an app bundle depends on into
# Contents/Frameworks, rewrites their install names and ad-hoc signs the
# result so the app runs on Macs without Homebrew.
#
# Usage: tools/bundle-dylibs.sh path/to/ZeonVNC.app [signing identity]
#
# Without an identity the bundle is signed ad hoc. Ad hoc signatures
# change on every build, which makes macOS forget Keychain access and
# Local Network permission, so a real (e.g. Apple Development) identity
# is preferred. A "Developer ID Application" identity additionally turns
# on the hardened runtime and a secure timestamp, which notarization
# requires (see tools/notarize.sh).
set -euo pipefail

APP="$1"
IDENTITY="${2:--}"
BIN="$APP/Contents/MacOS/$(basename "$APP" .app)"
FW="$APP/Contents/Frameworks"
mkdir -p "$FW"

is_external() {
  case "$1" in
    /System/*|/usr/lib/*|@*) return 1 ;;
    *) return 0 ;;
  esac
}

deps() {
  otool -L "$1" | tail -n +2 | awk '{print $1}'
}

queue=("$BIN")
done_list=" "

while [ ${#queue[@]} -gt 0 ]; do
  file="${queue[0]}"
  queue=("${queue[@]:1}")

  for dep in $(deps "$file"); do
    is_external "$dep" || continue
    real=$(realpath "$dep")
    name=$(basename "$dep")
    target="$FW/$name"
    if [ ! -f "$target" ]; then
      cp "$real" "$target"
      chmod u+w "$target"
      install_name_tool -id "@rpath/$name" "$target" 2>/dev/null
    fi
    install_name_tool -change "$dep" "@rpath/$name" "$file" 2>/dev/null
    case "$done_list" in
      *" $name "*) ;;
      *) done_list="$done_list$name "; queue+=("$target") ;;
    esac
  done
done

# Let the executable find the bundled libraries
if ! otool -l "$BIN" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN"
fi

# Libraries loading each other need the rpath too
for lib in "$FW"/*.dylib; do
  otool -l "$lib" | grep -q "@loader_path" || install_name_tool -add_rpath "@loader_path" "$lib" 2>/dev/null || true
done

sign_opts=()
if [ "$IDENTITY" != "-" ] &&
   security find-identity -v -p codesigning | grep -F "$IDENTITY" | grep -q "Developer ID Application"; then
  sign_opts=(--options runtime --timestamp)
fi

sign() { codesign --force --sign "$IDENTITY" ${sign_opts[@]+"${sign_opts[@]}"} "$@" >/dev/null; }

# Sparkle's helpers are signed inside out, as its documentation describes
SPARKLE="$FW/Sparkle.framework/Versions/B"
if [ -d "$SPARKLE" ]; then
  sign "$SPARKLE/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
  sign "$SPARKLE/Autoupdate"
  sign "$SPARKLE/Updater.app"
  sign "$FW/Sparkle.framework"
fi

sign "$FW"/*.dylib
sign "$APP"

echo "Bundled:$done_list"
echo "Signed with: $IDENTITY ${sign_opts[*]:-}"
