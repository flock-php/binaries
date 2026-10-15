#!/usr/bin/env bash
# Mirrors the RustFS binary, checked against GitHub's SHA-256 of the release asset. Upstream's zip
# holds only the executable, so it's repacked with the Apache-2.0 license.
# Usage: packages/rustfs/mirror.sh <version> <platform> <out-file>
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="$1"; PLATFORM="$2"; OUT="$3"

case "$PLATFORM" in
  macos-arm64) asset="rustfs-macos-aarch64-v$V.zip" ;;
  windows-x64) asset="rustfs-windows-x86_64-v$V.zip" ;;
esac
tmp="$(mktemp -d)"; dir="$tmp/pkg"; mkdir "$dir"
fetch "https://github.com/rustfs/rustfs/releases/download/$V/$asset" "$tmp/$asset"
check_sha256 "$tmp/$asset" "$(github_digest rustfs/rustfs "$V" "$asset")"
unzip -q "$tmp/$asset" -d "$dir"
fetch "https://raw.githubusercontent.com/rustfs/rustfs/$V/LICENSE" "$dir/LICENSE"
pack "$dir" "$OUT"
