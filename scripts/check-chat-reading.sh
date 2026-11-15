#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -swift-version 6 -parse-as-library -target arm64-apple-macos14.0 \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  "$ROOT/UI/Chat/ChatReadingPosition.swift" "$ROOT/UI/Chat/ChatScrollObserver.swift" \
  "$ROOT/scripts/tests/ChatReadingCheck.swift" \
  -o "$CHECK_DIR/check-chat-reading"
"$CHECK_DIR/check-chat-reading"
