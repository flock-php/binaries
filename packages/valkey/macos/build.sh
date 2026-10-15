#!/usr/bin/env bash
# Builds Valkey for macOS (Apple Silicon): valkey-server, valkey-cli and valkey-benchmark,
# linked only against macOS system libraries (TLS off: Flock only listens on 127.0.0.1).
# Usage: packages/valkey/macos/build.sh <version> <out-dir>
set -euo pipefail
V="${1:?usage: build.sh <version> <out-dir>}"
OUT="$(mkdir -p "${2:?usage: build.sh <version> <out-dir>}" && cd "$2" && pwd)"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="${WORK_DIR:-$PWD/valkey-work}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$WORK" && cd "$WORK"
bash "$ROOT/packages/valkey/source.sh" "$V" valkey.tar.gz
rm -rf src && mkdir src && tar -C src --strip-components 1 -xzf valkey.tar.gz
make -C src/src -j"$(sysctl -n hw.ncpu)" BUILD_TLS=no USE_SYSTEMD=no MALLOC=libc

rm -rf "$OUT" && mkdir -p "$OUT/LICENSES"
cp src/src/valkey-server src/src/valkey-cli src/src/valkey-benchmark "$OUT/"
cp src/COPYING "$OUT/LICENSES/valkey.txt"
"$OUT/valkey-server" --version
