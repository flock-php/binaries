#!/usr/bin/env bash
# Mirrors MongoDB Community Server's archive unchanged, checked against MongoDB's SHA-256. On Linux
# the Ubuntu 24.04 build, or 22.04's for lines that have none (7.0); both run on current distributions.
# Usage: packages/mongodb/mirror.sh <version> <platform> <out-file>
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="$1"; PLATFORM="$2"; OUT="$3"

case "$PLATFORM" in
  macos-arm64) urls=("https://fastdl.mongodb.org/osx/mongodb-macos-arm64-$V.tgz") ;;
  windows-x64) urls=("https://fastdl.mongodb.org/windows/mongodb-windows-x86_64-$V.zip") ;;
  linux-x64 | linux-arm64)
    arch=x86_64; [[ "$PLATFORM" == linux-arm64 ]] && arch=aarch64
    urls=("https://fastdl.mongodb.org/linux/mongodb-linux-$arch-ubuntu2404-$V.tgz"
          "https://fastdl.mongodb.org/linux/mongodb-linux-$arch-ubuntu2204-$V.tgz") ;;
esac
for url in "${urls[@]}"; do
  fetch "$url" "$OUT" 2>/dev/null && break
done
[[ -s "$OUT" ]] || { echo "::error::no MongoDB $V build for $PLATFORM" >&2; exit 1; }
check_sha256 "$OUT" "$(fetch_text "$url.sha256" | cut -d' ' -f1)"
