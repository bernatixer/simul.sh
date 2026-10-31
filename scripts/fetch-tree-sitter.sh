#!/bin/bash
# Re-vendors tree-sitter (core + Python, JavaScript, TypeScript/TSX
# grammars) into Vendor/tree-sitter from pinned GitHub release archives.
# Archives are untrusted: each is checked against its pinned sha256, and
# only C sources, headers, queries and licenses are copied out. Nothing in
# them is run. To bump a version, change its tag and sha256 below.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/Vendor/tree-sitter"

# name  repo  tag  sha256 of the tag's .tar.gz
PINS=(
  "core       tree-sitter            v0.27.0 d35c96e68736bd9569d2757c3cc71052485f33082c3825f1aed9d0e86013a159"
  "python     tree-sitter-python     v0.25.0 4609a3665a620e117acf795ff01b9e965880f81745f287a16336f4ca86cf270c"
  "javascript tree-sitter-javascript v0.25.0 9712fc283d3dc01d996d20b6392143445d05867a7aad76fdd723824468428b86"
  "typescript tree-sitter-typescript v0.23.2 2c4ce711ae8d1218a3b2f899189298159d672870b5b34dff5d937bed2f3e8983"
)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rm -rf "$OUT"
mkdir -p "$OUT"
{
  echo "# Written by scripts/fetch-tree-sitter.sh; edit the pins there."
  echo "# name repo tag sha256(archive)"
} > "$OUT/VERSIONS"

# grammar_src <extracted src dir> <dest src dir>
grammar_src() {
  mkdir -p "$2/tree_sitter"
  cp "$1/parser.c" "$1/scanner.c" "$2/"
  cp "$1"/tree_sitter/*.h "$2/tree_sitter/"
}

for pin in "${PINS[@]}"; do
  read -r name repo tag sha <<< "$pin"
  archive="$TMP/$repo.tar.gz"
  curl -fsSL -o "$archive" "https://github.com/tree-sitter/$repo/archive/refs/tags/$tag.tar.gz"
  echo "$sha  $archive" | shasum -a 256 -c --quiet
  src="$TMP/$repo"
  mkdir "$src"
  tar -xzf "$archive" -C "$src" --strip-components 1

  dest="$OUT/$name"
  mkdir -p "$dest"
  cp "$src/LICENSE" "$dest/LICENSE"
  case "$name" in
    core)
      mkdir -p "$dest/lib/src/portable" "$dest/lib/src/unicode" "$dest/lib/include/tree_sitter"
      cp "$src"/lib/src/*.c "$src"/lib/src/*.h "$dest/lib/src/"
      cp "$src"/lib/src/portable/*.h "$dest/lib/src/portable/"
      cp "$src"/lib/src/unicode/*.h "$src/lib/src/unicode/LICENSE" "$dest/lib/src/unicode/"
      cp "$src/lib/include/tree_sitter/api.h" "$dest/lib/include/tree_sitter/"
      ;;
    typescript)
      # One repo, two grammars sharing common/scanner.h.
      grammar_src "$src/typescript/src" "$dest/typescript/src"
      grammar_src "$src/tsx/src" "$dest/tsx/src"
      mkdir -p "$dest/common" "$dest/queries"
      cp "$src/common/scanner.h" "$dest/common/"
      # common/scanner.h includes "tree_sitter/parser.h": give it its own
      # copy (identical for both grammars) so no -I has to pick one.
      diff -r "$dest/typescript/src/tree_sitter" "$dest/tsx/src/tree_sitter" > /dev/null
      cp -R "$dest/typescript/src/tree_sitter" "$dest/common/"
      cp "$src"/queries/*.scm "$dest/queries/"
      ;;
    *)
      grammar_src "$src/src" "$dest/src"
      mkdir -p "$dest/queries"
      cp "$src"/queries/*.scm "$dest/queries/"
      ;;
  esac
  echo "$name $repo $tag $sha" >> "$OUT/VERSIONS"
done

echo "ok: $OUT"
