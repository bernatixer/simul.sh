#!/bin/bash
# Regenerates Resources/AppIcon.icns and docs/assets/{banner,og}.png from
# scripts/make-icon.swift.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc -parse-as-library -swift-version 6 \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -target arm64-apple-macos14.0 \
  "$HERE/scripts/make-icon.swift" "$HERE/UI/Components/DotMatrix.swift" -o "$WORK/make-icon"
"$WORK/make-icon" "$WORK/AppIcon.iconset" "$HERE/docs/assets"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$HERE/Resources/AppIcon.icns"
cp "$WORK/AppIcon.iconset/icon_512x512@2x.png" "$HERE/Resources/AppIcon.png"
echo "ok: $HERE/Resources/AppIcon.icns"
