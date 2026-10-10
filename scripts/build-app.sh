#!/bin/bash
# Compiles the app and produces Build/Simul.app.
# Uses swiftc + the CommandLineTools SDK — no xcodeproj, no Xcode.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY_OUT="$HERE/Vendor/Ghostty/zig-out"
BRIDGE_INCLUDE="$HERE/Terminal/GhosttyBridge/include"
APP="$HERE/Build/Simul.app"
CONTENTS="$APP/Contents"

if [ ! -f "$GHOSTTY_OUT/lib/libghostty.a" ]; then
  echo "error: libghostty.a missing — run scripts/build-ghostty.sh first" >&2
  exit 1
fi

# Prepare the Swift<->C bridge header + module map.
mkdir -p "$BRIDGE_INCLUDE"
cp "$GHOSTTY_OUT/include/ghostty.h" "$BRIDGE_INCLUDE/ghostty.h"
cat > "$BRIDGE_INCLUDE/module.modulemap" <<'EOF'
module Ghostty {
    umbrella header "ghostty.h"
    export *
}
EOF

# App bundle skeleton.
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$HERE/Support/Info.plist" "$CONTENTS/Info.plist"

# Version: SIMUL_VERSION (set by release.sh), else the latest vX.Y.Z tag,
# else what Info.plist says. Build number: commit count, always increasing.
VERSION="${SIMUL_VERSION:-$(git -C "$HERE" describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
PLIST=/usr/libexec/PlistBuddy
[ -n "$VERSION" ] && "$PLIST" -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
"$PLIST" -c "Set :CFBundleVersion $(git -C "$HERE" rev-list --count HEAD)" "$CONTENTS/Info.plist"

# Simul's and Ghostty's licenses ship with every build (Ghostty's MIT
# license requires it).
cp "$HERE/LICENSE" "$CONTENTS/Resources/LICENSE"
cp "$HERE/Vendor/Ghostty/LICENSE" "$CONTENTS/Resources/LICENSE-Ghostty"

# Ghostty resources (terminfo, shell-integration, themes).
# Layout matches zig-out: share/ghostty + share/terminfo (sibling).
if [ -d "$GHOSTTY_OUT/share/ghostty" ]; then
  mkdir -p "$CONTENTS/Resources/share"
  cp -R "$GHOSTTY_OUT/share/ghostty" "$CONTENTS/Resources/share/ghostty"
  if [ -d "$GHOSTTY_OUT/share/terminfo" ]; then
    cp -R "$GHOSTTY_OUT/share/terminfo" "$CONTENTS/Resources/share/terminfo"
  fi
fi

# App icon (regenerate with scripts/make-icon.sh).
cp "$HERE/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

# Provider icons.
if [ -d "$HERE/Resources/icons" ]; then
  cp -R "$HERE/Resources/icons" "$CONTENTS/Resources/icons"
fi

SOURCES=(
  App/SimulApp.swift
  App/AppCommands.swift
  App/SmokeMode.swift
  Models/Session.swift
  Models/AgentDefinition.swift
  State/AppModel.swift
  Persistence/SessionStore.swift
  Sessions/SessionBackend.swift
  Sessions/ExecutableResolver.swift
  Sessions/TmuxSessionBackend.swift
  Sessions/DirectSessionBackend.swift
  Sessions/AgentConversations.swift
  Sessions/UsageRefresher.swift
  Terminal/TerminalHost.swift
  Terminal/GhosttyTerminalHost.swift
  Terminal/GhosttyBridge/GhosttyInput.swift
  Terminal/GhosttyBridge/GhosttyRuntime.swift
  Terminal/GhosttyBridge/GhosttySurfaceView.swift
  UI/ContentView.swift
  UI/Sidebar/SidebarView.swift
  UI/Terminal/TerminalContainer.swift
  UI/NewSession/NewSessionView.swift
  UI/Components/DotMatrix.swift
  UI/Components/Theme.swift
  UI/Settings/SettingsView.swift
  UI/MenuBar/MenuBarExtraView.swift
  Support/Logging.swift
  Support/Paths.swift
  Support/ClipboardPaste.swift
  Support/ImageTokens.swift
  Support/ProviderIcon.swift
  Support/LaunchEnvironment.swift
  Support/GitInfo.swift
  Support/RelativeAge.swift
  Support/UsageLimits.swift
  Support/Preferences.swift
)

cd "$HERE"
# The macOS 27 SDK ships @State/@Environment as SwiftUIMacros whose plugin
# is Xcode-only; the 26.5 SDK still has classic property wrappers and works
# with bare swiftc from Command Line Tools.
swiftc \
  -swift-version 6 \
  -O \
  -target arm64-apple-macos14.0 \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  -I "$BRIDGE_INCLUDE" \
  "${SOURCES[@]}" \
  -Xlinker "$GHOSTTY_OUT/lib/libghostty.a" \
  -framework AppKit \
  -framework SwiftUI \
  -framework Metal \
  -framework MetalKit \
  -framework QuartzCore \
  -framework CoreText \
  -framework CoreFoundation \
  -framework IOKit \
  -framework AudioToolbox \
  -framework Carbon \
  -lobjc -lz -lc++ \
  -o "$CONTENTS/MacOS/Simul"

# Ad-hoc signing so the bundle launches locally.
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null || true

echo "ok: $APP"

"$HERE/scripts/smoke.sh" "$APP"
