#!/usr/bin/env bash
# Builds pgRouting for macOS or Linux against Flock's postgres package of one major, into the layout
# Flock links: lib/libpgrouting-<x.y>, extension/pgrouting*. It needs PostGIS at run time
# (requires = 'postgis' in its control file), not to build. Boost is header-only: compiled in.
# Usage: packages/pgrouting/build.sh <version> <postgres-dir> <out-dir>
#   BOOST_VERSION CMAKE_VERSION
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../scripts/lib.sh"
V="${1:?usage: build.sh <version> <postgres-dir> <out-dir>}"
PG="$(cd "${2:?usage: build.sh <version> <postgres-dir> <out-dir>}" && pwd -P)"
OUT="$(mkdir -p "${3:?usage: build.sh <version> <postgres-dir> <out-dir>}" && cd "$3" && pwd)"
WORK="${WORK_DIR:-$PWD/pgrouting-work}"
: "${BOOST_VERSION:?BOOST_VERSION is required}"
mkdir -p "$WORK" && cd "$WORK"

CMAKE=cmake LINKER=()
if [[ "$(uname -s)" == Darwin ]]; then
  CMAKE="$(macos_cmake "$WORK/cmake")"
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
  LINKER=(-DCMAKE_MODULE_LINKER_FLAGS="-bundle_loader $PG/bin/postgres" -DCMAKE_SHARED_LINKER_FLAGS="-undefined dynamic_lookup")
fi

echo "::group::Boost $BOOST_VERSION (headers)"
b="boost_${BOOST_VERSION//./_}"
if [[ ! -d "$b/boost" ]]; then
  fetch "https://archives.boost.io/release/$BOOST_VERSION/source/$b.tar.bz2" "$b.tar.bz2"
  check_sha256 "$b.tar.bz2" "$(fetch_text "https://archives.boost.io/release/$BOOST_VERSION/source/$b.tar.bz2.json" | jq -r .sha256)"
  tar -xjf "$b.tar.bz2" "$b/boost" "$b/LICENSE_1_0.txt" && rm "$b.tar.bz2"
fi
echo "::endgroup::"

bash "$HERE/source.sh" "$V" src
"$CMAKE" -S src -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
  -DPOSTGRESQL_PG_CONFIG="$PG/bin/pg_config" -DBoost_INCLUDE_DIR="$WORK/$b" -DBOOST_ROOT="$WORK/$b" -DBoost_NO_SYSTEM_PATHS=ON \
  ${LINKER[@]+"${LINKER[@]}"}
"$CMAKE" --build build -j"$(getconf _NPROCESSORS_ONLN)"
rm -rf stage && DESTDIR="$WORK/stage" "$CMAKE" --install build
rm -rf "$OUT" && pg_collect "$WORK/stage" "$PG/bin/pg_config" "$OUT"
[[ "$(uname -s)" == Darwin ]] || find "$OUT/lib" -type f -exec strip --strip-unneeded {} +

mkdir -p "$OUT/LICENSES"
cp src/LICENSE "$OUT/LICENSES/pgrouting.txt"
cp "$b/LICENSE_1_0.txt" "$OUT/LICENSES/boost.txt"
ls -R "$OUT" | head -20
