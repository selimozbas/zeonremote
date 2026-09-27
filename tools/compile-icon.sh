#!/bin/bash
# Compiles resources/AppIcon.icon (Icon Composer) into Assets.car and
# AppIcon.icns. Needs Xcode 26 or later on macOS 26 or later.
#
# Usage: tools/compile-icon.sh <output folder>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: tools/compile-icon.sh <output folder>}"
mkdir -p "$OUT"
xcrun actool "$ROOT/resources/AppIcon.icon" --compile "$OUT" \
  --app-icon AppIcon --include-all-app-icons \
  --output-partial-info-plist "$OUT/partial.plist" \
  --platform macosx --target-device mac --minimum-deployment-target 13.0 \
  --enable-on-demand-resources NO --development-region en \
  --errors --warnings --output-format human-readable-text
test -f "$OUT/Assets.car" && test -f "$OUT/AppIcon.icns"
