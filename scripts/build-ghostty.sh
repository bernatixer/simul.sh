#!/bin/bash
# Builds libghostty from the pinned, vendored Ghostty revision.
#
# Requirements (documented in README.md):
#   - Vendor/zig/        Zig 0.16.0 toolchain
#   - Vendor/Ghostty/    pinned submodule (see .gitmodules)
#   - No Xcode required: the runtime-metallib patch compiles shaders at
#     runtime and the xcframework step is replaced with a plain .a install.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$HERE/Vendor/Ghostty"
ZIG="$HERE/Vendor/zig/zig"
PATCH="$HERE/Vendor/patches/runtime-metallib.patch"

if [ ! -x "$ZIG" ]; then
  echo "error: Zig toolchain not found at $ZIG" >&2
  echo "       Install per README.md (Zig 0.16.0, aarch64-macos)." >&2
  exit 1
fi

cd "$GHOSTTY"

if [ -n "$(git status --porcelain -- src/build/MetallibStep.zig src/build/XCFrameworkStep.zig src/renderer/metal/shaders.zig 2>/dev/null)" ]; then
  echo "info: build patch already applied"
else
  git apply "$PATCH"
  echo "info: applied build patch"
fi

GHOSTTY_METALLIB_PLACEHOLDER=1 \
GHOSTTY_XCFRAMEWORK_SKIP=1 \
"$ZIG" build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=true \
  -Dxcframework-target=native \
  -Demit-macos-app=false

echo "ok: $(ls -lh zig-out/lib/libghostty.a | awk '{print $5, $9}')"
