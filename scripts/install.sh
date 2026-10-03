#!/bin/bash
# Installs the app into /Applications and opens it, so it behaves like a
# normal Mac app (Dock, Launchpad, Spotlight). Re-run after each rebuild.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HERE/Build/Simul.app"
DEST="/Applications/Simul.app"

if [ ! -d "$APP" ]; then
  echo "error: $APP missing — run scripts/build-app.sh first" >&2
  exit 1
fi

killall Simul AgentSessions 2>/dev/null || true # AgentSessions = pre-rename
sleep 1
rm -rf "$DEST"
ditto "$APP" "$DEST"
codesign --force --sign - --timestamp=none "$DEST" 2>/dev/null || true
open "$DEST"
echo "ok: $DEST"
