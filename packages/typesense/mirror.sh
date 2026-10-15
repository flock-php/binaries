#!/usr/bin/env bash
# Mirrors the Typesense server binary for macOS (there is no native Windows build). Typesense
# publishes no checksum file; the binary is checked against the MD5 shipped inside the tarball.
# Repacked with the GPLv3 license, which the upstream tarball doesn't include.
# Usage: packages/typesense/mirror.sh <version> macos-arm64 <out-file>
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="$1"; PLATFORM="$2"; OUT="$3"

[[ "$PLATFORM" == macos-arm64 ]] || { echo "Typesense has no Windows build" >&2; exit 1; }
tmp="$(mktemp -d)"; dir="$tmp/pkg"; mkdir "$dir"
fetch "https://dl.typesense.org/releases/$V/typesense-server-$V-darwin-arm64.tar.gz" "$tmp/t.tar.gz"
tar -C "$dir" -xzf "$tmp/t.tar.gz"
check_md5 "$dir/typesense-server" "$(cut -d' ' -f1 "$dir/typesense-server.md5.txt")"
fetch "https://raw.githubusercontent.com/typesense/typesense/v$V/LICENSE.txt" "$dir/LICENSE.txt"
pack "$dir" "$OUT"
