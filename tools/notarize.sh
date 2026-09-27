#!/bin/bash
# Signs, notarizes and staples a release DMG so Gatekeeper opens ZeonVNC
# without the "Apple could not verify" warning.
#
# Needs a paid Apple Developer account: the app must be built with a
# "Developer ID Application" identity (-DCODESIGN_IDENTITY=...) and the
# notary credentials stored once with
#
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
#
# Usage: tools/notarize.sh <profile> [path/to/ZeonVNC-x.y.dmg]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${1:?usage: tools/notarize.sh <keychain profile> [dmg]}"
DMG="${2:-$(ls -t "$ROOT"/build/ZeonVNC-*.dmg 2>/dev/null | head -n 1)}"

if [ ! -f "$DMG" ]; then
  echo "error: no DMG found, run tools/make-dmg.sh first" >&2
  exit 1
fi

# The DMG is signed with the identity the app inside was signed with
MOUNT=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null
APP="$MOUNT/ZeonVNC.app"
AUTHORITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)
RUNTIME=$(codesign -dv "$APP" 2>&1 | grep -c "flags=.*runtime" || true)
hdiutil detach "$MOUNT" >/dev/null
rmdir "$MOUNT"

case "$AUTHORITY" in
  "Developer ID Application:"*) ;;
  *)
    echo "error: the app is signed by '${AUTHORITY:-ad hoc}', not a Developer ID Application identity" >&2
    exit 1 ;;
esac
if [ "$RUNTIME" = 0 ]; then
  echo "error: the app is not signed with the hardened runtime" >&2
  exit 1
fi

codesign --force --sign "$AUTHORITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "$DMG"
