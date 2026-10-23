#!/usr/bin/env bash
# Builds Valkey for Linux (x64 or arm64, whichever machine it runs on): valkey-server, valkey-cli
# and valkey-benchmark, with the bundled jemalloc, linked only against glibc (TLS off: Flock only
# listens on 127.0.0.1). Built on the oldest Ubuntu LTS Flock supports, so it runs on newer ones.
# Usage: packages/valkey/linux/build.sh <version> <out-dir>
set -euo pipefail
V="${1:?usage: build.sh <version> <out-dir>}"
OUT="$(mkdir -p "${2:?usage: build.sh <version> <out-dir>}" && cd "$2" && pwd)"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="${WORK_DIR:-$PWD/valkey-work}"

mkdir -p "$WORK" && cd "$WORK"
# The work directory sits inside this repository: without this, the version string would
# record our commit (mkreleasehdr.sh asks git) instead of 00000000 for a release tarball.
export GIT_DIR="$WORK/no-git"
bash "$ROOT/packages/valkey/source.sh" "$V" valkey.tar.gz
rm -rf src && mkdir src && tar -C src --strip-components 1 -xzf valkey.tar.gz
make -C src -j"$(nproc)" BUILD_TLS=no USE_SYSTEMD=no

rm -rf "$OUT" && mkdir -p "$OUT/LICENSES"
cp src/src/valkey-server src/src/valkey-cli src/src/valkey-benchmark "$OUT/"
strip "$OUT"/valkey-*
cp src/COPYING "$OUT/LICENSES/valkey.txt"
"$OUT/valkey-server" --version
