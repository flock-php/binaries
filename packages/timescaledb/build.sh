#!/usr/bin/env bash
# Builds TimescaleDB for macOS or Linux, unmodified and complete (the Apache-2.0 part and the TSL
# part: compression, continuous aggregates, policies), against Flock's postgres package of one
# major, into the layout Flock links: lib/timescaledb*.{so,dylib}, extension/timescaledb*.
# Telemetry stays compiled in, but Flock starts the server with timescaledb.telemetry_level=off.
# Usage: packages/timescaledb/build.sh <version> <postgres-dir> <out-dir>
#   CMAKE_VERSION  CMake to use on macOS (Homebrew's would find Homebrew's libraries)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../scripts/lib.sh"
V="${1:?usage: build.sh <version> <postgres-dir> <out-dir>}"
PG="$(cd "${2:?usage: build.sh <version> <postgres-dir> <out-dir>}" && pwd -P)"
OUT="$(mkdir -p "${3:?usage: build.sh <version> <postgres-dir> <out-dir>}" && cd "$3" && pwd)"
WORK="${WORK_DIR:-$PWD/timescaledb-work}"
mkdir -p "$WORK" && cd "$WORK"

CMAKE=cmake
if [[ "$(uname -s)" == Darwin ]]; then
  CMAKE="$(macos_cmake "$WORK/cmake")"
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
fi
echo "TimescaleDB $V: commit $(bash "$HERE/source.sh" "$V" src)"
"$CMAKE" -S src -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
  -DPG_CONFIG="$PG/bin/pg_config" -DREGRESS_CHECKS=OFF -DTAP_CHECKS=OFF -DWARNINGS_AS_ERRORS=OFF \
  -DUSE_OPENSSL=OFF -DLINTER=OFF -DCLANG_FORMAT=OFF -DENABLE_DEBUG_UTILS=OFF
"$CMAKE" --build build -j"$(getconf _NPROCESSORS_ONLN)"
rm -rf stage && DESTDIR="$WORK/stage" "$CMAKE" --install build
pg_collect "$WORK/stage" "$PG/bin/pg_config" "$OUT"

mkdir -p "$OUT/LICENSES"
cp src/LICENSE "$OUT/LICENSES/timescaledb.txt"
cp src/LICENSE-APACHE "$OUT/LICENSES/timescaledb-apache.txt" 2>/dev/null || true
cp src/tsl/LICENSE-TIMESCALE "$OUT/LICENSES/timescaledb-tsl.txt"
ls -R "$OUT"
