#!/usr/bin/env bash
# Mirrors MongoDB Community Server's archive unchanged, checked against MongoDB's SHA-256.
# Usage: packages/mongodb/mirror.sh <version> <platform> <out-file>
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="$1"; PLATFORM="$2"; OUT="$3"

case "$PLATFORM" in
  macos-arm64) url="https://fastdl.mongodb.org/osx/mongodb-macos-arm64-$V.tgz" ;;
  windows-x64) url="https://fastdl.mongodb.org/windows/mongodb-windows-x86_64-$V.zip" ;;
esac
fetch "$url" "$OUT"
check_sha256 "$OUT" "$(fetch_text "$url.sha256" | cut -d' ' -f1)"
