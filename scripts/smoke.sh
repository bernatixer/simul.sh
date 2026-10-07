#!/bin/bash
# Launches the built app against an empty data folder and fails if it keeps
# burning CPU while idle: the signature of a SwiftUI redraw loop (e.g. an
# @AppStorage binding that a scene writes back on every update).
set -euo pipefail

APP="${1:-$(cd "$(dirname "$0")/.." && pwd)/Build/Simul.app}"
LIMIT=20 # % CPU; idle is ~0.1-0.5, a loop pins ~100

DATA="$(mktemp -d)"
SIMUL_DATA_DIR="$DATA" "$APP/Contents/MacOS/Simul" >/dev/null 2>&1 &
PID=$!
cleanup() {
  local status=$?
  kill "$PID" 2>/dev/null && wait "$PID" 2>/dev/null || true
  rm -rf "$DATA"
  exit "$status"
}
trap cleanup EXIT

sleep 8 # past launch work
lowest=100
for _ in 1 2 3 4 5; do
  kill -0 "$PID" 2>/dev/null || { echo "smoke: app exited during idle check" >&2; exit 1; }
  cpu="$(ps -o %cpu= -p "$PID" | tr -d ' ')"
  lowest="$(awk -v a="$cpu" -v b="$lowest" 'BEGIN { print (a < b ? a : b) }')"
  sleep 1
done

# Lowest sample, so a single busy moment can't fail the check.
if awk -v c="$lowest" -v l="$LIMIT" 'BEGIN { exit !(c > l) }'; then
  echo "smoke: FAIL, idle CPU never dropped below ${lowest}% (limit ${LIMIT}%); likely a redraw loop" >&2
  exit 1
fi
echo "smoke: ok (idle CPU ${lowest}%)"
