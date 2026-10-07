#!/bin/bash
# Cuts a release: scripts/release.sh 0.2.0 [--dry-run]
#
# Needs a clean tree on main and a "## [X.Y.Z] - YYYY-MM-DD" section in
# CHANGELOG.md (its text becomes the release notes). Builds with that
# version (build-app.sh runs the idle-CPU smoke check), zips the app, tags
# vX.Y.Z, pushes the tag and creates a GitHub prerelease with the zip.
# --dry-run stops after the zip: no tag, push or release.
#
# The build is ad-hoc signed, so it runs on this Mac but another Mac's
# Gatekeeper blocks it. Developer ID signing and notarization go between
# the build and the zip once there's an Apple Developer account.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
DRY_RUN="${2:-}"
die() { echo "release: $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: scripts/release.sh X.Y.Z [--dry-run]"
[ -z "$DRY_RUN" ] || [ "$DRY_RUN" = "--dry-run" ] || die "unknown option: $DRY_RUN"
TAG="v$VERSION"

cd "$HERE"
if [ -z "$DRY_RUN" ]; then
  [ "$(git branch --show-current)" = main ] || die "release from main"
  # Ghostty is patched in place at build time (build-ghostty.sh); its
  # pinned commit still counts.
  [ -z "$(git status --porcelain --ignore-submodules=dirty)" ] || die "working tree has uncommitted changes"
fi
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || die "$TAG already exists"

# Release notes: the CHANGELOG section for this version, up to the next one.
NOTES="$(awk -v v="$VERSION" '
  $0 ~ "^## \\[" v "\\]" { found = 1; next }
  found && /^## \[/ { exit }
  found && /^\[[^]]+\]: / { exit }
  found { print }
' CHANGELOG.md)"
[ -n "$(echo "$NOTES" | tr -d '[:space:]')" ] ||
  die "no \"## [$VERSION] - $(date +%F)\" section in CHANGELOG.md (rename Unreleased to it)"

SIMUL_VERSION="$VERSION" scripts/build-app.sh

ZIP="$HERE/Build/Simul-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$HERE/Build/Simul.app" "$ZIP"
echo "release: built $ZIP"

if [ -n "$DRY_RUN" ]; then
  echo "release: dry run, stopping before tag, push and GitHub release. Notes:"
  echo "$NOTES"
  exit 0
fi

git tag -a "$TAG" -m "Simul $VERSION"
git push origin "$TAG"
PRERELEASE=(); [[ "$VERSION" == 0.* ]] && PRERELEASE=(--prerelease) # pre-1.0
echo "$NOTES" | gh release create "$TAG" "$ZIP" --title "Simul $VERSION" --notes-file - ${PRERELEASE[@]+"${PRERELEASE[@]}"}
echo "release: published $TAG"
