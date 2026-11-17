#!/usr/bin/env bash
# Builds a static ICU (macOS has no public one) into <prefix>, checked against the SHA-256 GitHub
# recorded for the release's source archive. The data is compiled in (libicudata.a): whatever
# links it needs no data file to ship or find. Reuses <prefix> when it already holds this build.
# Usage: scripts/macos/icu.sh <version> <prefix>
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
V="${1:?usage: icu.sh <version> <prefix>}"; PREFIX="${2:?usage: icu.sh <version> <prefix>}"

[[ -f "$PREFIX/lib/libicuuc.a" && -f "$PREFIX/.version-$V" ]] && exit 0
tmp="$(mktemp -d)"
f="icu4c-$V-sources.tgz"
fetch "https://github.com/unicode-org/icu/releases/download/release-$V/$f" "$tmp/$f"
check_sha256 "$tmp/$f" "$(github_digest unicode-org/icu "release-$V" "$f")"
mkdir "$tmp/src" && tar -C "$tmp/src" --strip-components 1 -xzf "$tmp/$f"
rm -rf "$PREFIX"
# The tools build too (they package the data), but only the libraries are used.
(cd "$tmp/src/source" \
  && ./configure --prefix="$PREFIX" --enable-static --disable-shared --with-data-packaging=static \
       --disable-samples --disable-tests --disable-extras \
  && make -j"$(sysctl -n hw.ncpu)" && make install)
cp "$tmp/src/LICENSE" "$PREFIX/LICENSE"
touch "$PREFIX/.version-$V"
rm -rf "$tmp"
