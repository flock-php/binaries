#!/usr/bin/env bash
# Builds Redis for macOS (Apple Silicon): redis-server, redis-cli and redis-benchmark, linked only
# against macOS system libraries (TLS off: Flock only listens on 127.0.0.1). Builds src/ only:
# since 8.x the top-level make also builds modules that need Rust.
# Usage: packages/redis/macos/build.sh <version> <out-dir>
set -euo pipefail
V="${1:?usage: build.sh <version> <out-dir>}"
OUT="$(mkdir -p "${2:?usage: build.sh <version> <out-dir>}" && cd "$2" && pwd)"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="${WORK_DIR:-$PWD/redis-work}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$WORK" && cd "$WORK"
# The work directory sits inside this repository: without this, the version string would
# record our commit (mkreleasehdr.sh asks git) instead of 00000000 for a release tarball.
export GIT_DIR="$WORK/no-git"
bash "$ROOT/packages/redis/source.sh" "$V" redis.tar.gz
rm -rf src && mkdir src && tar -C src --strip-components 1 -xzf redis.tar.gz
make -C src/src -j"$(sysctl -n hw.ncpu)" BUILD_TLS=no USE_SYSTEMD=no MALLOC=libc

rm -rf "$OUT" && mkdir -p "$OUT/LICENSES"
cp src/src/redis-server src/src/redis-cli src/src/redis-benchmark "$OUT/"
# 7.2: BSD (COPYING); 7.4: RSALv2/SSPL; 8.x: RSALv2/SSPL/AGPLv3 (LICENSE.txt plus one file each).
for f in src/COPYING src/LICENSE*.txt src/licenses/*; do
  [[ -f "$f" ]] && cp "$f" "$OUT/LICENSES/"
done
"$OUT/redis-server" --version
