#!/bin/bash
# Builds build/ZeonRemote-<version>.dmg from build/src/ZeonRemote.app
# (installed as "Zeon Remote.app")
#
# Usage: tools/make-dmg.sh [build directory]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$ROOT/build}"
APP="$BUILD/src/ZeonRemote.app"

if [ ! -d "$APP" ]; then
  echo "error: $APP not found, build first" >&2
  exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
SHORT=${VERSION%.0}
DMG="$BUILD/ZeonRemote-$SHORT.dmg"
STAGE="$BUILD/dmg-stage"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Zeon Remote.app"
cp "$ROOT/LICENSE" "$STAGE/LICENSE.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGE/Third Party Notices.md"

# Finder window layout needs a logged in GUI session, which CI lacks
extra=()
if [ -n "${CI:-}" ]; then
  extra=(--skip-jenkins)
fi

create-dmg ${extra[@]+"${extra[@]}"} \
  --volname "Zeon Remote $SHORT" \
  --volicon "$ROOT/resources/ZeonVNC.icns" \
  --window-pos 200 120 \
  --window-size 620 400 \
  --icon-size 110 \
  --icon "Zeon Remote.app" 170 170 \
  --app-drop-link 450 170 \
  --icon "LICENSE.txt" 170 320 \
  --icon "Third Party Notices.md" 450 320 \
  --no-internet-enable \
  "$DMG" "$STAGE" >/dev/null

rm -rf "$STAGE"
echo "$DMG"
