#!/bin/bash
# Builds libghostty from the pinned, vendored Ghostty revision.
#
# Requirements (documented in README.md):
#   - Vendor/zig/        Zig 0.16.0 toolchain
#   - Vendor/Ghostty/    pinned submodule (see .gitmodules)
#   - No Xcode required: the runtime-metallib patch compiles shaders at
#     runtime and the xcframework step is replaced with a plain .a install.
#   - hyperlink-at.patch adds ghostty_surface_hyperlink_at (link hover).
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$HERE/Vendor/Ghostty"
ZIG="$HERE/Vendor/zig/zig"

if [ ! -x "$ZIG" ]; then
  echo "error: Zig toolchain not found at $ZIG" >&2
  echo "       Install per README.md (Zig 0.16.0, aarch64-macos)." >&2
  exit 1
fi

cd "$GHOSTTY"

for patch in "$HERE"/Vendor/patches/*.patch; do
  if git apply --reverse --check "$patch" 2>/dev/null; then
    echo "info: $(basename "$patch") already applied"
  else
    git apply "$patch"
    echo "info: applied $(basename "$patch")"
  fi
done

GHOSTTY_METALLIB_PLACEHOLDER=1 \
GHOSTTY_XCFRAMEWORK_SKIP=1 \
"$ZIG" build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=true \
  -Dxcframework-target=native \
  -Demit-macos-app=false

echo "ok: $(ls -lh zig-out/lib/libghostty.a | awk '{print $5, $9}')"
