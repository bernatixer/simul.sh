#!/bin/bash
# Compiles the app and produces Build/AgentSessions.app.
# Uses swiftc + the CommandLineTools SDK — no xcodeproj, no Xcode.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY_OUT="$HERE/Vendor/Ghostty/zig-out"
BRIDGE_INCLUDE="$HERE/Terminal/GhosttyBridge/include"
APP="$HERE/Build/AgentSessions.app"
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

# Ghostty resources (terminfo, shell-integration, themes).
# Layout matches zig-out: share/ghostty + share/terminfo (sibling).
if [ -d "$GHOSTTY_OUT/share/ghostty" ]; then
  mkdir -p "$CONTENTS/Resources/share"
  cp -R "$GHOSTTY_OUT/share/ghostty" "$CONTENTS/Resources/share/ghostty"
  if [ -d "$GHOSTTY_OUT/share/terminfo" ]; then
    cp -R "$GHOSTTY_OUT/share/terminfo" "$CONTENTS/Resources/share/terminfo"
  fi
fi

SOURCES=(
  App/AgentSessionsApp.swift
  App/AppCommands.swift
  App/SmokeMode.swift
  Models/Session.swift
  Models/AgentDefinition.swift
  State/AppModel.swift
  Persistence/SessionStore.swift
  Sessions/SessionBackend.swift
  Sessions/ExecutableResolver.swift
  Sessions/TmuxSessionBackend.swift
  Terminal/TerminalHost.swift
  Terminal/GhosttyTerminalHost.swift
  Terminal/GhosttyBridge/GhosttyInput.swift
  Terminal/GhosttyBridge/GhosttyRuntime.swift
  Terminal/GhosttyBridge/GhosttySurfaceView.swift
  UI/ContentView.swift
  UI/Sidebar/SidebarView.swift
  UI/Sidebar/SessionRow.swift
  UI/Terminal/TerminalContainer.swift
  UI/NewSession/NewSessionView.swift
  Support/Logging.swift
  Support/Paths.swift
)

cd "$HERE"
# The macOS 27 SDK ships @State/@Environment as SwiftUIMacros whose plugin
# is Xcode-only; the 26.5 SDK still has classic property wrappers and works
# with bare swiftc from Command Line Tools.
swiftc \
  -swift-version 5 \
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
  -o "$CONTENTS/MacOS/AgentSessions"

# Ad-hoc signing so the bundle launches locally.
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null || true

echo "ok: $APP"
