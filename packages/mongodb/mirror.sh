#!/usr/bin/env bash
# Mirrors MongoDB Community Server's archive unchanged, checked against MongoDB's SHA-256. On Linux,
# MongoDB builds per distribution; the Ubuntu 22.04 build needs glibc 2.35, OpenSSL 3 and libcurl,
# which current distributions have (Ubuntu 22.04+, Debian 12+, Fedora, RHEL 9+, Arch). The RHEL 8
# build would need OpenSSL 1.1, which reached its end of life.
# Usage: packages/mongodb/mirror.sh <version> <platform> <out-file>
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="$1"; PLATFORM="$2"; OUT="$3"

case "$PLATFORM" in
  macos-arm64) url="https://fastdl.mongodb.org/osx/mongodb-macos-arm64-$V.tgz" ;;
  windows-x64) url="https://fastdl.mongodb.org/windows/mongodb-windows-x86_64-$V.zip" ;;
  linux-x64)   url="https://fastdl.mongodb.org/linux/mongodb-linux-x86_64-ubuntu2204-$V.tgz" ;;
  linux-arm64) url="https://fastdl.mongodb.org/linux/mongodb-linux-aarch64-ubuntu2204-$V.tgz" ;;
esac
fetch "$url" "$OUT"
check_sha256 "$OUT" "$(fetch_text "$url.sha256" | cut -d' ' -f1)"
